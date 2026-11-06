import copy
import http.server
import json
import os
from pathlib import Path
import select
import socket
import socketserver
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest import mock
from urllib.parse import urlencode
import uuid

import test_installers as installers
import test_optional_routing as routing


VLESS_ID = "11111111-2222-4333-8444-555555555555"
TLS_NAME = "upstream.test.invalid"
SOURCES = (("debian", installers.DEBIAN), ("alpine", installers.ALPINE))
VLESS_BODY = b"domain-routing-through-verified-vless-tls"


def make_uri(host="upstream.example.com", port=32464, **parameters):
    query = {
        "encryption": "none", "security": "reality", "type": "tcp",
        "sni": "gateway.icloud.com", "fp": "chrome",
        "pbk": installers.KEY, "sid": installers.SID,
        "flow": "xtls-rprx-vision",
    }
    for name, value in parameters.items():
        if value is None:
            query.pop(name, None)
        else:
            query[name] = value
    address = f"[{host}]" if ":" in host else host
    return f"vless://{VLESS_ID}@{address}:{port}?" + urlencode(query)


def tls_uri(host="upstream.example.com", port=32464, **parameters):
    defaults = {
        "security": "tls", "pbk": None, "sid": None, "flow": None,
    }
    defaults.update(parameters)
    return make_uri(host=host, port=port, **defaults)


def parser_code(source):
    return (
        "set -e\n"
        + routing.source_functions(source, ("fail", "parse_route_vless"))
        + '\nparse_route_vless\nprintf "%s\\n" "$route_vless_outbound"\n'
    )


def run_shell(code, values, *, input_text=None):
    if not installers.SHELL or not installers.JQ:
        raise unittest.SkipTest("POSIX shell and jq are required")
    environment = os.environ.copy()
    environment.update(values)
    environment["MSYS_NO_PATHCONV"] = "1"
    environment["TEST_JQ"] = Path(installers.JQ).resolve().as_posix()
    environment["TEST_SECRET_ID"] = VLESS_ID
    wrapper = r'''
jq() {
  for argument do
    case "$argument" in
      *"$TEST_SECRET_ID"*)
        printf 'Upstream credential was exposed in jq arguments\n' >&2
        return 98
        ;;
    esac
  done
  "$TEST_JQ" "$@"
}
'''
    # Passing a large quoted script through Windows argv changes regex escapes.
    with tempfile.TemporaryDirectory() as directory:
        menu_file = Path(directory) / "menu-input"
        menu_file.write_text(input_text or "", encoding="utf-8", newline="\n")
        environment["TEST_MENU_INPUT_FILE"] = menu_file.as_posix()
        return subprocess.run(
            [installers.SHELL, "-s"],
            input=wrapper + code, env=environment, capture_output=True,
            text=True, encoding="utf-8",
        )


def parse_outbound(source, uri):
    result = run_shell(parser_code(source), {"route_vless_link": uri})
    if result.returncode:
        raise AssertionError(result.stdout + result.stderr)
    return json.loads(result.stdout)


def route_configuration(installer, upstream, *, mode="2", family="3"):
    values = installers.variables(mode, address_family=family)
    encoded = json.dumps(upstream, separators=(",", ":"))
    values.update({
        "routing_mode": "3", "route_domains": routing.DOMAINS,
        "route_host": "", "route_port": "", "route_user": "",
        "route_password": "", "route_vless_outbound": encoded,
        "XRAY_ROUTE_VLESS": encoded,
        "XRAY_ROUTE_USER": "", "XRAY_ROUTE_PASSWORD": "",
        "TEST_SECRET_ID": VLESS_ID,
    })
    with tempfile.TemporaryDirectory() as directory:
        output = Path(directory) / "config.json"
        if installer == "alpine":
            start = installers.ALPINE.index("jq -n \\\n")
            end = installers.ALPINE.index(
                '\n"$tmp_dir/xray" run -test', start
            )
            code = r'''
jq() {
  for argument do
    case "$argument" in
      *"$TEST_SECRET_ID"*)
        printf 'Upstream credential was exposed in jq arguments\n' >&2
        return 98
        ;;
    esac
  done
  "$TEST_JQ" "$@"
}
'''
            installers.shell_run(
                code + installers.ALPINE[start:end],
                {**values, "tmp_dir": Path(directory).as_posix()},
            )
        else:
            environment = installers.python_env(values)
            environment.update({
                "XRAY_ROUTING_MODE": "3",
                "XRAY_ROUTE_DOMAINS": routing.DOMAINS,
                "XRAY_ROUTE_VLESS": encoded,
            })
            subprocess.run(
                [sys.executable, "-c", installers.PY_BLOCKS[0], str(output)],
                env=environment, check=True,
            )
        return json.loads(output.read_text(encoding="utf-8"))


