import base64
import contextlib
import copy
import http.server
import json
import os
from pathlib import Path
import re
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from urllib.parse import parse_qs, unquote, urlsplit


ROOT = Path(__file__).resolve().parents[1]
ALPINE = (ROOT / "install-alpine.sh").read_text(encoding="utf-8")
DEBIAN = (ROOT / "install.sh").read_text(encoding="utf-8")
PY_BLOCKS = re.findall(r"<<'PY'\n(.*?)\nPY", DEBIAN, re.S)
SHELL = os.environ.get("INSTALLER_TEST_SHELL") or shutil.which("sh")
JQ = os.environ.get("JQ_TEST_BIN") or shutil.which("jq")
XRAY = os.environ.get("XRAY_TEST_BIN")
UUID = "00000000-0000-4000-8000-000000000001"
KEY = base64.urlsafe_b64encode(bytes(range(32))).decode().rstrip("=")
SID = "0123456789abcdef"
WS_PATH = "/ws-0123456789abcdef"
NAME = "NAT test & # \u8282\u70b9"
FAMILY_STRATEGIES = {"1": "ForceIPv4", "2": "ForceIPv6", "3": "UseIP"}


def variables(mode, host="198.51.100.20", address_family="3", listen_address=None):
    return {
        "node_type": mode,
        "address_family": address_family,
        "public_host": host,
        "public_port": "30860",
        "listen_port": "31001",
        "listen_address": listen_address or ("::" if ":" in host else "0.0.0.0"),
        "uuid": UUID,
        "private_key": KEY if mode == "1" else "",
        "public_key": KEY if mode == "1" else "",
        "short_id": SID if mode == "1" else "",
        "server_name": "gateway.icloud.com" if mode == "1" else "",
        "ws_path": WS_PATH if mode == "2" else "",
        "cdn_domain": "cdn.example.com" if mode == "2" else "",
        "cdn_port": "443" if mode == "2" else "",
        "node_name": NAME,
    }


def shell_run(code, values):
    if not SHELL or not JQ:
        raise unittest.SkipTest("POSIX shell and jq are required")
    env = os.environ.copy()
    env.update(values)
    # Avoid Git Bash rewriting WS paths passed to a native Windows jq binary.
    env["MSYS_NO_PATHCONV"] = "1"
    env["TEST_JQ"] = Path(JQ).resolve().as_posix()
    return subprocess.check_output(
        [SHELL, "-c", 'jq() { "$TEST_JQ" "$@"; }\n' + code],
        env=env, text=True, encoding="utf-8",
    )


def python_env(values):
    env = os.environ.copy()
    env["PYTHONIOENCODING"] = "utf-8"
    mapping = {
        "node_type": "NODE_TYPE", "address_family": "ADDRESS_FAMILY", "ws_path": "WS_PATH",
        "listen_address": "LISTEN_ADDRESS", "listen_port": "LISTEN_PORT",
        "uuid": "UUID", "private_key": "PRIVATE_KEY", "public_key": "PUBLIC_KEY",
        "short_id": "SHORT_ID", "server_name": "SERVER_NAME",
        "public_host": "PUBLIC_HOST", "public_port": "PUBLIC_PORT",
        "node_name": "NODE_NAME", "cdn_domain": "CDN_DOMAIN",
        "cdn_port": "CDN_PORT",
    }
    env.update({"XRAY_" + target: values[source] for source, target in mapping.items()})
    return env


def configuration(installer, mode, host="198.51.100.20", address_family="3", listen_address=None):
    values = variables(mode, host, address_family, listen_address)
    with tempfile.TemporaryDirectory() as directory:
        output = Path(directory) / "config.json"
        if installer == "alpine":
            start = ALPINE.index("jq -n \\\n")
            end = ALPINE.index('\n"$tmp_dir/xray" run -test', start)
            values["tmp_dir"] = Path(directory).as_posix()
            shell_run(ALPINE[start:end], values)
        else:
            subprocess.run(
                [sys.executable, "-c", PY_BLOCKS[0], str(output)],
                env=python_env(values), check=True,
            )
        return json.loads(output.read_text(encoding="utf-8"))


