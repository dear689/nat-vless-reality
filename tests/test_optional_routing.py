import contextlib
import http.server
import json
from pathlib import Path
import select
import socket
import socketserver
import struct
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest import mock

import test_installers as installers


SUFFIX_DOMAIN = "route.test.invalid"
EXACT_DOMAIN = "exact.test.invalid"
DIRECT_DOMAIN = "ordinary.test.invalid"
PROXIED_DOMAINS = (
    SUFFIX_DOMAIN, "child." + SUFFIX_DOMAIN, EXACT_DOMAIN,
)
DOMAINS = "domain:" + SUFFIX_DOMAIN + "\nfull:" + EXACT_DOMAIN
SOCKS_USER = "route-user"
SOCKS_PASSWORD = 'synthetic-"password\\only'
PROXY_BODY = b"custom-routing-via-authenticated-socks"
DIRECT_BODY = b"custom-routing-via-direct"


def route_configuration(
    installer, mode="2", family="3", enabled=True,
    host="192.0.2.50", port="11080", user=SOCKS_USER,
    password=SOCKS_PASSWORD, domains=DOMAINS,
):
    values = installers.variables(mode, address_family=family)
    routing = {
        "routing_mode": "2" if enabled else "1",
        "route_domains": domains,
        "route_host": host,
        "route_port": port,
        "route_user": user,
        "route_password": password,
    }
    with tempfile.TemporaryDirectory() as directory:
        output = Path(directory) / "config.json"
        if installer == "alpine":
            start = installers.ALPINE.index("jq -n \\\n")
            end = installers.ALPINE.index(
                '\n"$tmp_dir/xray" run -test', start
            )
            installers.shell_run(
                r'''
jq() {
  for argument do
    if [ -n "$XRAY_ROUTE_PASSWORD" ] \
      && [ "$argument" = "$XRAY_ROUTE_PASSWORD" ]; then
      printf 'SOCKS password was exposed in jq arguments\n' >&2
      return 98
    fi
  done
  "$TEST_JQ" "$@"
}
''' + installers.ALPINE[start:end],
                {
                    **values, **routing,
                    "tmp_dir": Path(directory).as_posix(),
                    "XRAY_ROUTE_USER": user,
                    "XRAY_ROUTE_PASSWORD": password,
                },
            )
        else:
            environment = installers.python_env(values)
            environment.update({
                "XRAY_" + key.upper(): value
                for key, value in routing.items()
            })
            subprocess.run(
                [sys.executable, "-c", installers.PY_BLOCKS[0], str(output)],
                env=environment, check=True,
            )
        return json.loads(output.read_text(encoding="utf-8"))


def source_functions(source, names):
    return "\n".join(installers.shell_function(source, name) for name in names)


