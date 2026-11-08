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
            r"(?<![\w/.-])(?:/usr/(?:local|share|lib)|/etc|/run|/root|/home|/lib)",
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
id() {
  if [ "$*" = cloudflared ]; then [ "${TEST_CLOUDFLARED_USER:-0}" = 1 ]; return; fi
  if [ "$*" = xray ]; then [ "${TEST_XRAY_USER:-0}" = 1 ]; return; fi
  printf '0\n'
}
python3() { "$TEST_PYTHON" "$@"; }
rm() {
  if [ "${TEST_REMOVE_FAIL:-0}" = 1 ]; then
    for path do
      case "$path" in */usr/local/bin/xray) return 1 ;; esac
    done
  fi
  command rm "$@"
}
kill() {
  if [ "$1" = -0 ]; then [ "$2" = "${TEST_LIVE_PID:-none}" ]; return; fi
  return 99
}
pidof() {
  case "$1" in
    cloudflared) [ "${TEST_SHARED_PROCESS:-0}" = 1 ] ;;
    xray) [ "${TEST_XRAY_PROCESS:-0}" = 1 ] ;;
    *) return 99 ;;
  esac
}
apk() {
  if [ "$1" = info ]; then [ -f "$TEST_LOG.build-deps" ]; return; fi
  printf 'apk %s\n' "$*" >> "$TEST_LOG"
  [ "${TEST_PACKAGE_FAIL:-0}" != 1 ] || return 1
  rm -f "$TEST_LOG.build-deps"
}
dpkg-query() {
  [ "${TEST_DPKG_FAIL:-0}" != 1 ] || return 2
  [ ! -f "$TEST_LOG.package-purged" ] || [ "${TEST_PACKAGE_STUCK:-0}" = 1 ] || return 1
  if [ "${TEST_CLOUDFLARED_PACKAGE:-0}" = 1 ]; then
    printf '%s' "${TEST_PACKAGE_STATUS:-install ok installed}"
  else
    return 1
  fi
}
apt-get() {
  printf 'apt-get %s\n' "$*" >> "$TEST_LOG"
  [ "${TEST_PACKAGE_FAIL:-0}" != 1 ] || return 1
  : > "$TEST_LOG.package-purged"
}
deluser() { printf 'deluser %s\n' "$*" >> "$TEST_LOG"; }
userdel() { printf 'userdel %s\n' "$*" >> "$TEST_LOG"; }
delgroup() { printf 'delgroup %s\n' "$*" >> "$TEST_LOG"; }
groupdel() { printf 'groupdel %s\n' "$*" >> "$TEST_LOG"; }
getent() {
  case "$*" in
    'group cloudflared') [ "${TEST_CLOUDFLARED_GROUP:-0}" = 1 ] ;;
    'group xray') [ "${TEST_XRAY_GROUP:-0}" = 1 ] ;;
    *) return 99 ;;
  esac
}
systemctl() {
  printf 'systemctl %s\n' "$*" >> "$TEST_LOG"
  case "$1" in
    is-active|is-enabled) return "${TEST_CLOUDFLARED_NATIVE_ACTIVE:-1}" ;;
  esac
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

    def resources(self, *flags):
        return self.put(
            "/usr/local/etc/xray/.nat-vless-resources",
            "nat-vless-resources-v1\n" + "".join(flag + "\n" for flag in flags),
        )

    def stage(self, suffix="ABC123", pid="999999", marker=True):
        name = "/usr/local/.nat-vless-install." + suffix
        if marker:
            self.put(name + "/.nat-vless-stage", "nat-vless-stage-v1\n")
        self.put(name + "/installer.pid", pid + "\n")
        self.put(name + "/xray.zip")
        return self.root / name.lstrip("/")

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

    def test_marked_stale_stage_without_installation_is_removed(self):
        self.put("/etc/alpine-release")
        stage = self.stage()
        unmarked = self.stage("DEF456", marker=False)
        result = self.run_uninstall()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(stage.exists())
        self.assertTrue(unmarked.exists())
        again = self.run_uninstall()
        self.assertEqual(again.returncode, 0, again.stderr)

    def test_active_stage_blocks_all_mutations(self):
        self.fixture("alpine")
        stage = self.stage(pid="54321")
        result = self.run_uninstall(TEST_LIVE_PID="54321")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(stage.exists())
        self.assertTrue((self.root / "usr/local/bin/xray").exists())
        self.assertFalse(self.log.exists())

    def test_marker_only_removes_startup_links_and_stale_pid(self):
        self.put("/etc/alpine-release")
        self.put("/usr/local/etc/xray/.nat-vless-installer", "nat-vless-reality-v1\n")
        self.put("/etc/runlevels/default/xray")
        self.put("/etc/runlevels/default/cloudflared-nat-vless")
        self.put("/run/xray.pid", "987654\n")
        result = self.run_uninstall()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.root / "etc/runlevels/default/xray").exists())
        self.assertFalse((self.root / "etc/runlevels/default/cloudflared-nat-vless").exists())
        self.assertFalse((self.root / "run/xray.pid").exists())
        self.assertFalse((self.root / "usr/local/etc/xray").exists())

    def test_live_unknown_pid_blocks_marker_only_cleanup(self):
        self.put("/etc/alpine-release")
        marker = self.put("/usr/local/etc/xray/.nat-vless-installer", "nat-vless-reality-v1\n")
        self.put("/run/xray.pid", "54321\n")
        result = self.run_uninstall(TEST_LIVE_PID="54321")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(marker.exists())
        self.assertFalse(self.log.exists())

    def test_resource_manifest_only_cleanup_and_unknown_flag_rejection(self):
        for flag in ("", "unknown-resource"):
            with self.subTest(flag=flag):
                self.setUp()
                self.put("/etc/alpine-release")
                manifest = self.resources(*([flag] if flag else []))
                result = self.run_uninstall()
                if flag:
                    self.assertNotEqual(result.returncode, 0)
                    self.assertTrue(manifest.exists())
                    self.assertFalse(self.log.exists())
                else:
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertFalse(manifest.exists())

    def test_build_dependencies_only_cleanup_and_failure(self):
        for failure in ("0", "1"):
            with self.subTest(failure=failure):
                self.setUp()
                self.put("/etc/alpine-release")
                deps = Path(str(self.log) + ".build-deps")
                deps.touch()
                result = self.run_uninstall(TEST_PACKAGE_FAIL=failure)
                self.assertEqual(result.returncode == 0, failure == "0", result.stderr)
                self.assertEqual(deps.exists(), failure == "1")
                self.assertIn("apk del .nat-vless-build-deps", self.log.read_text())

    def test_owned_cloudflared_binary_and_accounts_are_removed_when_unused(self):
        self.fixture("alpine")
        (self.root / "etc/cloudflared/other-tunnel.yml").unlink()
        (self.root / "etc/cloudflared").rmdir()
        self.put("/etc/group", "cloudflared:x:100:\n")
        manifest = self.resources("cloudflared-binary", "cloudflared-user", "cloudflared-group")
        result = self.run_uninstall(TEST_CLOUDFLARED_USER="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.root / "usr/local/bin/cloudflared").exists())
        self.assertFalse(manifest.exists())
        log = self.log.read_text()
        self.assertIn("deluser cloudflared", log)
        self.assertIn("delgroup cloudflared", log)

    def test_owned_cloudflared_package_repository_and_key_are_removed_when_unused(self):
        self.fixture("systemd")
        (self.root / "etc/cloudflared/other-tunnel.yml").unlink()
        (self.root / "etc/cloudflared").rmdir()
        repo = self.put("/etc/apt/sources.list.d/cloudflared.list")
        key = self.put("/usr/share/keyrings/cloudflare-main.gpg")
        manifest = self.resources(
            "cloudflared-package", "cloudflared-repo", "cloudflared-key",
            "cloudflared-user", "cloudflared-group",
        )
        result = self.run_uninstall(
            TEST_CLOUDFLARED_PACKAGE="1", TEST_CLOUDFLARED_USER="1", TEST_CLOUDFLARED_GROUP="1",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        for path in (repo, key, manifest):
            self.assertFalse(path.exists())
        log = self.log.read_text()
        self.assertIn("apt-get purge -y cloudflared", log)
        self.assertIn("userdel cloudflared", log)
        self.assertIn("groupdel cloudflared", log)

    def test_other_cloudflared_uses_preserve_owned_resources_and_manifest(self):
        for shared in ("config", "service", "process"):
            with self.subTest(shared=shared):
                self.setUp()
                self.fixture("alpine")
                if shared != "config":
                    (self.root / "etc/cloudflared/other-tunnel.yml").unlink()
                    (self.root / "etc/cloudflared").rmdir()
                if shared == "service":
                    self.put("/etc/init.d/other-tunnel", "command=/usr/local/bin/cloudflared\n")
                manifest = self.resources("cloudflared-binary", "cloudflared-user")
                result = self.run_uninstall(TEST_SHARED_PROCESS="1" if shared == "process" else "0")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertTrue((self.root / "usr/local/bin/cloudflared").exists())
                self.assertTrue(manifest.exists())
                self.assertNotIn("deluser", self.log.read_text())
                self.assertIn("保留共享程序", result.stdout)

    def test_known_maintenance_files_removed_and_unmarked_files_preserved(self):
        self.fixture("alpine", tunnel=False)
        node = self.put("/root/nat-vless-node.txt", "vless://synthetic-private-node\n")
        copy = self.put(
            "/root/install-alpine.sh",
            "XRAY_BIN=" + shell_path(self.root) + "/usr/local/bin/xray\n# nat-vless-reality-v1\n",
        )
        unknown = self.put("/root/install.sh", "unrelated installer")
        backup = self.put(
            "/root/nat-vless-recovery-20261108/.nat-vless-recovery", "nat-vless-recovery-v1\n",
        ).parent
        self.put("/root/nat-vless-recovery-20261108/xray.truncated")
        other = self.put("/root/nat-vless-recovery-keep/other").parent
        result = self.run_uninstall()
        self.assertEqual(result.returncode, 0, result.stderr)
        for path in (node, copy, backup):
            self.assertFalse(path.exists(), path)
        self.assertTrue(unknown.exists())
        self.assertTrue(other.exists())

    def test_mixed_node_export_is_preserved(self):
        self.fixture("alpine", tunnel=False)
        node = self.put("/root/nat-vless-node.txt", "vless://fixture\nunrelated text\n")
        result = self.run_uninstall()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(node.exists())

    def test_new_xray_accounts_removed_and_shared_accounts_preserved(self):
        for shared in (False, True):
            with self.subTest(shared=shared):
                self.setUp()
                self.fixture("systemd", tunnel=False)
                manifest = self.resources("xray-user", "xray-group")
                if shared:
                    self.put("/usr/local/etc/xray/other.json")
                result = self.run_uninstall(TEST_XRAY_USER="1", TEST_XRAY_GROUP="1")
                self.assertEqual(result.returncode, 0, result.stderr)
                log = self.log.read_text()
                self.assertEqual("userdel xray" in log, not shared)
                self.assertEqual("groupdel xray" in log, not shared)
                self.assertEqual(manifest.exists(), shared)

    def test_native_package_service_only_blocks_removal_when_active_or_enabled(self):
        for active in ("0", "1"):
            with self.subTest(active=active):
                self.setUp()
                self.fixture("systemd")
                (self.root / "etc/cloudflared/other-tunnel.yml").unlink()
                (self.root / "etc/cloudflared").rmdir()
                self.put(
                    "/lib/systemd/system/cloudflared.service",
                    "ExecStart=/usr/bin/cloudflared tunnel run\n",
                )
                manifest = self.resources("cloudflared-package")
                result = self.run_uninstall(
                    TEST_CLOUDFLARED_PACKAGE="1", TEST_CLOUDFLARED_NATIVE_ACTIVE=active,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(manifest.exists(), active == "0")
                self.assertEqual("apt-get purge" in self.log.read_text(), active == "1")

    def test_running_unmanaged_xray_blocks_file_removal(self):
        self.put("/etc/alpine-release")
        marker = self.put("/usr/local/etc/xray/.nat-vless-installer", "nat-vless-reality-v1\n")
        result = self.run_uninstall(TEST_XRAY_PROCESS="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(marker.exists())
        self.assertFalse(self.log.exists())

    def test_systemd_missing_service_cleans_startup_file(self):
        (self.root / "run/systemd/system").mkdir(parents=True)
        marker = self.put("/usr/local/etc/xray/.nat-vless-installer", "nat-vless-reality-v1\n")
        link = self.put("/etc/systemd/system/multi-user.target.wants/xray.service")
        result = self.run_uninstall()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(marker.exists())
        self.assertFalse(link.exists())

    def test_package_cleanup_failure_keeps_manifest_for_retry(self):
        self.fixture("systemd")
        (self.root / "etc/cloudflared/other-tunnel.yml").unlink()
        (self.root / "etc/cloudflared").rmdir()
        manifest = self.resources("cloudflared-package")
        result = self.run_uninstall(TEST_CLOUDFLARED_PACKAGE="1", TEST_PACKAGE_FAIL="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(manifest.exists())
        self.assertTrue((self.root / "usr/local/bin/xray").exists())
        self.assertNotIn("卸载完成", result.stdout)

    def test_unrecognized_stage_and_recovery_markers_are_preserved(self):
        self.fixture("alpine", tunnel=False)
        stage = self.stage()
        (stage / ".nat-vless-stage").write_text("unknown", encoding="utf-8")
        recovery = self.put("/root/nat-vless-recovery-keep/.nat-vless-recovery", "unknown").parent
        result = self.run_uninstall()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(stage.exists())
        self.assertTrue(recovery.exists())

    def test_unrelated_service_using_xray_blocks_uninstall(self):
        self.fixture("alpine", tunnel=False)
        self.put(
            "/etc/init.d/other-xray",
            "command=" + shell_path(self.root) + "/usr/local/bin/xray\n",
        )
        result = self.run_uninstall()
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((self.root / "usr/local/bin/xray").exists())
        self.assertFalse(self.log.exists())

    def test_file_removal_failure_preserves_ownership_for_retry(self):
        self.fixture("alpine", tunnel=False)
        marker = self.root / "usr/local/etc/xray/.nat-vless-installer"
        result = self.run_uninstall(TEST_REMOVE_FAIL="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(marker.exists())
        self.assertTrue((self.root / "usr/local/bin/xray").exists())
        self.assertNotIn("卸载完成", result.stdout)

    def test_partial_cloudflared_package_states_are_purged(self):
        for status in ("install ok unpacked", "install ok half-configured", "deinstall ok config-files"):
            with self.subTest(status=status):
                self.setUp()
                self.fixture("systemd")
                (self.root / "etc/cloudflared/other-tunnel.yml").unlink()
                (self.root / "etc/cloudflared").rmdir()
                manifest = self.resources("cloudflared-package")
                result = self.run_uninstall(
                    TEST_CLOUDFLARED_PACKAGE="1", TEST_PACKAGE_STATUS=status,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertFalse(manifest.exists())
                self.assertIn("apt-get purge", self.log.read_text())

    def test_package_query_failure_or_stuck_package_keeps_manifest(self):
        for values in ({"TEST_DPKG_FAIL": "1"}, {"TEST_PACKAGE_STUCK": "1"}):
            with self.subTest(values=values):
                self.setUp()
                self.fixture("systemd")
                (self.root / "etc/cloudflared/other-tunnel.yml").unlink()
                (self.root / "etc/cloudflared").rmdir()
                manifest = self.resources("cloudflared-package")
                result = self.run_uninstall(TEST_CLOUDFLARED_PACKAGE="1", **values)
                self.assertNotEqual(result.returncode, 0)
                self.assertTrue(manifest.exists())
                self.assertNotIn("卸载完成", result.stdout)


if __name__ == "__main__":
    unittest.main()
