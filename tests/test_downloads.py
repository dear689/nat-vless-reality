import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

import test_installers as installers


SHELL = (
    os.environ.get("INSTALLER_TEST_SHELL")
    or shutil.which("bash")
    or installers.SHELL
)
TEST_URL = "https://downloads.example.invalid/xray.zip?first=one&second=two"


def shell_path(path):
    value = Path(path).resolve().as_posix()
    if os.name == "nt":
        return "/" + value[0].lower() + value[2:]
    return value


def last_option(arguments, name):
    positions = [index for index, value in enumerate(arguments) if value == name]
    if not positions:
        raise AssertionError(f"Missing curl option: {name}")
    return arguments[positions[-1] + 1]


@unittest.skipUnless(SHELL, "Bash is required")
class InstallerDownloadTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.stage = self.root / "stage with spaces"
        self.stage.mkdir()
        self.curl_bin = self.root / "real curl with spaces"
        self.curl_bin.mkdir()
        self.calls = self.root / "curl-calls"
        self.output = self.stage / "download with spaces"
        self.sentinel = self.root / "existing-file"
        self.sentinel.write_text("keep-existing-data", encoding="utf-8")
        curl = self.curl_bin / "curl"
        curl.write_text(
            """#!/bin/sh
printf '%s\\0' "$@" >> "$TEST_CURL_LOG"
printf '\\0' >> "$TEST_CURL_LOG"
output=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o|--output) output=$2; shift ;;
  esac
  shift
done
if [ -n "$output" ]; then
  printf 'synthetic-download-body' > "$output"
fi
exit "${TEST_CURL_EXIT:-0}"
""",
            encoding="utf-8",
            newline="\n",
        )
        curl.chmod(0o755)

    def run_shell(self, code, *, status=0):
        environment = os.environ.copy()
        environment.pop("MSYS_NO_PATHCONV", None)
        environment.update(
            TEST_CURL_BIN=shell_path(self.curl_bin),
            TEST_CURL_LOG=shell_path(self.calls),
            TEST_CURL_EXIT=str(status),
            TEST_OUTPUT=shell_path(self.output),
            TEST_URL=TEST_URL,
            TEST_LABEL="synthetic Xray installer",
            TEST_UPSTREAM_ARGS=shell_path(self.root / "upstream-args"),
            TEST_UPSTREAM_PATH=shell_path(self.root / "upstream-path"),
            tmp_dir=shell_path(self.stage),
        )
        permission_fixture = ""
        if os.name == "nt":
            # Git Bash cannot apply Unix directory modes on this Windows test host.
            permission_fixture = """
install() {
  if [ "$#" -eq 4 ] && [ "$1" = -d ] && [ "$2" = -m ]; then
    mkdir -p -- "$4"
  else
    command install "$@"
  fi
}
"""
        return subprocess.run(
            [SHELL, "-s"],
            input=(
                'set -Eeuo pipefail\nPATH="$TEST_CURL_BIN:$PATH"\nexport PATH\n'
                + permission_fixture + code
            ),
            env=environment,
            capture_output=True,
            text=True,
            encoding="utf-8",
            timeout=15,
            cwd=self.root,
        )

    def curl_calls(self):
        if not self.calls.exists():
            return []
        return [
            [argument.decode("utf-8") for argument in call.split(b"\0")]
            for call in self.calls.read_bytes().removesuffix(b"\0\0").split(b"\0\0")
        ]

    def functions(self, *names):
        return "\n".join(
            installers.shell_function(installers.DEBIAN, name)
            for name in ("fail", *names)
        ) + "\n"

    def write_upstream(self):
        upstream = self.stage / "install-release.sh"
        upstream.write_text(
            """#!/usr/bin/env bash
set -e
curl() {
  "$(type -P curl)" -q -L --retry 5 --retry-delay 10 --retry-max-time 60 "$@"
}
printf '%s\\0' "$@" > "$TEST_UPSTREAM_ARGS"
printf '%s' "$PATH" > "$TEST_UPSTREAM_PATH"
curl --fail "$TEST_URL" --output "$tmp_dir/upstream-archive"
curl --fail "$TEST_URL.dgst" --output "$tmp_dir/upstream-digest"
""",
            encoding="utf-8",
            newline="\n",
        )

    def test_installer_uses_raw_entry_and_bounded_download(self):
        self.assertIn(
            'XRAY_INSTALL_URL="https://raw.githubusercontent.com/XTLS/Xray-install/'
            'main/install-release.sh"',
            installers.DEBIAN,
        )
        install_steps = installers.DEBIAN[
            installers.DEBIAN.index(
                "apt-get install -y --no-install-recommends openssl python3"
            ):
        ]
        self.assertIn('download_file "$XRAY_INSTALL_URL"', install_steps)
        self.assertIn("if run_xray_installer; then", install_steps)

    def test_successful_download_is_visible_and_has_bounded_https_options(self):
        result = self.run_shell(
            self.functions("download_file")
            + 'download_file "$TEST_URL" "$TEST_OUTPUT" "$TEST_LABEL"\n'
            + 'printf "download-finished\\n"\n'
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("synthetic Xray installer", result.stdout)
        self.assertIn("download-finished", result.stdout)
        self.assertEqual(
            self.output.read_text(encoding="utf-8"), "synthetic-download-body"
        )
        calls = self.curl_calls()
        self.assertEqual(len(calls), 1)
        arguments = calls[0]
        self.assertEqual(arguments[0], "--disable")
        for option in ("--fail", "--show-error", "--location", "--progress-bar"):
            self.assertIn(option, arguments)
        for option, value in (
            ("--proto", "=https"),
            ("--proto-redir", "=https"),
            ("--connect-timeout", "10"),
            ("--max-time", "60"),
            ("--speed-time", "20"),
            ("--speed-limit", "1024"),
            ("--retry", "2"),
            ("--retry-delay", "2"),
            ("--retry-max-time", "90"),
            ("--output", shell_path(self.output)),
        ):
            self.assertEqual(last_option(arguments, option), value)
        self.assertEqual(arguments.count(TEST_URL), 1)
        self.assertNotIn("-k", arguments)
        self.assertNotIn("--insecure", arguments)

    def test_failed_download_removes_partial_and_reports_the_failed_stage(self):
        for status in (22, 28):
            with self.subTest(curl_status=status):
                self.calls.unlink(missing_ok=True)
                result = self.run_shell(
                    self.functions("download_file")
                    + 'download_file "$TEST_URL" "$TEST_OUTPUT" "$TEST_LABEL"\n'
                    + 'printf "download-finished\\n"\n',
                    status=status,
                )
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertFalse(self.output.exists())
                self.assertIn("synthetic Xray installer", result.stderr)
                self.assertIn(str(status), result.stderr)
                self.assertNotIn("download-finished", result.stdout)
                self.assertEqual(
                    self.sentinel.read_text(encoding="utf-8"), "keep-existing-data"
                )
                self.assertEqual(len(self.curl_calls()), 1)

    def test_upstream_downloads_use_bounds_even_after_replacing_curl_function(self):
        self.write_upstream()
        result = self.run_shell(
            self.functions("run_xray_installer")
            + """
original_path=$PATH
export NAT_VLESS_REAL_CURL=caller-sentinel
run_xray_installer
[ "$PATH" = "$original_path" ]
[ "$NAT_VLESS_REAL_CURL" = caller-sentinel ]
[ "$(type -P curl)" = "$TEST_CURL_BIN/curl" ]
printf "upstream-finished\\n"
"""
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("upstream-finished", result.stdout)
        self.assertEqual(
            (self.root / "upstream-args").read_bytes().split(b"\0")[:-1],
            [b"install", b"--without-geodata", b"--without-logfiles"],
        )
        self.assertNotEqual(
            (self.root / "upstream-path").read_text(encoding="utf-8").split(":")[0],
            shell_path(self.curl_bin),
        )
        calls = self.curl_calls()
        self.assertEqual(len(calls), 2)
        for arguments, url in zip(calls, (TEST_URL, TEST_URL + ".dgst")):
            self.assertEqual(arguments[0], "--disable")
            self.assertIn("-q", arguments)
            self.assertIn("-L", arguments)
            self.assertIn(url, arguments)
            for option, value in (
                ("--connect-timeout", "10"),
                ("--max-time", "180"),
                ("--speed-time", "30"),
                ("--speed-limit", "512"),
                ("--retry", "2"),
                ("--retry-delay", "2"),
                ("--retry-max-time", "190"),
            ):
                self.assertEqual(last_option(arguments, option), value)

    def test_upstream_download_failure_stops_the_install_attempt(self):
        self.write_upstream()
        result = self.run_shell(
            self.functions("run_xray_installer")
            + 'run_xray_installer\nprintf "unexpected-install-success\\n"\n',
            status=28,
        )
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertNotIn("unexpected-install-success", result.stdout)
        self.assertEqual(len(self.curl_calls()), 1)
        self.assertFalse((self.stage / "upstream-digest").exists())
        self.assertEqual(
            self.sentinel.read_text(encoding="utf-8"), "keep-existing-data"
        )

    def test_failed_wrapper_setup_cannot_fall_back_to_unbounded_upstream_curl(self):
        self.write_upstream()
        result = self.run_shell(
            self.functions("run_xray_installer")
            + """
install() { return 73; }
if run_xray_installer; then
  printf "unexpected-install-success\\n"
else
  exit 1
fi
"""
        )
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertFalse((self.root / "upstream-args").exists())
        self.assertEqual(self.curl_calls(), [])


if __name__ == "__main__":
    unittest.main()