class OptionalRoutingGeneratorTests(unittest.TestCase):
    def test_disabled_routing_preserves_ordinary_configuration(self):
        for installer in ("debian", "alpine"):
            for family in installers.FAMILY_STRATEGIES:
                with self.subTest(installer=installer, family=family):
                    config = route_configuration(
                        installer, family=family, enabled=False
                    )
                    self.assertEqual(
                        config,
                        installers.configuration(
                            installer, "2", address_family=family
                        ),
                    )
                    self.assertNotIn("routing", config)
                    self.assertNotIn("sniffing", config["inbounds"][0])

    def test_custom_domains_have_platform_parity_in_every_mode_and_family(self):
        for mode in ("1", "2", "3", "4"):
            for family in installers.FAMILY_STRATEGIES:
                with self.subTest(mode=mode, family=family):
                    config = route_configuration(
                        "debian", mode=mode, family=family
                    )
                    self.assertEqual(
                        config,
                        route_configuration("alpine", mode=mode, family=family),
                    )
                    direct, upstream = config["outbounds"]
                    ordinary = installers.configuration(
                        "debian", mode, address_family=family
                    )
                    self.assertEqual(direct, ordinary["outbounds"][0])
                    self.assertEqual(upstream["tag"], "custom-upstream")
                    self.assertEqual(upstream["protocol"], "socks")
                    self.assertEqual(upstream["settings"], {
                        "servers": [{
                            "address": "192.0.2.50",
                            "port": 11080,
                            "users": [{
                                "user": SOCKS_USER,
                                "pass": SOCKS_PASSWORD,
                            }],
                        }],
                    })
                    self.assertNotIn("finalRules", upstream["settings"])
                    self.assertNotIn(
                        upstream.get("streamSettings", {}).get(
                            "sockopt", {}
                        ).get("domainStrategy"),
                        ("ForceIPv4", "ForceIPv6"),
                    )
                    self.assertEqual(config["routing"]["domainStrategy"], "AsIs")
                    rules = config["routing"]["rules"]
                    self.assertEqual(len(rules), 1)
                    self.assertEqual(
                        rules[0]["domain"], DOMAINS.splitlines()
                    )
                    self.assertEqual(
                        rules[0]["outboundTag"], "custom-upstream"
                    )
                    self.assertNotIn("dns", config)
                    for inbound in config["inbounds"]:
                        sniffing = inbound["sniffing"]
                        self.assertTrue(sniffing["enabled"])
                        self.assertFalse(sniffing["routeOnly"])
                        self.assertIn("http", sniffing["destOverride"])
                        self.assertIn("tls", sniffing["destOverride"])

    def test_unauthenticated_socks_and_ipv6_upstream(self):
        for installer in ("debian", "alpine"):
            with self.subTest(installer=installer):
                config = route_configuration(
                    installer, host="2001:db8::50", port="1080",
                    user="", password="",
                )
                server, = config["outbounds"][1]["settings"]["servers"]
                self.assertEqual(server, {
                    "address": "2001:db8::50", "port": 1080,
                })

    def test_authenticated_generation_does_not_put_password_in_process_argv(self):
        native_popen = subprocess.Popen
        calls = []

        def recorded_popen(arguments, *args, **kwargs):
            calls.append(arguments)
            return native_popen(arguments, *args, **kwargs)

        for installer in ("debian", "alpine"):
            with self.subTest(installer=installer):
                calls.clear()
                with mock.patch.object(
                    subprocess, "Popen", side_effect=recorded_popen
                ):
                    route_configuration(installer)
                self.assertTrue(calls)
                for arguments in calls:
                    self.assertNotIn(
                        SOCKS_PASSWORD, "\n".join(map(str, arguments))
                    )

    def test_domains_are_normalized_and_deduplicated(self):
        raw = (
            "Example.COM,domain:example.com FULL:Exact.Example.NET "
            "sub.example.org\nfull:exact.example.net"
        )
        expected = (
            "domain:example.com\nfull:exact.example.net\n"
            "domain:sub.example.org"
        )
        for installer, source in (
            ("debian", installers.DEBIAN), ("alpine", installers.ALPINE),
        ):
            with self.subTest(installer=installer):
                output = installers.shell_run(
                    "set -e\n"
                    + source_functions(source, (
                        "fail", "validate_hostname", "validate_route_domain",
                        "normalize_route_domains",
                    ))
                    + '\nnormalize_route_domains\nprintf "%s\\n" "$route_domains"\n',
                    {"route_domains": raw},
                )
                self.assertEqual(output.strip(), expected)

    def test_routing_menu_defaults_retries_and_preserves_authentication(self):
        spaced_user = "  route user  "
        spaced_password = '  quoted "password\\ with spaces  '
        scenarios = [
            {
                "name": "default",
                "input": "\n",
                "mode": "1", "domains": "", "host": "", "port": "",
                "user": "", "password": "",
            },
            {
                "name": "ordinary",
                "input": "1\n",
                "mode": "1", "domains": "", "host": "", "port": "",
                "user": "", "password": "",
            },
            {
                "name": "invalid_retries_then_ordinary",
                "input": "invalid\n0\n4\n1\n",
                "mode": "1", "domains": "", "host": "", "port": "",
                "user": "", "password": "",
            },
            {
                "name": "unauthenticated_default_port",
                "input": "2\nExample.COM\n192.0.2.50\n\n\n",
                "mode": "2", "domains": "domain:example.com",
                "host": "192.0.2.50", "port": "1080",
                "user": "", "password": "",
            },
            {
                "name": "authenticated_ipv6_with_spaces",
                "input": (
                    "bad\n2\nExample.COM,full:Exact.Example.NET\n"
                    "[2001:db8::50]\n11080\n"
                    + spaced_user + "\n" + spaced_password + "\n"
                ),
                "mode": "2",
                "domains": "domain:example.com\nfull:exact.example.net",
                "host": "2001:db8::50", "port": "11080",
                "user": spaced_user, "password": spaced_password,
            },
        ]
        for installer, source in (
            ("debian", installers.DEBIAN), ("alpine", installers.ALPINE),
        ):
            functions = source_functions(source, (
                "fail", "validate_hostname", "validate_host", "validate_port",
                "validate_route_domain", "normalize_route_domains",
                "validate_route_auth", "select_routing_mode",
            )).replace(" >/dev/tty", "")
            for scenario in scenarios:
                with self.subTest(
                    installer=installer, scenario=scenario["name"]
                ):
                    values = {
                        "TEST_EXPECTED_" + name.upper(): scenario[name]
                        for name in (
                            "mode", "domains", "host", "port", "user", "password"
                        )
                    }
                    values.update({
                        name: "previous-value"
                        for name in (
                            "routing_mode", "route_domains", "route_host",
                            "route_port", "route_user", "route_password",
                        )
                    })
                    output = installers.shell_run(
                        "set -e\n" + functions
                        + "\nexec 3<<'MENU_TEST_INPUT'\n"
                        + scenario["input"]
                        + "MENU_INPUT_END\nMENU_TEST_INPUT\n"
                        + r'''
select_routing_mode
[ "$routing_mode" = "$TEST_EXPECTED_MODE" ]
[ "$route_domains" = "$TEST_EXPECTED_DOMAINS" ]
[ "$route_host" = "$TEST_EXPECTED_HOST" ]
[ "$route_port" = "$TEST_EXPECTED_PORT" ]
[ "$route_user" = "$TEST_EXPECTED_USER" ]
[ "$route_password" = "$TEST_EXPECTED_PASSWORD" ]
IFS= read -r menu_remainder <&3
[ "$menu_remainder" = MENU_INPUT_END ]
printf 'MENU_VALUES_VALID\n'
''',
                        values,
                    )
                    self.assertIn("MENU_VALUES_VALID", output)
                    if scenario["password"]:
                        self.assertNotIn(scenario["password"], output)

    def test_authentication_has_255_byte_protocol_limits(self):
        valid = [
            ("", ""),
            ("u", "p"),
            ("u" * 255, "p" * 255),
            ("\u540d" * 85, "\u5bc6" * 85),
            (SOCKS_USER, SOCKS_PASSWORD),
        ]
        invalid = [
            ("", "password"),
            ("user", ""),
            ("u" * 256, "password"),
            ("user", "p" * 256),
            ("\u540d" * 86, "password"),
            ("user", "\u5bc6" * 86),
        ]
        for installer, source in (
            ("debian", installers.DEBIAN), ("alpine", installers.ALPINE),
        ):
            code = (
                "set -e\n"
                + source_functions(source, ("fail", "validate_route_auth"))
                + '\nvalidate_route_auth\nprintf "VALID\\n"\n'
            )
            for username, password in valid:
                with self.subTest(
                    installer=installer, valid=True,
                    username_bytes=len(username.encode()),
                    password_bytes=len(password.encode()),
                ):
                    self.assertIn(
                        "VALID",
                        installers.shell_run(code, {
                            "route_user": username, "route_password": password,
                        }),
                    )
            for username, password in invalid:
                with self.subTest(
                    installer=installer, valid=False,
                    username_bytes=len(username.encode()),
                    password_bytes=len(password.encode()),
                ):
                    with self.assertRaises(subprocess.CalledProcessError):
                        installers.shell_run(code, {
                            "route_user": username, "route_password": password,
                        })

    def test_invalid_domains_and_upstream_inputs_are_rejected(self):
        for installer, source in (
            ("debian", installers.DEBIAN), ("alpine", installers.ALPINE),
        ):
            functions = source_functions(source, (
                "fail", "validate_hostname", "validate_host",
                "validate_port", "validate_route_domain",
            ))
            checks = [
                ("validate_route_domain", ""),
                ("validate_route_domain", "domain:"),
                ("validate_route_domain", "https://example.com"),
                ("validate_route_domain", "example.com/path"),
                ("validate_route_domain", "example.com:443"),
                ("validate_route_domain", "invalid_domain.example"),
                ("validate_route_domain", "*.example.com"),
                ("validate_route_domain", "192.0.2.1"),
                ("validate_route_domain", "domain:192.0.2.1"),
                ("validate_route_domain", "a" * 64 + ".example"),
                ("validate_route_domain", "full:" + "a" * 64 + ".example"),
                ("validate_route_domain", "example.com."),
                ("validate_host", ""),
                ("validate_host", "https://proxy.example"),
                ("validate_port", ""),
                ("validate_port", "0"),
                ("validate_port", "65536"),
                ("validate_port", "1080;exit"),
            ]
            for function, value in checks:
                with self.subTest(
                    installer=installer, function=function, value=value
                ):
                    with self.assertRaises(subprocess.CalledProcessError):
                        installers.shell_run(
                            "set -e\n" + functions
                            + '\n' + function + ' "$TEST_VALUE" test-label\n',
                            {"TEST_VALUE": value},
                        )