def link(installer, mode, host, address_family="3"):
    values = variables(mode, host, address_family)
    if installer == "alpine":
        start = ALPINE.index('case "$public_host" in\n  *:*) case')
        end = ALPINE.index("# Clean both the release archive", start)
        output_start = ALPINE.index("printf '\\nXray 服务已启动。")
        output = shell_run(ALPINE[start:end] + ALPINE[output_start:], values)
    else:
        output = subprocess.check_output(
            [sys.executable, "-c", PY_BLOCKS[1]],
            env=python_env(values), text=True, encoding="utf-8",
        )
    links = [line for line in output.splitlines() if line.startswith("vless://")]
    if len(links) != 1:
        raise AssertionError("Expected exactly one VLESS import link")
    return links[0]


def shell_function(source, name):
    match = re.search(r"^" + re.escape(name) + r"\(\) \{\n.*?^\}", source, re.M | re.S)
    if match is None:
        raise AssertionError(f"Missing shell function: {name}")
    return match.group(0)


class AddressFamilyTests(unittest.TestCase):
    def test_detection_uses_successful_egress_probes(self):
        mock_curl = r'''
curl() {
  printf 'PROBE %s\n' "$*" >&4
  probe_family=
  probe_endpoint=
  for argument in "$@"; do
    case "$argument" in
      -4) probe_family=4 ;;
      -6) probe_family=6 ;;
      https://*) probe_endpoint=$argument ;;
    esac
  done
  case "$probe_family:$probe_endpoint" in
    4:https://www.cloudflare.com/cdn-cgi/trace) return "$MOCK_V4_PRIMARY" ;;
    4:https://www.google.com/generate_204) return "$MOCK_V4_FALLBACK" ;;
    6:https://www.cloudflare.com/cdn-cgi/trace) return "$MOCK_V6_PRIMARY" ;;
    6:https://www.google.com/generate_204) return "$MOCK_V6_FALLBACK" ;;
    *) return 99 ;;
  esac
}
'''
        scenarios = (
            ("ipv4_only", (0, 0, 7, 7), (1, 0), 3),
            ("ipv6_only", (7, 7, 0, 0), (0, 1), 3),
            ("dual_stack", (0, 0, 0, 0), (1, 1), 2),
            ("neither", (7, 7, 7, 7), (0, 0), 4),
            ("fallback", (28, 0, 22, 0), (1, 1), 4),
            ("timeouts", (28, 28, 28, 28), (0, 0), 4),
            ("http_errors", (22, 22, 22, 22), (0, 0), 4),
        )
        for installer, source in (("alpine", ALPINE), ("debian", DEBIAN)):
            functions = "\n".join(shell_function(source, name) for name in (
                "probe_address_family", "detect_address_families",
            ))
            for name, statuses, expected, attempts in scenarios:
                with self.subTest(installer=installer, scenario=name):
                    env = dict(zip((
                        "MOCK_V4_PRIMARY", "MOCK_V4_FALLBACK",
                        "MOCK_V6_PRIMARY", "MOCK_V6_FALLBACK",
                    ), map(str, statuses)))
                    # A successful local proxy must never mask broken native egress.
                    env.update(HTTP_PROXY="http://127.0.0.1:9",
                               HTTPS_PROXY="http://127.0.0.1:9",
                               ALL_PROXY="socks5://127.0.0.1:9")
                    output = shell_run(
                        "set -e\nexec 4>&1\n" + mock_curl + functions
                        + '\ndetect_address_families\nprintf "RESULT %s %s\\n" '
                          '"$detected_v4" "$detected_v6"\n',
                        env,
                    )
                    self.assertIn("RESULT %s %s" % expected, output)
                    calls = [line for line in output.splitlines() if line.startswith("PROBE ")]
                    self.assertEqual(len(calls), attempts)
                    for call in calls:
                        self.assertIn("--disable", call)
                        self.assertIn("--noproxy *", call)
                        self.assertIn("--proto =https", call)
                        self.assertIn("--connect-timeout 3", call)
                        self.assertIn("--max-time 5", call)
                        self.assertIn("--fail", call)
                        self.assertIn("--output /dev/null", call)

    def test_selection_defaults_and_retries(self):
        scenarios = (
            ("dual_default", 1, 1, "\n", "3"),
            ("ipv4_default", 1, 0, "\n", "1"),
            ("ipv6_default", 0, 1, "\n", "2"),
            ("choose_ipv4", 1, 1, "1\n", "1"),
            ("choose_ipv6", 1, 1, "2\n", "2"),
            ("invalid_retry", 1, 1, "invalid\n4\n2\n", "2"),
            ("ipv4_only_rejects_other_families", 1, 0, "2\n3\n1\n", "1"),
            ("ipv6_only_rejects_other_families", 0, 1, "1\n3\n2\n", "2"),
        )
        for installer, source in (("alpine", ALPINE), ("debian", DEBIAN)):
            function = shell_function(source, "select_address_family")
            for name, detected_v4, detected_v6, choices, expected in scenarios:
                with self.subTest(installer=installer, scenario=name):
                    output = shell_run(
                        "set -e\nfail() { printf '%s\\n' \"$*\" >&2; exit 1; }\n"
                        + function + "\nexec 3<<'TEST_INPUT'\n"
                        + choices + "TEST_INPUT\nselect_address_family\n"
                          'printf "RESULT %s\\n" "$address_family"\n',
                        {"detected_v4": str(detected_v4), "detected_v6": str(detected_v6)},
                    )
                    self.assertIn("RESULT " + expected, output)

    def test_detection_and_selection_precede_protocol_choice(self):
        for installer, source in (("alpine", ALPINE), ("debian", DEBIAN)):
            with self.subTest(installer=installer):
                detection = re.search(r"^detect_address_families\s*$", source, re.M)
                selection = re.search(r"^select_address_family\s*$", source, re.M)
                self.assertIsNotNone(detection)
                self.assertIsNotNone(selection)
                self.assertLess(detection.start(), selection.start())
                self.assertLess(selection.start(), source.index("\u8282\u70b9\u7c7b\u578b\uff1a"))

    def test_interactive_prompts_are_chinese_and_ordered(self):
        prompts = {
            "egress": "\u8282\u70b9\u51fa\u7ad9\u65b9\u5f0f\uff1a",
            "node": "\u8282\u70b9\u7c7b\u578b\uff1a",
            "public_host": "\u516c\u7f51 IP \u6216\u57df\u540d",
            "public_port": "\u670d\u52a1\u5546\u6620\u5c04\u7684\u516c\u7f51 TCP \u7aef\u53e3\uff1a",
            "listen_port": "\u672c\u673a\u76d1\u542c\u7aef\u53e3",
            "reality_sni": "REALITY SNI",
            "cdn_domain": "\u0043\u0044\u004e \u57df\u540d\uff08SNI \u548c WebSocket Host\uff09\uff1a",
            "node_name": "\u8282\u70b9\u540d\u79f0",
        }
        for installer, source in (("alpine", ALPINE), ("debian", DEBIAN)):
            with self.subTest(installer=installer):
                positions = {}
                for name, label in prompts.items():
                    positions[name] = source.find(label)
                    self.assertGreaterEqual(
                        positions[name], 0, f"{installer} is missing prompt: {label}"
                    )
                self.assertLess(positions["egress"], positions["node"])
                self.assertLess(positions["node"], positions["public_host"])
                self.assertLess(positions["public_host"], positions["public_port"])
                self.assertLess(positions["public_port"], positions["listen_port"])
                self.assertLess(positions["listen_port"], positions["node_name"])


