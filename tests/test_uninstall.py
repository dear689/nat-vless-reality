import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "uninstall.sh").read_text(encoding="utf-8")
SHELL = os.environ.get("INSTALLER_TEST_SHELL") or shutil.which("sh")


def shell_path(path):
    value = Path(path).resolve().as_posix()
    if os.name == "nt":
        return "/" + value[0].lower() + value[2:]
    return value


@unittest.skipUnless(SHELL, "A POSIX shell is required")
class UninstallTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        # All filesystem operations stay in the fixture, including parent checks.
        self.source = re.sub(
            r"(?<![\w/.-])(?:/usr/local|/etc|/run/systemd/system)",
            lambda match: shell_path(self.root) + match.group(0),
            SOURCE,
        )
        self.log = self.root / "service.log"

    def put(self, path, content="fixture"):
        target = self.root / path.lstrip("/")
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content, encoding="utf-8", newline="\n")
        return target

    def fixture(self, platform, tunnel=True, marker=True):
        if platform == "alpine":
            self.put("/etc/alpine-release", "3.24.2")
            xray_service = "/etc/init.d/xray"
            tunnel_service = "/etc/init.d/cloudflared-nat-vless"
            content = (
                'description="VLESS server"\n'
                f"command={shell_path(self.root)}/usr/local/bin/xray\n"
                f'command_args="run -config {shell_path(self.root)}/usr/local/etc/xray/config.json"\n'
                "command_user=nobody:nobody\n"
            )
            self.put("/etc/runlevels/default/xray")
            if tunnel:
                self.put("/etc/runlevels/default/cloudflared-nat-vless")
        else:
            (self.root / "run/systemd/system").mkdir(parents=True)
            xray_service = "/etc/systemd/system/xray.service"
            tunnel_service = "/etc/systemd/system/cloudflared-nat-vless.service"
            content = (
                f"ExecStart={shell_path(self.root)}/usr/local/bin/xray run -config "
                f"{shell_path(self.root)}/usr/local/etc/xray/config.json\n"
            )
            self.put("/etc/systemd/system/xray@.service")
            for service in ("xray.service", "xray@.service"):
                self.put(f"/etc/systemd/system/{service}.d/10-donot_touch_single_conf.conf")
        self.put(xray_service, content)
        config = {
            "log": {"loglevel": "warning"},
            "inbounds": [{
                "protocol": "vless",
                "settings": {"clients": [{"id": "test-id"}], "decryption": "none"},
                "streamSettings": {
                    "network": "ws", "security": "none",
                    "wsSettings": {"path": "/ws-0123456789abcdef"},
                },
            }],
            "outbounds": [{"protocol": "freedom", "tag": "direct"}],
        }
        self.put("/usr/local/etc/xray/config.json", json.dumps(config))
        self.put("/usr/local/bin/xray")
        if marker:
            self.put("/usr/local/etc/xray/.nat-vless-installer", "nat-vless-reality-v1\n")
        if tunnel:
            self.put(tunnel_service, (
                "Cloudflare Tunnel for NAT VLESS WebSocket\n"
                f"--token-file {shell_path(self.root)}/etc/nat-vless/cloudflared.token\n"
            ))
            self.put("/etc/nat-vless/cloudflared.token", "private-test-token")
        self.put("/usr/local/bin/cloudflared", "shared-binary")
        self.put("/etc/cloudflared/other-tunnel.yml", "unrelated")
        self.put("/usr/local/x-ui/bin/xray-linux-amd64", "panel-binary")
        return xray_service, tunnel_service

    def run_uninstall(self, choices="", args="--yes", **values):
        mocks = r'''
id() { printf '0\n'; }
python3() { "$TEST_PYTHON" "$@"; }
systemctl() {
  printf 'systemctl %s\n' "$*" >> "$TEST_LOG"
  if [ "$1" = stop ] && [ "${TEST_STOP_FAIL:-0}" = 1 ]; then return 1; fi
  if [ "$1" = list-units ] && [ "${TEST_INSTANCES:-0}" = 1 ]; then
    printf 'xray@other.service loaded active running\n'
  fi
  return 0
}
rc-service() {
  printf 'rc-service %s\n' "$*" >> "$TEST_LOG"
  case "$2" in
    status)
      if [ -f "$TEST_LOG.$1.stopped" ]; then
        return "${TEST_FINAL_STATUS:-3}"
      fi
      return "${TEST_INITIAL_STATUS:-0}"
      ;;
    stop)
      [ "${TEST_STOP_FAIL:-0}" != 1 ] || return 1
      : > "$TEST_LOG.$1.stopped"
      ;;
    *) return 99 ;;
  esac
}
rc-update() { printf 'rc-update %s\n' "$*" >> "$TEST_LOG"; }
'''
        env = os.environ.copy()
        env.pop("MSYS_NO_PATHCONV", None)
        env.update(
            TEST_PYTHON=Path(sys.executable).as_posix(),
            TEST_LOG=shell_path(self.log),
            **values,
        )
        script = self.put("/uninstall-test.sh", mocks + self.source)
        return subprocess.run(
            [SHELL, str(script), *args.split()],
            env=env, input=choices, capture_output=True, text=True,
            encoding="utf-8", timeout=10,
        )

    def test_both_platforms_remove_nodes_and_leave_shared_files(self):
        for platform in ("alpine", "systemd"):
            for marker in (True, False):
                with self.subTest(platform=platform, marker=marker):
                    self.setUp()
                    xray_service, tunnel_service = self.fixture(platform, marker=marker)
                    extra = self.put("/usr/local/etc/xray/keep.json", "unrelated")
                    result = self.run_uninstall()
                    self.assertEqual(result.returncode, 0, result.stderr)
                    for removed in (
                        xray_service, tunnel_service, "/usr/local/bin/xray",
                        "/usr/local/etc/xray/config.json",
                        "/usr/local/etc/xray/.nat-vless-installer",
                        "/etc/nat-vless/cloudflared.token",
                    ):
                        self.assertFalse((self.root / removed.lstrip("/")).exists(), removed)
                    self.assertTrue(extra.exists())
                    self.assertTrue((self.root / "usr/local/bin/cloudflared").exists())
                    self.assertTrue((self.root / "usr/local/x-ui/bin/xray-linux-amd64").exists())
                    self.assertTrue((self.root / "etc/cloudflared/other-tunnel.yml").exists())
                    log = self.log.read_text(encoding="utf-8")
                    if platform == "systemd":
                        self.assertIn("systemctl stop xray.service", log)
                        self.assertIn("systemctl disable cloudflared-nat-vless.service", log)
                        self.assertIn("systemctl daemon-reload", log)
                    else:
                        self.assertIn("rc-service xray stop", log)
                        self.assertIn("rc-update del cloudflared-nat-vless default", log)
                    again = self.run_uninstall()
                    self.assertEqual(again.returncode, 0, again.stderr)
                    self.assertNotIn("private-test-token", result.stdout + result.stderr)

    def test_stop_failure_keeps_all_configuration(self):
        for platform in ("alpine", "systemd"):
            with self.subTest(platform=platform):
                self.setUp()
                self.fixture(platform)
                result = self.run_uninstall(TEST_STOP_FAIL="1")
                self.assertNotEqual(result.returncode, 0)
                self.assertTrue((self.root / "usr/local/bin/xray").exists())
                self.assertTrue((self.root / "etc/nat-vless/cloudflared.token").exists())

    def test_alpine_stopped_services_skip_stop_and_remove_startup(self):
        xray_service, tunnel_service = self.fixture("alpine")
        result = self.run_uninstall(TEST_INITIAL_STATUS="3")
        self.assertEqual(result.returncode, 0, result.stderr)
        log = self.log.read_text(encoding="utf-8")
        for service, path in (
            ("xray", xray_service), ("cloudflared-nat-vless", tunnel_service),
        ):
            self.assertIn(f"rc-service {service} status", log)
            self.assertNotIn(f"rc-service {service} stop", log)
            self.assertIn(f"rc-update del {service} default", log)
            self.assertFalse((self.root / path.lstrip("/")).exists())

    def test_alpine_original_legacy_service_is_recognized(self):
        xray_service, _ = self.fixture("alpine", tunnel=False, marker=False)
        service = self.root / xray_service.lstrip("/")
        service.write_text(
            service.read_text(encoding="utf-8").replace(
                'description="VLESS server"', 'description="VLESS REALITY server"',
            ),
            encoding="utf-8", newline="\n",
        )
        result = self.run_uninstall()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(service.exists())
        self.assertFalse((self.root / "usr/local/bin/xray").exists())

    def test_alpine_abnormal_statuses_require_stopping(self):
        for status in ("1", "4", "8", "16", "32", "64"):
            with self.subTest(status=status):
                self.setUp()
                self.fixture("alpine", tunnel=False)
                result = self.run_uninstall(TEST_INITIAL_STATUS=status)
                self.assertEqual(result.returncode, 0, result.stderr)
                log = self.log.read_text(encoding="utf-8")
                self.assertIn("rc-service xray stop", log)
                self.assertEqual(log.count("rc-service xray status"), 2)
                self.assertFalse((self.root / "usr/local/bin/xray").exists())

    def test_alpine_stop_requires_confirmed_stopped_state(self):
        for status in ("0", "1", "4", "8", "16", "32", "64"):
            with self.subTest(status=status):
                self.setUp()
                self.fixture("alpine")
                result = self.run_uninstall(TEST_FINAL_STATUS=status)
                self.assertNotEqual(result.returncode, 0)
                self.assertTrue((self.root / "usr/local/bin/xray").exists())
                self.assertTrue((self.root / "etc/nat-vless/cloudflared.token").exists())
                self.assertNotIn("rc-update del", self.log.read_text(encoding="utf-8"))

    def test_confirmation_cancellation_keeps_services_untouched(self):
        self.fixture("alpine")
        result = self.run_uninstall(args="", choices="n\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.root / "usr/local/bin/xray").exists())
        self.assertFalse(self.log.exists())

    def test_other_systemd_instances_block_shared_binary_removal(self):
        self.fixture("systemd")
        result = self.run_uninstall(TEST_INSTANCES="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((self.root / "usr/local/bin/xray").exists())
        self.assertNotIn("systemctl stop ", self.log.read_text(encoding="utf-8"))

    def test_unknown_legacy_configuration_is_refused(self):
        self.fixture("systemd", marker=False)
        self.put("/usr/local/etc/xray/config.json", '{"inbounds":[],"outbounds":[]}')
        result = self.run_uninstall()
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((self.root / "usr/local/bin/xray").exists())
        self.assertFalse(self.log.exists())

    def test_marker_does_not_allow_replaced_service(self):
        xray_service, _ = self.fixture("alpine")
        self.put(xray_service, "command=/usr/local/something-else")
        result = self.run_uninstall()
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((self.root / "usr/local/bin/xray").exists())
        self.assertFalse(self.log.exists())

    def test_symlinked_config_parent_is_refused(self):
        self.fixture("alpine")
        config_dir = self.root / "usr/local/etc/xray"
        outside = self.root / "outside"
        config_dir.rename(outside)
        try:
            config_dir.symlink_to(outside, target_is_directory=True)
        except OSError as exc:
            self.skipTest(f"Symlinks are unavailable: {exc}")
        result = self.run_uninstall()
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((outside / "config.json").exists())
        self.assertFalse(self.log.exists())


if __name__ == "__main__":
    unittest.main()
