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


def variables(mode, host="198.51.100.20"):
    return {
        "node_type": mode,
        "public_host": host,
        "public_port": "30860",
        "listen_port": "31001",
        "listen_address": "::" if ":" in host else "0.0.0.0",
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
        "node_type": "NODE_TYPE", "ws_path": "WS_PATH",
        "listen_address": "LISTEN_ADDRESS", "listen_port": "LISTEN_PORT",
        "uuid": "UUID", "private_key": "PRIVATE_KEY", "public_key": "PUBLIC_KEY",
        "short_id": "SHORT_ID", "server_name": "SERVER_NAME",
        "public_host": "PUBLIC_HOST", "public_port": "PUBLIC_PORT",
        "node_name": "NODE_NAME", "cdn_domain": "CDN_DOMAIN",
        "cdn_port": "CDN_PORT",
    }
    env.update({"XRAY_" + target: values[source] for source, target in mapping.items()})
    return env


def configuration(installer, mode, host="198.51.100.20"):
    values = variables(mode, host)
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


def link(installer, mode, host):
    values = variables(mode, host)
    if installer == "alpine":
        start = ALPINE.index('case "$public_host" in\n  *:*) case')
        end = ALPINE.index("# Clean both the release archive", start)
        output_start = ALPINE.index("printf '\\nXray service is active.")
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


class GeneratorTests(unittest.TestCase):
    def test_configuration_modes_and_platform_parity(self):
        for mode in ("1", "2"):
            for host in ("198.51.100.20", "2001:db8::20"):
                with self.subTest(mode=mode, host=host):
                    config = configuration("debian", mode, host)
                    self.assertEqual(config, configuration("alpine", mode, host))
                    inbound, = config["inbounds"]
                    self.assertEqual(inbound["port"], 31001)
                    self.assertEqual(inbound["listen"], "::" if ":" in host else "0.0.0.0")
                    self.assertEqual(config["outbounds"], [{"protocol": "freedom", "tag": "direct"}])
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

    def test_apple_default_and_service_safety(self):
        self.assertIn("DEFAULT_SNI=gateway.icloud.com", ALPINE)
        self.assertIn('DEFAULT_SNI="gateway.icloud.com"', DEBIAN)
        self.assertIn("CDN domain (SNI and WebSocket Host)", ALPINE)
        self.assertIn("CDN domain (SNI and WebSocket Host)", DEBIAN)
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


def receive_exact(sock, length):
    data = b""
    while len(data) < length:
        part = sock.recv(length - len(data))
        if not part:
            raise AssertionError("Unexpected end of SOCKS reply")
        data += part
    return data


@unittest.skipUnless(XRAY, "Set XRAY_TEST_BIN for Xray validation and WS forwarding")
class XrayTests(unittest.TestCase):
    def test_generated_configurations(self):
        for installer in ("alpine", "debian"):
            for mode in ("1", "2"):
                for host in ("198.51.100.20", "2001:db8::20"):
                    with self.subTest(installer=installer, mode=mode, host=host):
                        config = configuration(installer, mode, host)
                        with tempfile.TemporaryDirectory() as directory:
                            path = Path(directory) / "config.json"
                            path.write_text(json.dumps(config), encoding="utf-8")
                            result = subprocess.run(
                                [XRAY, "run", "-test", "-config", str(path)],
                                capture_output=True, text=True,
                            )
                            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

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
                config["outbounds"][0]["settings"] = {"finalRules": [{
                    "action": "allow", "network": "tcp", "ip": ["127.0.0.1/32"],
                    "port": str(origin.server_port),
                }]}
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