class GeneratorTests(unittest.TestCase):
    def test_configuration_modes_and_platform_parity(self):
        for mode in ("1", "2"):
            for host in ("198.51.100.20", "2001:db8::20"):
                reference_inbound = None
                for family, strategy in FAMILY_STRATEGIES.items():
                    with self.subTest(mode=mode, host=host, family=family):
                        config = configuration("debian", mode, host, family)
                        self.assertEqual(config, configuration("alpine", mode, host, family))
                        inbound, = config["inbounds"]
                        self.assertEqual(inbound["port"], 31001)
                        self.assertEqual(inbound["listen"], "::" if ":" in host else "0.0.0.0")
                        if reference_inbound is None:
                            reference_inbound = inbound
                        self.assertEqual(inbound, reference_inbound,
                                         "Egress family must not alter incoming connections")
                        outbound, = config["outbounds"]
                        self.assertEqual(outbound["protocol"], "freedom")
                        self.assertEqual(outbound["tag"], "direct")
                        expected_settings = {}
                        expected_sockopt = {"domainStrategy": strategy}
                        if family == "3":
                            expected_sockopt["happyEyeballs"] = {
                                "tryDelayMs": 250, "prioritizeIPv6": True,
                                "interleave": 1, "maxConcurrentTry": 2,
                            }
                        else:
                            expected_settings["finalRules"] = [{
                                "action": "block",
                                "ip": ["::/0" if family == "1" else "0.0.0.0/0"],
                                "blockDelay": "0",
                            }]
                        self.assertEqual(outbound["settings"], expected_settings)
                        self.assertEqual(outbound["streamSettings"], {"sockopt": expected_sockopt})
                        self.assertNotIn("dns", config)
                        self.assertNotIn("routing", config)
                        client, = inbound["settings"]["clients"]
                        self.assertEqual(client["id"], UUID)
                        stream = inbound["streamSettings"]
                        if mode == "1":
                            self.assertEqual(client["flow"], "xtls-rprx-vision")
                            self.assertEqual(stream["security"], "reality")
                            self.assertEqual(stream["network"], "raw")
                            self.assertEqual(stream["realitySettings"]["target"], "gateway.icloud.com:443")
                            self.assertEqual(stream["realitySettings"]["shortIds"], [SID])
                            self.assertNotIn("wsSettings", stream)
                        else:
                            self.assertNotIn("flow", client)
                            self.assertEqual(stream, {
                                "network": "ws", "security": "none",
                                "wsSettings": {"path": WS_PATH},
                            })
                            self.assertNotIn("icloud.com", json.dumps(config))

    def test_listener_is_independent_of_outbound_family(self):
        for installer in ("alpine", "debian"):
            for family in FAMILY_STRATEGIES:
                with self.subTest(installer=installer, family=family):
                    config = configuration(installer, "2", "198.51.100.20", family, "::")
                    self.assertEqual(config["inbounds"][0]["listen"], "::")

    def test_links_and_platform_parity(self):
        for mode in ("1", "2"):
            for host in ("198.51.100.20", "2001:db8::20", "[2001:db8::20]"):
                with self.subTest(mode=mode, host=host):
                    uri = link("debian", mode, host)
                    self.assertEqual(uri, link("alpine", mode, host))
                    parsed = urlsplit(uri)
                    self.assertEqual(parsed.username, UUID)
                    expected_host = host.strip("[]") if mode == "1" else "cdn.example.com"
                    expected_port = 30860 if mode == "1" else 443
                    self.assertEqual(parsed.hostname, expected_host)
                    self.assertEqual(parsed.port, expected_port)
                    self.assertEqual(unquote(parsed.fragment), NAME)
                    query = parse_qs(parsed.query)
                    if mode == "1":
                        self.assertEqual(query, {
                            "encryption": ["none"], "flow": ["xtls-rprx-vision"],
                            "security": ["reality"], "sni": ["gateway.icloud.com"],
                            "fp": ["chrome"], "pbk": [KEY], "sid": [SID], "type": ["tcp"],
                        })
                    else:
                        self.assertEqual(query, {
                            "encryption": ["none"], "security": ["tls"],
                            "sni": ["cdn.example.com"], "fp": ["chrome"],
                            "type": ["ws"], "host": ["cdn.example.com"],
                            "path": [WS_PATH],
                        })

    def test_egress_selection_preserves_single_client_link(self):
        for installer in ("alpine", "debian"):
            for mode in ("1", "2"):
                for host in ("198.51.100.20", "2001:db8::20"):
                    with self.subTest(installer=installer, mode=mode, host=host):
                        uris = [link(installer, mode, host, family) for family in FAMILY_STRATEGIES]
                        self.assertEqual(uris, [uris[0]] * len(uris))

    def test_apple_default_and_service_safety(self):
        self.assertIn("DEFAULT_SNI=gateway.icloud.com", ALPINE)
        self.assertIn('DEFAULT_SNI="gateway.icloud.com"', DEBIAN)
        self.assertIn("CDN 域名（SNI 和 WebSocket Host）", ALPINE)
        self.assertIn("CDN 域名（SNI 和 WebSocket Host）", DEBIAN)
        self.assertNotIn("Preferred CDN edge", ALPINE)
        self.assertNotIn("Preferred CDN edge", DEBIAN)
        self.assertIn("validate_hostname", ALPINE)
        self.assertIn("validate_hostname", DEBIAN)
        self.assertIn("rc-update add xray default", ALPINE)
        self.assertIn("systemctl enable xray.service", DEBIAN)
        self.assertIn("command_user=nobody:$service_group", ALPINE)
        self.assertIn("export GOGC=50", ALPINE)
        self.assertIn("An Xray installation already exists", ALPINE)
        self.assertIn("refusing to overwrite an existing setup", DEBIAN)


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