class DirectHandler(http.server.BaseHTTPRequestHandler):
    body = DIRECT_BODY

    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Length", str(len(self.body)))
        self.end_headers()
        self.wfile.write(self.body)

    def log_message(self, *_arguments):
        pass


class ProxiedHandler(DirectHandler):
    body = PROXY_BODY


class IPv6OnlyHTTPServer(http.server.ThreadingHTTPServer):
    address_family = socket.AF_INET6

    def server_bind(self):
        self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
        super().server_bind()


@contextlib.contextmanager
def serve_http(server):
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield server
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)


class AuthenticatedSocksHandler(socketserver.BaseRequestHandler):
    def handle(self):
        client = self.request
        client.settimeout(5)
        try:
            version, count = installers.receive_exact(client, 2)
            methods = installers.receive_exact(client, count)
            if version != 5 or 2 not in methods:
                client.sendall(b"\x05\xff")
                return
            client.sendall(b"\x05\x02")
            version, size = installers.receive_exact(client, 2)
            username = installers.receive_exact(client, size).decode()
            password_size = installers.receive_exact(client, 1)[0]
            password = installers.receive_exact(client, password_size).decode()
            if (
                version != 1 or username != SOCKS_USER
                or password != SOCKS_PASSWORD
            ):
                client.sendall(b"\x01\x01")
                return
            client.sendall(b"\x01\x00")
            version, command, _reserved, address_type = (
                installers.receive_exact(client, 4)
            )
            if address_type == 3:
                length = installers.receive_exact(client, 1)[0]
                target = installers.receive_exact(client, length).decode("ascii")
            elif address_type in (1, 4):
                family, length = (
                    (socket.AF_INET, 4) if address_type == 1
                    else (socket.AF_INET6, 16)
                )
                target = socket.inet_ntop(
                    family, installers.receive_exact(client, length)
                )
            else:
                return
            port, = struct.unpack("!H", installers.receive_exact(client, 2))
            self.server.requests.append((target, port, username))
            origin_address = self.server.origin_addresses.get(target)
            if (
                version != 5 or command != 1
                or port != self.server.origin_port or origin_address is None
            ):
                client.sendall(b"\x05\x02\x00\x01" + b"\x00" * 6)
                return
            with socket.create_connection(
                (origin_address, port), timeout=5
            ) as origin:
                client.sendall(b"\x05\x00\x00\x01" + b"\x00" * 6)
                while True:
                    readable, _, _ = select.select([client, origin], [], [], 5)
                    if not readable:
                        return
                    for source in readable:
                        destination = origin if source is client else client
                        data = source.recv(8192)
                        if not data:
                            return
                        destination.sendall(data)
        except (OSError, AssertionError):
            return


class AuthenticatedSocksServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True

    def __init__(self, origin_port):
        super().__init__(("127.0.0.1", 0), AuthenticatedSocksHandler)
        self.origin_port = origin_port
        self.origin_addresses = {
            target: "127.0.0.1" for target in PROXIED_DOMAINS
        }
        self.requests = []
        self.stopped = False
        self.thread = threading.Thread(
            target=self.serve_forever, daemon=True
        )
        self.thread.start()

    def stop(self):
        if not self.stopped:
            self.stopped = True
            self.shutdown()
            self.server_close()
            self.thread.join(timeout=5)


def request_http(socks_port, target, target_port, host_header=None):
    with socket.create_connection(
        ("127.0.0.1", socks_port), timeout=5
    ) as client:
        client.settimeout(4)
        client.sendall(b"\x05\x01\x00")
        if installers.receive_exact(client, 2) != b"\x05\x00":
            raise AssertionError("Local SOCKS ingress rejected the request")
        encoded = (host_header or target).encode("ascii")
        try:
            address = b"\x01" + socket.inet_pton(socket.AF_INET, target)
        except OSError:
            try:
                address = b"\x04" + socket.inet_pton(socket.AF_INET6, target)
            except OSError:
                target_bytes = target.encode("ascii")
                address = b"\x03" + bytes([len(target_bytes)]) + target_bytes
        client.sendall(
            b"\x05\x01\x00" + address
            + struct.pack("!H", target_port)
        )
        try:
            response = installers.receive_exact(client, 4)
            if response[:2] != b"\x05\x00":
                return b""
            size = {1: 4, 4: 16}.get(response[3])
            if response[3] == 3:
                size = installers.receive_exact(client, 1)[0]
            if size is None:
                raise AssertionError("Invalid local SOCKS response address")
            installers.receive_exact(client, size + 2)
            client.sendall(
                b"GET / HTTP/1.1\r\nHost: " + encoded
                + b"\r\nConnection: close\r\n\r\n"
            )
            data = b""
            while True:
                packet = client.recv(8192)
                if not packet:
                    return data
                data += packet
                if PROXY_BODY in data or DIRECT_BODY in data:
                    return data
        except (OSError, AssertionError):
            return b""