class VlessImportTests(unittest.TestCase):
    def test_reality_nat_port_ipv6_and_raw_alias_have_platform_parity(self):
        cases = (
            ("upstream.example.com", "tcp"),
            ("192.0.2.50", "raw"),
            ("2001:db8::50", "tcp"),
        )
        for host, transport in cases:
            with self.subTest(host=host, transport=transport):
                parsed = [
                    parse_outbound(source, make_uri(host=host, type=transport))
                    for _, source in SOURCES
                ]
                self.assertEqual(*parsed)
                outbound = parsed[0]
                self.assertEqual(outbound["tag"], "custom-upstream")
                self.assertEqual(outbound["protocol"], "vless")
                server, = outbound["settings"]["vnext"]
                self.assertEqual(server["address"], host)
                self.assertEqual(server["port"], 32464)
                user, = server["users"]
                self.assertEqual(user, {
                    "id": VLESS_ID, "encryption": "none",
                    "flow": "xtls-rprx-vision",
                })
                stream = outbound["streamSettings"]
                self.assertEqual(stream["security"], "reality")
                self.assertEqual(stream["network"], "raw")
                reality = stream["realitySettings"]
                self.assertEqual(reality["serverName"], "gateway.icloud.com")
                self.assertEqual(reality["shortId"], installers.SID)
                self.assertEqual(reality["fingerprint"], "chrome")
                self.assertEqual(
                    reality.get("password", reality.get("publicKey")),
                    installers.KEY,
                )

    def test_tls_defaults_certificate_verification_and_websocket_decoding(self):
        path = '/ws-\u8282\u70b9?token=one+two&quoted="yes"&literal=$(id)'
        # URI host and the WebSocket Host query use separate namespaces.
        websocket = tls_uri(
            host="2001:db8::50", type="ws", sni=TLS_NAME, path=path
        ) + "&host=cdn.example.com"
        cases = (
            (tls_uri(sni=None), "raw", "upstream.example.com", None),
            (websocket, "ws", TLS_NAME, path),
        )
        for uri, network, server_name, expected_path in cases:
            with self.subTest(network=network):
                parsed = [
                    parse_outbound(source, uri + "#Private%20node")
                    for _, source in SOURCES
                ]
                self.assertEqual(*parsed)
                stream = parsed[0]["streamSettings"]
                self.assertEqual(stream["network"], network)
                tls = stream["tlsSettings"]
                self.assertEqual(tls["serverName"], server_name)
                self.assertFalse(tls.get("allowInsecure", False))
                if expected_path is not None:
                    self.assertEqual(stream["wsSettings"]["path"], expected_path)
                    websocket = stream["wsSettings"]
                    self.assertEqual(
                        websocket.get("host", websocket.get("headers", {}).get("Host")),
                        "cdn.example.com",
                    )

    def test_empty_reality_short_id_defaults_and_safe_optional_parameters(self):
        for _, source in SOURCES:
            with self.subTest(source="alpine" if source == installers.ALPINE else "debian"):
                outbound = parse_outbound(
                    source,
                    make_uri(sid="", flow=None, fp=None, spx="/") + "&allowInsecure=0",
                )
                reality = outbound["streamSettings"]["realitySettings"]
                self.assertEqual(reality["shortId"], "")
                self.assertEqual(reality["fingerprint"], "chrome")
                tls = parse_outbound(
                    source, tls_uri(alpn="h2,http/1.1") + "&insecure=false"
                )["streamSettings"]["tlsSettings"]
                self.assertEqual(tls["alpn"], ["h2", "http/1.1"])
                self.assertFalse(tls.get("allowInsecure", False))

    def test_malformed_or_unsafe_links_fail_without_disclosing_credentials(self):
        valid = make_uri()
        invalid = (
            "",
            valid.replace("vless://", "vmess://"),
            valid.replace(VLESS_ID, "invalid-user"),
            valid.replace(":32464?", ":0?"),
            valid.replace(":32464?", ":65536?"),
            valid.replace(":32464?", ":32464/path?"),
            valid.replace("@upstream.example.com:", "@[upstream.example.com]:"),
            make_uri(host="192.0.2.50").replace("@192.0.2.50:", "@[192.0.2.50]:"),
            make_uri(host="bad_host.example"),
            make_uri(host="2001:::50"),
            make_uri(security=None),
            make_uri(security="none"),
            make_uri(encryption="unsupported"),
            make_uri(type="grpc"),
            make_uri(type="ws"),
            make_uri(sni=None),
            make_uri(pbk="short-key"),
            make_uri(fp="unsupported-fingerprint"),
            make_uri(sid="abc"),
            make_uri(sid="00" * 9),
            make_uri(flow="unsupported-flow"),
            tls_uri(type="ws", flow="xtls-rprx-vision"),
            tls_uri(host="192.0.2.50", sni=None),
            tls_uri() + "&allowInsecure=1",
            tls_uri() + "&insecure=true",
            tls_uri() + "&security=tls",
            tls_uri() + "&%73ecurity=tls",
            tls_uri() + "&unknownTransportOption=true",
            tls_uri(type="ws") + "&path=%2Ftest%00secret",
            tls_uri(type="ws", path="/") + "&host=bad%0D%0AHost",
            tls_uri(type="ws") + "&path=%",
            tls_uri(type="ws") + "&path=%C0%AF",
            tls_uri(type="ws") + "&path=%ED%A0%80",
            tls_uri(type="ws") + "&path=%F4%90%80%80",
            tls_uri(type="ws") + "&path=%E4%BD",
        )
        for installer, source in SOURCES:
            for index, uri in enumerate(invalid):
                with self.subTest(installer=installer, invalid=index):
                    result = run_shell(
                        parser_code(source), {"route_vless_link": uri}
                    )
                    self.assertNotEqual(result.returncode, 0)
                    self.assertNotIn(
                        VLESS_ID, result.stdout + result.stderr,
                        "Invalid-link diagnostics must not echo a credential",
                    )
                    self.assertNotIn('"protocol":"vless"', result.stdout)

    def test_import_and_generation_do_not_pass_credentials_in_process_arguments(self):
        native_popen = subprocess.Popen
        arguments_seen = []

        def recorded_popen(arguments, *args, **kwargs):
            arguments_seen.append(arguments)
            return native_popen(arguments, *args, **kwargs)

        for installer, source in SOURCES:
            with self.subTest(installer=installer):
                arguments_seen.clear()
                with mock.patch.object(subprocess, "Popen", side_effect=recorded_popen):
                    upstream = parse_outbound(source, make_uri())
                    route_configuration(installer, upstream)
                self.assertTrue(arguments_seen)
                for arguments in arguments_seen:
                    self.assertNotIn(VLESS_ID, "\n".join(map(str, arguments)))

    def test_menu_imports_hidden_link_and_preserves_custom_domains(self):
        for installer, source in SOURCES:
            with self.subTest(installer=installer):
                functions = routing.source_functions(source, (
                    "fail", "validate_hostname", "validate_host", "validate_port",
                    "validate_route_domain", "normalize_route_domains",
                    "validate_route_auth", "parse_route_vless", "select_routing_mode",
                )).replace(" >/dev/tty", "")
                code = "set -e\n" + functions + r'''
exec 3< "$TEST_MENU_INPUT_FILE"
select_routing_mode
[ "$routing_mode" = 3 ]
[ "$route_domains" = "$TEST_EXPECTED_DOMAINS" ]
printf '%s' "$route_vless_outbound" | jq -e \
  '.settings.vnext[0].users[0].id == env.TEST_SECRET_ID' >/dev/null
IFS= read -r remainder <&3
[ "$remainder" = MENU_END ]
printf 'VLESS_MENU_OK\n'
'''
                result = run_shell(
                    code,
                    {
                        "TEST_EXPECTED_DOMAINS": routing.DOMAINS,
                        "TEST_SECRET_ID": VLESS_ID,
                    },
                    input_text="3\n" + routing.DOMAINS.replace("\n", ",") + "\n"
                    + make_uri() + "\nMENU_END\n",
                )
                self.assertEqual(
                    result.returncode, 0, result.stdout + result.stderr
                )
                self.assertIn("VLESS_MENU_OK", result.stdout)
                self.assertNotIn(VLESS_ID, result.stdout + result.stderr)

    def test_vless_routing_has_parity_in_every_node_mode_and_egress_family(self):
        upstream = parse_outbound(installers.DEBIAN, make_uri())
        for mode in ("1", "2", "3", "4"):
            for family in installers.FAMILY_STRATEGIES:
                with self.subTest(mode=mode, family=family):
                    config = route_configuration(
                        "debian", upstream, mode=mode, family=family
                    )
                    self.assertEqual(
                        config,
                        route_configuration(
                            "alpine", upstream, mode=mode, family=family
                        ),
                    )
                    self.assertEqual(config["outbounds"][1], upstream)
                    ordinary = installers.configuration(
                        "debian", mode, address_family=family
                    )
                    self.assertEqual(
                        config["outbounds"][0], ordinary["outbounds"][0]
                    )
                    self.assertEqual(config["routing"]["rules"], [{
                        "type": "field",
                        "domain": routing.DOMAINS.splitlines(),
                        "outboundTag": "custom-upstream",
                    }])
                    self.assertNotIn("dns", config)
                    for inbound in config["inbounds"]:
                        self.assertTrue(inbound["sniffing"]["enabled"])
                        self.assertFalse(inbound["sniffing"]["routeOnly"])

    def test_installer_generated_links_are_accepted_as_upstreams(self):
        for host in ("198.51.100.20", "2001:db8::20"):
            for uri in installers.links("debian", "3", host):
                with self.subTest(host=host, websocket="type=ws" in uri):
                    parsed = [
                        parse_outbound(source, uri) for _, source in SOURCES
                    ]
                    self.assertEqual(*parsed)
                    server, = parsed[0]["settings"]["vnext"]
                    self.assertEqual(server["users"][0]["id"], installers.UUID)

    def test_summary_hides_upstream_credentials_and_needs_no_removed_packages(self):
        encoded = json.dumps(parse_outbound(installers.DEBIAN, make_uri()))
        values = {
            **installers.variables("3"),
            "routing_mode": "3", "route_domains": routing.DOMAINS,
            "route_vless_outbound": encoded,
            "XRAY_ROUTE_VLESS": encoded,
        }
        environment = installers.python_env(values)
        environment.update({
            "XRAY_ROUTING_MODE": "3",
            "XRAY_ROUTE_DOMAINS": routing.DOMAINS,
            "XRAY_ROUTE_VLESS": encoded,
        })
        debian_output = subprocess.check_output(
            [sys.executable, "-c", installers.PY_BLOCKS[1]],
            env=environment, text=True, encoding="utf-8",
        )
        start = installers.ALPINE.index(
            'case "$public_host" in\n  *:*) case'
        )
        end = installers.ALPINE.index(
            "# Clean both the release archive", start
        )
        output_start = installers.ALPINE.index(
            "printf '\\nXray 服务已启动。"
        )
        alpine = run_shell(
            installers.ALPINE[start:end]
            + '\njq() { printf "jq used after package removal\\n" >&2; return 99; }\n'
            + installers.ALPINE[output_start:],
            values,
        )
        self.assertEqual(alpine.returncode, 0, alpine.stdout + alpine.stderr)
        for output in (debian_output, alpine.stdout):
            self.assertIn("VLESS", output)
            self.assertIn(routing.SUFFIX_DOMAIN, output)
            self.assertNotIn(VLESS_ID, output)
            self.assertNotIn("upstream.example.com", output)
            self.assertNotIn(encoded, output)


