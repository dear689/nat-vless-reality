import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "install-alpine.sh").read_text(encoding="utf-8")
SHELL = os.environ.get("INSTALLER_TEST_SHELL") or shutil.which("sh")


def shell_path(path):
    value = Path(path).resolve().as_posix()
    if os.name == "nt":
        return "/" + value[0].lower() + value[2:]
    return value


def function(name):
    return re.search(
        r"^" + name + r"\(\) \{\n.*?^\}", SOURCE, re.M | re.S
    ).group(0)


@unittest.skipUnless(SHELL, "A POSIX shell is required")
class AlpineCommitTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.stage = self.root / "stage"
        self.stage.mkdir()
        (self.stage / "xray").write_text("validated-binary", encoding="utf-8")
        (self.stage / "config.json").write_text("{}", encoding="utf-8")
        self.bin = self.root / "usr/local/bin/xray"
        self.config = self.root / "usr/local/etc/xray/config.json"
        self.service = self.root / "etc/init.d/xray"
        self.marker = self.root / "usr/local/etc/xray/.nat-vless-installer"
        self.resources = self.root / "usr/local/etc/xray/.nat-vless-resources"
        self.service.parent.mkdir(parents=True)

    def run_commit(self, fail_step="", existing=None, signal="", after_commit=""):
        if existing is not None:
            existing.parent.mkdir(parents=True, exist_ok=True)
            existing.write_text("unknown-installation", encoding="utf-8")
        start = SOURCE.index("# Refuse to replace files created by another process")
        end = SOURCE.index("\nrc-update add xray default", start)
        trap_start = SOURCE.index("xray_commit_started=0")
        trap_end = SOURCE.index("\n# Install dependencies", trap_start)
        code = (
            "set -eu\n"
            + function("fail") + "\n"
            + function("cleanup_install") + "\n"
            + function("record_resource") + "\n"
            + SOURCE[trap_start:trap_end] + "\n"
            + r'''
install() {
  for argument do destination=$argument; done
  if [ "$destination" = "$XRAY_CONFIG" ]; then
    if [ "$TEST_FAIL" = config ]; then
      printf partial > "$destination"
      return 9
    fi
    # File ownership is not portable to the Windows POSIX-shell test host.
    command install -m 640 "$tmp_dir/config.json" "$XRAY_CONFIG"
    return
  fi
  command install "$@"
}
mv() {
  for argument do destination=$argument; done
  if [ "$TEST_FAIL" = service ] && [ "$destination" = "$XRAY_SERVICE" ]; then
    return 10
  fi
  if [ "$destination" = "$XRAY_BIN" ]; then
    if [ "$TEST_SIGNAL" != "" ]; then kill "-$TEST_SIGNAL" "$$"; fi
    if [ "$TEST_FAIL" = binary ]; then return 11; fi
  fi
  command mv "$@"
}
'''
            + SOURCE[start:end] + "\n" + after_commit + "\n"
        )
        code = re.sub(
            r"(?<![\w/.-])(?:/usr/local|/etc)",
            lambda match: shell_path(self.root) + match.group(0),
            code,
        )
        env = os.environ.copy()
        env.pop("MSYS_NO_PATHCONV", None)
        env.update(
            XRAY_BIN=shell_path(self.bin),
            XRAY_CONFIG=shell_path(self.config),
            XRAY_SERVICE=shell_path(self.service),
            XRAY_MARKER=shell_path(self.marker),
            XRAY_RESOURCES=shell_path(self.resources),
            tmp_dir=shell_path(self.stage),
            node_type="1",
            service_group="nobody",
            TEST_FAIL=fail_step,
            TEST_SIGNAL=signal,
        )
        return subprocess.run(
            [SHELL, "-c", code], env=env, capture_output=True,
            text=True, encoding="utf-8", timeout=10,
        )

    def test_failed_file_commit_removes_partial_installation(self):
        for step, status in (("config", 9), ("service", 10), ("binary", 11)):
            with self.subTest(step=step):
                self.setUp()
                result = self.run_commit(fail_step=step)
                self.assertEqual(result.returncode, status, result.stderr)
                for path in (self.bin, self.config, self.service, self.marker, self.resources, self.stage):
                    self.assertFalse(path.exists(), path)

    def test_interruption_before_binary_move_rolls_back(self):
        for signal, status in (("HUP", 129), ("INT", 130), ("TERM", 143)):
            with self.subTest(signal=signal):
                self.setUp()
                result = self.run_commit(signal=signal)
                self.assertEqual(result.returncode, status, result.stderr)
                for path in (self.bin, self.config, self.service, self.marker, self.resources, self.stage):
                    self.assertFalse(path.exists(), path)

    def test_uncatchable_interruption_keeps_ownership_for_uninstall(self):
        result = self.run_commit(signal="KILL")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertEqual(
            self.marker.read_text(encoding="utf-8"), "nat-vless-reality-v1\n"
        )
        self.assertEqual(
            self.resources.read_text(encoding="utf-8"), "nat-vless-resources-v1\n"
        )
        self.assertFalse(self.bin.exists())
        self.assertTrue((self.stage / "xray").exists())

    def test_success_renames_binary_and_preserves_managed_files(self):
        original_inode = (self.stage / "xray").stat().st_ino
        result = self.run_commit()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.bin.read_text(encoding="utf-8"), "validated-binary")
        self.assertEqual(self.bin.stat().st_ino, original_inode)
        self.assertEqual(
            self.marker.read_text(encoding="utf-8"), "nat-vless-reality-v1\n"
        )
        self.assertTrue(self.config.exists())
        self.assertIn(
            "command=" + shell_path(self.bin),
            self.service.read_text(encoding="utf-8"),
        )
        self.assertFalse(self.stage.exists())

    def test_failure_after_commit_preserves_recoverable_installation(self):
        result = self.run_commit(after_commit="exit 12")
        self.assertEqual(result.returncode, 12, result.stderr)
        for path in (self.bin, self.config, self.service, self.marker, self.resources):
            self.assertTrue(path.exists(), path)
        self.assertFalse(self.stage.exists())

    def test_unknown_existing_files_are_not_overwritten_or_removed(self):
        for kind in ("bin", "config", "service", "marker", "resources"):
            with self.subTest(kind=kind):
                self.setUp()
                existing = getattr(self, kind)
                result = self.run_commit(existing=existing)
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertIn("refusing to overwrite", result.stderr)
                self.assertEqual(
                    existing.read_text(encoding="utf-8"), "unknown-installation"
                )


if __name__ == "__main__":
    unittest.main()