@unittest.skipUnless(
    installers.XRAY, "Set XRAY_TEST_BIN for real custom routing tests"
)
class OptionalRoutingXrayTests(unittest.TestCase):
    def test_all_generated_custom_routing_configurations_validate(self):
        for installer in ("debian", "alpine"):
            for mode in ("1", "2", "3", "4"):
                for family in installers.FAMILY_STRATEGIES:
                    with self.subTest(
                        installer=installer, mode=mode, family=family
                    ):
                        config = route_configuration(
                            installer, mode=mode, family=family
                        )
                        with tempfile.TemporaryDirectory() as directory:
                            path = Path(directory) / "config.json"
                            path.write_text(json.dumps(config), encoding="utf-8")
                            process = subprocess.run(
                                [
                                    installers.XRAY, "run", "-test",
                                    "-config", str(path),
                                ],
                                capture_output=True, text=True,
                            )
                        self.assertEqual(
                            process.returncode, 0,
                            process.stdout + process.stderr,
                        )

    def test_ws_chain_uses_remote_socks_for_matches_and_ipv6_for_others(self):
        for installer in ("debian", "alpine"):
            with self.subTest(installer=installer):
                self.check_live_chain(installer)

    def check_live_chain(self, installer):
        ipv4_origin = http.server.ThreadingHTTPServer(
            ("127.0.0.1", 0), ProxiedHandler
        )
        origin_port = ipv4_origin.server_port
        try:
            ipv6_origin = IPv6OnlyHTTPServer(
                ("::1", origin_port), DirectHandler
            )
        except OSError as error:
            ipv4_origin.server_close()
            self.skipTest(f"IPv6 loopback is unavailable: {error}")
        upstream = AuthenticatedSocksServer(origin_port)
        try:
            with serve_http(ipv4_origin), serve_http(ipv6_origin):
                config = route_configuration(
                    installer, family="2", host="127.0.0.1",
                    port=str(upstream.server_address[1]),
                )
                ws_port, socks_port = installers.free_port(), installers.free_port()
                config["log"]["loglevel"] = "debug"
                config["inbounds"][0].update(
                    listen="127.0.0.1", port=ws_port
                )
                # Allow only the temporary IPv6 origin; preserve IPv4 blocking.
                config["outbounds"][0]["settings"]["finalRules"].append({
                    "action": "allow", "network": "tcp",
                    "ip": ["::1/128"], "port": str(origin_port),
                })
                targets = [
                    *PROXIED_DOMAINS,
                    "child." + EXACT_DOMAIN, DIRECT_DOMAIN,
                ]
                config["dns"] = {
                    "hosts": {target: "::1" for target in targets},
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
                            "users": [{
                                "id": installers.UUID, "encryption": "none",
                            }],
                        }]},
                        "streamSettings": {
                            "network": "ws", "security": "none",
                            "wsSettings": {"path": installers.WS_PATH},
                        },
                    }],
                }
                with (
                    installers.running_xray(config, ws_port),
                    installers.running_xray(client, socks_port),
                ):
                    for target in targets[:3]:
                        with self.subTest(target=target, route="socks"):
                            response = request_http(
                                socks_port, target, origin_port
                            )
                            self.assertIn(PROXY_BODY, response)
                            self.assertNotIn(DIRECT_BODY, response)
                    for target in targets[3:]:
                        with self.subTest(target=target, route="direct"):
                            response = request_http(
                                socks_port, target, origin_port
                            )
                            self.assertIn(DIRECT_BODY, response)
                            self.assertNotIn(PROXY_BODY, response)
                    wrong_addresses = ("192.0.2.123", "2001:db8::123")
                    for address in wrong_addresses:
                        with self.subTest(target=address, route="sniffed-domain"):
                            sniffed = request_http(
                                socks_port, address, origin_port,
                                host_header=SUFFIX_DOMAIN,
                            )
                            self.assertIn(
                                PROXY_BODY, sniffed,
                                "The matching HTTP Host must replace a wrong IP",
                            )
                            self.assertNotIn(DIRECT_BODY, sniffed)
                    self.assertEqual(
                        [request[0] for request in upstream.requests],
                        [*PROXIED_DOMAINS, *(
                            SUFFIX_DOMAIN for _ in wrong_addresses
                        )],
                    )
                    self.assertTrue(all(
                        request[2] == SOCKS_USER
                        for request in upstream.requests
                    ))
                    upstream.stop()
                    failed = request_http(
                        socks_port, SUFFIX_DOMAIN, origin_port
                    )
                    self.assertNotIn(
                        DIRECT_BODY, failed,
                        "A selected upstream failure must not leak via direct",
                    )
                    ordinary = request_http(
                        socks_port, DIRECT_DOMAIN, origin_port
                    )
                    self.assertIn(
                        DIRECT_BODY, ordinary,
                        "An upstream outage must not break ordinary traffic",
                    )
        finally:
            upstream.stop()


if __name__ == "__main__":
    unittest.main()