class VlessHandler(routing.DirectHandler):
    body = VLESS_BODY


class RecordingRelayHandler(socketserver.BaseRequestHandler):
    def handle(self):
        try:
            with socket.create_connection(self.server.target, timeout=3) as upstream:
                while True:
                    readable, _, _ = select.select(
                        [self.request, upstream], [], [], 3
                    )
                    if not readable:
                        return
                    for source in readable:
                        data = source.recv(65536)
                        if not data:
                            return
                        self.server.packets.append(data)
                        destination = (
                            upstream if source is self.request else self.request
                        )
                        destination.sendall(data)
        except OSError:
            return


class RecordingRelay(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True

    def __init__(self, target):
        super().__init__(("127.0.0.1", 0), RecordingRelayHandler)
        self.target = target
        self.packets = []


@unittest.skipUnless(
    installers.XRAY, "Set XRAY_TEST_BIN for encrypted VLESS routing tests"
)
class VlessXrayTests(unittest.TestCase):
    def test_supported_outbound_transports_validate_with_real_xray(self):
        uris = (
            make_uri(), tls_uri(), tls_uri(type="ws", path="/custom"),
        )
        for installer, source in SOURCES:
            for index, uri in enumerate(uris):
                upstream = parse_outbound(source, uri)
                for mode in ("1", "4"):
                    for family in installers.FAMILY_STRATEGIES:
                        with self.subTest(
                            installer=installer, transport=index,
                            mode=mode, family=family,
                        ):
                            config = route_configuration(
                                installer, upstream, mode=mode, family=family
                            )
                            with tempfile.TemporaryDirectory() as directory:
                                path = Path(directory) / "config.json"
                                path.write_text(json.dumps(config), encoding="utf-8")
                                result = subprocess.run(
                                    [
                                        installers.XRAY, "run", "-test",
                                        "-config", str(path),
                                    ],
                                    capture_output=True, text=True,
                                )
                            self.assertEqual(
                                result.returncode, 0, result.stdout + result.stderr
                            )

    def test_verified_tls_chain_routes_domains_and_fails_closed(self):
        certificate = json.loads(subprocess.check_output(
            [
                installers.XRAY, "tls", "cert", "--ca",
                "--domain=" + TLS_NAME,
            ],
            text=True, encoding="utf-8",
        ))
        for installer, source in SOURCES:
            for transport in ("tcp", "ws"):
                with self.subTest(installer=installer, transport=transport):
                    self.check_live_chain(
                        installer, source, transport, certificate
                    )

    def check_live_chain(self, installer, source, transport, certificate):
        ipv4_origin = http.server.ThreadingHTTPServer(
            ("127.0.0.1", 0), VlessHandler
        )
        self.addCleanup(ipv4_origin.server_close)
        origin_port = ipv4_origin.server_port
        try:
            ipv6_origin = routing.IPv6OnlyHTTPServer(
                ("::1", origin_port), routing.DirectHandler
            )
            self.addCleanup(ipv6_origin.server_close)
        except OSError as error:
            ipv4_origin.server_close()
            self.skipTest(f"IPv6 loopback is unavailable: {error}")
        upstream_port = installers.free_port()
        relay = RecordingRelay(("127.0.0.1", upstream_port))
        self.addCleanup(relay.server_close)
        upstream_uri = tls_uri(
            host="127.0.0.1", port=relay.server_address[1],
            sni=TLS_NAME, type=transport,
            **({"path": "/encrypted-route"} if transport == "ws" else {}),
        )
        upstream = parse_outbound(source, upstream_uri)
        tls = upstream["streamSettings"]["tlsSettings"]
        self.assertFalse(tls.get("allowInsecure", False))
        tls["certificates"] = [{
            "certificate": certificate["certificate"], "usage": "verify",
        }]
        stream = {
            "network": "raw" if transport == "tcp" else "ws",
            "security": "tls",
            "tlsSettings": {"certificates": [copy.deepcopy(certificate)]},
        }
        if transport == "ws":
            stream["wsSettings"] = {"path": "/encrypted-route"}
        targets = [
            *routing.PROXIED_DOMAINS,
            "child." + routing.EXACT_DOMAIN, routing.DIRECT_DOMAIN,
        ]
        exit_node = {
            "log": {"loglevel": "debug"},
            "inbounds": [{
                "listen": "127.0.0.1", "port": upstream_port,
                "protocol": "vless",
                "settings": {
                    "clients": [{"id": VLESS_ID}], "decryption": "none",
                },
                "streamSettings": stream,
            }],
            "outbounds": [{
                "protocol": "freedom",
                "settings": {"finalRules": [{
                    "action": "allow", "network": "tcp",
                    "ip": ["127.0.0.1/32"], "port": str(origin_port),
                }]},
                "streamSettings": {"sockopt": {"domainStrategy": "ForceIPv4"}},
            }],
            "dns": {
                "hosts": {
                    domain: "127.0.0.1" for domain in routing.PROXIED_DOMAINS
                },
                "servers": ["localhost"],
            },
        }
        config = route_configuration(installer, upstream, family="2")
        ws_port, socks_port = installers.free_port(), installers.free_port()
        config["log"]["loglevel"] = "debug"
        config["inbounds"][0].update(listen="127.0.0.1", port=ws_port)
        config["outbounds"][0]["settings"]["finalRules"].append({
            "action": "allow", "network": "tcp",
            "ip": ["::1/128"], "port": str(origin_port),
        })
        config["dns"] = {
            "hosts": {domain: "::1" for domain in targets},
            "servers": ["localhost"],
        }
        client = {
            "log": {"loglevel": "debug"},
            "inbounds": [{
                "listen": "127.0.0.1", "port": socks_port,
                "protocol": "socks", "settings": {"auth": "noauth"},
            }],
            "outbounds": [{
                "protocol": "vless",
                "settings": {"vnext": [{
                    "address": "127.0.0.1", "port": ws_port,
                    "users": [{"id": installers.UUID, "encryption": "none"}],
                }]},
                "streamSettings": {
                    "network": "ws", "security": "none",
                    "wsSettings": {"path": installers.WS_PATH},
                },
            }],
        }
        with (
            routing.serve_http(ipv4_origin),
            routing.serve_http(ipv6_origin),
            routing.serve_http(relay),
            installers.running_xray(config, ws_port),
            installers.running_xray(client, socks_port),
        ):
            with installers.running_xray(exit_node, upstream_port):
                for domain in routing.PROXIED_DOMAINS:
                    response = routing.request_http(
                        socks_port, domain, origin_port
                    )
                    self.assertIn(VLESS_BODY, response)
                    self.assertNotIn(routing.DIRECT_BODY, response)
                for domain in targets[3:]:
                    response = routing.request_http(
                        socks_port, domain, origin_port
                    )
                    self.assertIn(routing.DIRECT_BODY, response)
                    self.assertNotIn(VLESS_BODY, response)
                sniffed = routing.request_http(
                    socks_port, "192.0.2.123", origin_port,
                    host_header=routing.SUFFIX_DOMAIN,
                )
                self.assertIn(VLESS_BODY, sniffed)
                transferred = b"".join(relay.packets)
                self.assertTrue(transferred)
                self.assertTrue(any(packet.startswith(b"\x16\x03") for packet in relay.packets))
                for secret in (
                    VLESS_ID.encode(), uuid.UUID(VLESS_ID).bytes,
                    routing.SUFFIX_DOMAIN.encode(), VLESS_BODY,
                ):
                    self.assertNotIn(secret, transferred)
            failed = routing.request_http(
                socks_port, routing.SUFFIX_DOMAIN, origin_port
            )
            self.assertNotIn(
                routing.DIRECT_BODY, failed,
                "A VLESS upstream outage must not fall back to local egress",
            )
            ordinary = routing.request_http(
                socks_port, routing.DIRECT_DOMAIN, origin_port
            )
            self.assertIn(routing.DIRECT_BODY, ordinary)


if __name__ == "__main__":
    unittest.main()