@contextlib.contextmanager
def running_xray(config, port):
    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory) / "config.json"
        path.write_text(json.dumps(config), encoding="utf-8")
        with tempfile.TemporaryFile() as log:
            process = subprocess.Popen(
                [XRAY, "run", "-config", str(path)],
                stdout=log, stderr=log,
            )
            failure = None
            try:
                for _ in range(100):
                    if process.poll() is not None:
                        log.seek(0)
                        raise AssertionError(log.read().decode(errors="replace"))
                    try:
                        with socket.create_connection(("127.0.0.1", port), timeout=0.1):
                            break
                    except OSError:
                        time.sleep(0.05)
                else:
                    raise AssertionError("Xray did not listen in time")
                yield
            except Exception as exc:
                failure = exc
                raise
            finally:
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait(timeout=5)
                if failure is not None:
                    log.seek(0)
                    diagnostics = log.read().decode(errors="replace")
                    if hasattr(failure, "add_note"):
                        failure.add_note(diagnostics)
                    else:
                        print(diagnostics, file=sys.stderr)


class TraceHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = b"ws-origin-regression-ok"
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_args):
        pass


class IPv6HTTPServer(http.server.ThreadingHTTPServer):
    address_family = socket.AF_INET6


def receive_exact(sock, length):
    data = b""
    while len(data) < length:
        part = sock.recv(length - len(data))
        if not part:
            raise AssertionError("Unexpected end of SOCKS reply")
        data += part
    return data


def socks_get(port, target, target_port):
    with socket.create_connection(("127.0.0.1", port), timeout=5) as sock:
        sock.sendall(b"\x05\x01\x00")
        if receive_exact(sock, 2) != b"\x05\x00":
            raise AssertionError("SOCKS server rejected unauthenticated connection")
        try:
            address = b"\x01" + socket.inet_pton(socket.AF_INET, target)
        except OSError:
            try:
                address = b"\x04" + socket.inet_pton(socket.AF_INET6, target)
            except OSError:
                encoded = target.encode("ascii")
                address = b"\x03" + bytes([len(encoded)]) + encoded
        sock.sendall(b"\x05\x01\x00" + address + struct.pack("!H", target_port))
        reply = receive_exact(sock, 4)
        if reply[:2] != b"\x05\x00":
            return b""
        size = {1: 4, 4: 16}.get(reply[3])
        if reply[3] == 3:
            size = receive_exact(sock, 1)[0]
        if size is None:
            raise AssertionError("Invalid SOCKS address type")
        receive_exact(sock, size + 2)
        sock.settimeout(2)
        try:
            sock.sendall(b"GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
            response = b""
            while b"ws-origin-regression-ok" not in response:
                data = sock.recv(4096)
                if not data:
                    break
                response += data
            return response
        except (ConnectionResetError, ConnectionAbortedError, TimeoutError):
            return b""


@unittest.skipUnless(XRAY, "Set XRAY_TEST_BIN for Xray validation and WS forwarding")
class XrayTests(unittest.TestCase):
    def test_generated_configurations(self):
        for installer in ("alpine", "debian"):
            for mode in ("1", "2"):
                for host in ("198.51.100.20", "2001:db8::20"):
                    for family in FAMILY_STRATEGIES:
                        with self.subTest(installer=installer, mode=mode, host=host, family=family):
                            config = configuration(installer, mode, host, family)
                            with tempfile.TemporaryDirectory() as directory:
                                path = Path(directory) / "config.json"
                                path.write_text(json.dumps(config), encoding="utf-8")
                                result = subprocess.run(
                                    [XRAY, "run", "-test", "-config", str(path)],
                                    capture_output=True, text=True,
                                )
                                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_egress_family_enforcement_and_dual_fallback(self):
        try:
            ipv6_origin = IPv6HTTPServer(("::1", 0), TraceHandler)
        except OSError as exc:
            self.skipTest(f"IPv6 loopback is unavailable: {exc}")
        ipv4_origin = http.server.ThreadingHTTPServer(("127.0.0.1", 0), TraceHandler)
        origins = (ipv4_origin, ipv6_origin)
        threads = [threading.Thread(target=origin.serve_forever, daemon=True) for origin in origins]
        for thread in threads:
            thread.start()
        try:
            for installer in ("alpine", "debian"):
                for family in FAMILY_STRATEGIES:
                    with self.subTest(installer=installer, family=family):
                        config = configuration(installer, "2", address_family=family)
                        port = free_port()
                        config["inbounds"] = [{
                            "listen": "127.0.0.1", "port": port,
                            "protocol": "socks", "settings": {"auth": "noauth"},
                        }]
                        rules = config["outbounds"][0]["settings"].setdefault("finalRules", [])
                        rules.extend({
                            "action": "allow", "network": "tcp", "ip": [cidr],
                            "port": str(origin.server_port),
                        } for cidr, origin in zip(("127.0.0.1/32", "::1/128"), origins))
                        with running_xray(config, port):
                            for target, origin, allowed in (
                                ("127.0.0.1", ipv4_origin, family in ("1", "3")),
                                ("::1", ipv6_origin, family in ("2", "3")),
                            ):
                                with self.subTest(target=target):
                                    response = socks_get(port, target, origin.server_port)
                                    self.assertEqual(b"ws-origin-regression-ok" in response, allowed)
                with self.subTest(installer=installer, scenario="dual_ipv4_fallback"):
                    config = configuration(installer, "2")
                    port = free_port()
                    config["inbounds"] = [{
                        "listen": "127.0.0.1", "port": port,
                        "protocol": "socks", "settings": {"auth": "noauth"},
                    }]
                    config["dns"] = {
                        "hosts": {"nat-test.invalid": ["::1", "127.0.0.1"]},
                        "servers": ["localhost"],
                    }
                    config["outbounds"][0]["settings"]["finalRules"] = [{
                        "action": "allow", "network": "tcp",
                        "ip": ["127.0.0.1/32", "::1/128"],
                        "port": str(ipv4_origin.server_port),
                    }]
                    with running_xray(config, port):
                        response = socks_get(port, "nat-test.invalid", ipv4_origin.server_port)
                        self.assertIn(b"ws-origin-regression-ok", response)
        finally:
            for origin in origins:
                origin.shutdown()
                origin.server_close()
            for thread in threads:
                thread.join(timeout=5)

    def test_ws_forwarding(self):
        for installer in ("alpine", "debian"):
            with self.subTest(installer=installer):
                config = configuration(installer, "2")
                server_port, socks_port = free_port(), free_port()
                config = copy.deepcopy(config)
                config["log"]["loglevel"] = "debug"
                config["inbounds"][0].update(listen="127.0.0.1", port=server_port)
                client = {
                    "log": {"loglevel": "debug"},
                    "inbounds": [{
                        "listen": "127.0.0.1", "port": socks_port,
                        "protocol": "socks", "settings": {"auth": "noauth"},
                    }],
                    "outbounds": [{
                        "protocol": "vless",
                        "settings": {"vnext": [{
                            "address": "127.0.0.1", "port": server_port,
                            "users": [{"id": UUID, "encryption": "none"}],
                        }]},
                        "streamSettings": {
                            "network": "ws", "security": "none",
                            "wsSettings": {
                                "path": WS_PATH, "headers": {"Host": "cdn.example.invalid"},
                            },
                        },
                    }],
                }
                origin = http.server.ThreadingHTTPServer(("127.0.0.1", 0), TraceHandler)
                # Newer cores block loopback exits; allow only this temporary test target.
                config["outbounds"][0].setdefault("settings", {})["finalRules"] = [{
                    "action": "allow", "network": "tcp", "ip": ["127.0.0.1/32"],
                    "port": str(origin.server_port),
                }]
                thread = threading.Thread(target=origin.serve_forever, daemon=True)
                thread.start()
                try:
                    with running_xray(config, server_port), running_xray(client, socks_port):
                        with socket.create_connection(("127.0.0.1", socks_port), timeout=5) as sock:
                            sock.sendall(b"\x05\x01\x00")
                            self.assertEqual(receive_exact(sock, 2), b"\x05\x00")
                            request = b"\x05\x01\x00\x01\x7f\x00\x00\x01"
                            sock.sendall(request + struct.pack("!H", origin.server_port))
                            reply = receive_exact(sock, 4)
                            self.assertEqual(reply[:2], b"\x05\x00")
                            address_size = {1: 4, 4: 16}.get(reply[3])
                            if reply[3] == 3:
                                address_size = receive_exact(sock, 1)[0]
                            self.assertIsNotNone(address_size)
                            receive_exact(sock, address_size + 2)
                            sock.sendall(b"GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
                            response = b""
                            while b"ws-origin-regression-ok" not in response:
                                data = sock.recv(4096)
                                if not data:
                                    break
                                response += data
                            self.assertIn(b"200 OK", response)
                            self.assertIn(b"ws-origin-regression-ok", response)
                finally:
                    origin.shutdown()
                    origin.server_close()
                    thread.join(timeout=5)


if __name__ == "__main__":
    unittest.main()
