#!/usr/bin/env python3
"""Isolated tests for spicetify-universal.sh.

All mutating external boundaries are replaced by fake commands in a temporary PATH.
No real sudo/flatpak/spicetify/package/network call is made.
"""

from __future__ import annotations

import hashlib
import io
import json
import os
import shutil
import stat
import subprocess
import tarfile
import tempfile
import textwrap
import unittest
import zipfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPT = REPO_ROOT / "spicetify-universal.sh"
NOBODY_UID = 65534
NOBODY_GID = 65534

FAKE_SPICETIFY_BODY = """#!/bin/sh
printf '%s\\n' "$*" >> "$FAKE_LOG/spicetify.log"
if [ -n "${FAKE_SPICETIFY_FAIL_PATTERN:-}" ]; then
    case "$*" in
        *"$FAKE_SPICETIFY_FAIL_PATTERN"*) exit "${FAKE_SPICETIFY_FAIL_CODE:-1}" ;;
    esac
fi
if [ "$1" = "--version" ]; then echo "2.46.4-fake"; fi
case "$1 $2" in
    "config spotify_path")
        if [ $# -eq 2 ]; then
            if [ "${FAKE_SPICETIFY_CONFIG_MISMATCH:-0}" = "1" ]; then echo "/wrong/path"; exit 0; fi
            cat "$FAKE_LOG/spotify_path" 2>/dev/null || exit 1
        else
            printf '%s\\n' "$3" > "$FAKE_LOG/spotify_path"
        fi
        exit 0 ;;
    "config prefs_path")
        if [ $# -eq 2 ]; then
            if [ "${FAKE_SPICETIFY_CONFIG_MISMATCH:-0}" = "1" ]; then echo "/wrong/prefs"; exit 0; fi
            cat "$FAKE_LOG/prefs_path" 2>/dev/null || exit 1
        else
            printf '%s\\n' "$3" > "$FAKE_LOG/prefs_path"
        fi
        exit 0 ;;
esac
exit 0
"""


def write_exec(path: Path, body: str) -> None:
    path.write_text(textwrap.dedent(body).lstrip(), encoding="utf-8")
    path.chmod(0o755)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(65536), b""):
            digest.update(chunk)
    return digest.hexdigest()


def make_tar_with_binary(path: Path, body: str) -> None:
    data = textwrap.dedent(body).lstrip().encode("utf-8")
    info = tarfile.TarInfo("spicetify")
    info.size = len(data)
    info.mode = 0o755
    with tarfile.open(path, "w:gz") as archive:
        archive.addfile(info, io.BytesIO(data))


def make_marketplace_zip(path: Path) -> None:
    with zipfile.ZipFile(path, "w") as archive:
        archive.writestr("marketplace-dist/manifest.json", '{"name":"marketplace"}\n')


class Harness(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="esl-tests.")
        self.root = Path(self.temp.name)
        self.home = self.root / "home"
        self.config_home = self.home / ".config"
        self.state_home = self.home / ".local" / "state"
        self.data_home = self.home / ".local" / "share"
        self.zdotdir = self.home / ".config" / "zsh"
        self.tmpdir = self.root / "tmp"
        self.bin = self.root / "bin"
        self.log = self.root / "log"
        for path in (
            self.home,
            self.config_home,
            self.state_home,
            self.data_home,
            self.zdotdir,
            self.tmpdir,
            self.bin,
            self.log,
        ):
            path.mkdir(parents=True, exist_ok=True)

        self.script_copy = self.root / "script.sh"
        shutil.copy2(SCRIPT, self.script_copy)
        self.script_copy.chmod(0o755)

        self.cli_archive = self.root / "spicetify.tar.gz"
        make_tar_with_binary(self.cli_archive, FAKE_SPICETIFY_BODY)
        self.cli_digest = sha256(self.cli_archive)
        self.cli_json = self.root / "cli.json"
        self.cli_json.write_text(
            json.dumps(
                {
                    "tag_name": "v2.46.4",
                    "assets": [
                        {
                            "name": "spicetify-2.46.4-linux-amd64.tar.gz",
                            "digest": f"sha256:{self.cli_digest}",
                            "browser_download_url": "https://example.invalid/spicetify.tar.gz",
                        }
                    ],
                }
            ),
            encoding="utf-8",
        )

        self.marketplace_zip = self.root / "marketplace.zip"
        make_marketplace_zip(self.marketplace_zip)
        self.marketplace_digest = sha256(self.marketplace_zip)
        self.marketplace_json = self.root / "marketplace.json"
        self.marketplace_json.write_text(
            json.dumps(
                {
                    "tag_name": "v1.0.12",
                    "assets": [
                        {
                            "name": "marketplace.zip",
                            "digest": f"sha256:{self.marketplace_digest}",
                            "browser_download_url": "https://example.invalid/marketplace.zip",
                        }
                    ],
                }
            ),
            encoding="utf-8",
        )

        self.legacy_script = self.root / "legacy-install.sh"
        write_exec(
            self.legacy_script,
            """#!/bin/sh
            echo "legacy" >> "$FAKE_LOG/legacy.log"
            exit "${FAKE_LEGACY_EXIT:-0}"
            """,
        )

        self._make_fakes()
        self.bin_nospice = self.root / "bin-nospice"
        self.bin_nospice.mkdir()
        for fake in self.bin.iterdir():
            if fake.name != "spicetify":
                (self.bin_nospice / fake.name).symlink_to(fake)

        self.safe_bin = self.root / "safe-bin"
        self.safe_bin.mkdir()
        safe_tools = [
            "awk", "basename", "bash", "cat", "chmod", "cp", "cut", "dirname",
            "env", "find", "getent", "grep", "gzip", "head", "id", "mkdir", "mktemp",
            "mv", "realpath", "readlink", "rm", "sed", "setsid", "sh", "sha256sum",
            "shasum", "sleep", "stat", "tar", "timeout", "tr", "uname", "unzip",
        ]
        for tool in safe_tools:
            source = shutil.which(tool, path="/usr/bin:/bin")
            if source:
                (self.safe_bin / tool).symlink_to(source)
        self.test_path = f"{self.bin}:{self.safe_bin}"
        self.test_path_nospice = f"{self.bin_nospice}:{self.safe_bin}"
        self.env = self._base_env()

    def tearDown(self) -> None:
        self.temp.cleanup()

    def _base_env(self) -> dict[str, str]:
        env = {
            "HOME": str(self.home),
            "XDG_CONFIG_HOME": str(self.config_home),
            "XDG_STATE_HOME": str(self.state_home),
            "XDG_DATA_HOME": str(self.data_home),
            "ZDOTDIR": str(self.zdotdir),
            "TMPDIR": str(self.tmpdir),
            "PATH": self.test_path,
            "SHELL": "/bin/bash",
            "TERM": "dumb",
            "NO_COLOR": "1",
            "SCRIPT": str(self.script_copy),
            "FAKE_LOG": str(self.log),
            "FAKE_CLI_JSON": str(self.cli_json),
            "FAKE_CLI_ARCHIVE": str(self.cli_archive),
            "FAKE_MARKETPLACE_JSON": str(self.marketplace_json),
            "FAKE_MARKETPLACE_ZIP": str(self.marketplace_zip),
            "FAKE_LEGACY_SCRIPT": str(self.legacy_script),
            "FAKE_UNAME_M": "x86_64",
            "FAKE_FLATPAK_RUNNING": "0",
            "FAKE_SPOTIFY_RUNNING": "0",
        }
        return env

    def _make_fakes(self) -> None:
        write_exec(
            self.bin / "curl",
            """#!/bin/sh
            printf '%s\\n' "$*" >> "$FAKE_LOG/curl.log"
            url=""
            out=""
            prev=""
            for arg in "$@"; do
                if [ "$prev" = "--url" ]; then url="$arg"; prev=""; continue; fi
                if [ "$prev" = "--output" ]; then out="$arg"; prev=""; continue; fi
                case "$arg" in
                    --url|--output) prev="$arg" ;;
                esac
            done
            if [ -z "$url" ]; then
                for arg in "$@"; do
                    case "$arg" in http*) url="$arg" ;; esac
                done
            fi
            if [ "${FAKE_CURL_FAIL:-0}" = "1" ]; then exit 22; fi
            case "$url" in
                *api.github.com/repos/spicetify/cli/releases/tags/*|*api.github.com/repos/spicetify/cli/releases/latest)
                    cat "$FAKE_CLI_JSON" ;;
                *api.github.com/repos/spicetify/marketplace/releases/latest)
                    cat "$FAKE_MARKETPLACE_JSON" ;;
                *github.com/spicetify/cli/releases/download/*)
                    cp "$FAKE_CLI_ARCHIVE" "$out" ;;
                *github.com/spicetify/marketplace/releases/download/*)
                    cp "$FAKE_MARKETPLACE_ZIP" "$out" ;;
                *example.invalid/spicetify.tar.gz)
                    cp "$FAKE_CLI_ARCHIVE" "$out" ;;
                *example.invalid/install.sh)
                    cp "$FAKE_LEGACY_SCRIPT" "$out" ;;
                *raw.githubusercontent.com*)
                    cp "$FAKE_LEGACY_SCRIPT" "$out" ;;
                *) exit 22 ;;
            esac
            """,
        )
        write_exec(self.bin / "spicetify", FAKE_SPICETIFY_BODY)
        write_exec(
            self.bin / "flatpak",
            """#!/bin/sh
            printf '%s\\n' "$*" >> "$FAKE_LOG/flatpak.log"
            case "$*" in
                "info --user --show-location com.spotify.Client")
                    [ -n "${FAKE_FLATPAK_USER_PATH:-}" ] && printf '%s\\n' "$FAKE_FLATPAK_USER_PATH" && exit 0
                    exit 1 ;;
                "info --system --show-location com.spotify.Client")
                    [ -n "${FAKE_FLATPAK_SYSTEM_PATH:-}" ] && printf '%s\\n' "$FAKE_FLATPAK_SYSTEM_PATH" && exit 0
                    exit 1 ;;
                "ps --columns=application")
                    [ "${FAKE_FLATPAK_RUNNING:-0}" = "1" ] && printf '%s\\n' "com.spotify.Client"
                    exit 0 ;;
                kill*)
                    exit 0 ;;
            esac
            exit 0
            """,
        )
        write_exec(
            self.bin / "sudo",
            """#!/bin/sh
            printf '%s\\n' "$*" >> "$FAKE_LOG/sudo.log"
            exit 0
            """,
        )
        write_exec(
            self.bin / "setfacl",
            """#!/bin/sh
            printf '%s\\n' "$*" >> "$FAKE_LOG/setfacl.log"
            exit 0
            """,
        )
        write_exec(
            self.bin / "uname",
            """#!/bin/sh
            if [ "$1" = "-m" ]; then printf '%s\\n' "${FAKE_UNAME_M:-x86_64}"; exit 0; fi
            exec /usr/bin/uname "$@"
            """,
        )
        write_exec(
            self.bin / "pgrep",
            """#!/bin/sh
            printf '%s\\n' "$*" >> "$FAKE_LOG/pgrep.log"
            [ "${FAKE_SPOTIFY_RUNNING:-0}" = "1" ] && exit 0
            exit 1
            """,
        )
        write_exec(
            self.bin / "pkill",
            """#!/bin/sh
            printf '%s\\n' "$*" >> "$FAKE_LOG/pkill.log"
            exit 0
            """,
        )
        write_exec(
            self.bin / "sleep",
            """#!/bin/sh
            exit 0
            """,
        )

    def cli(
        self, *args: str, env: dict[str, str] | None = None
    ) -> subprocess.CompletedProcess[str]:
        run_env = self.env.copy()
        if env:
            run_env.update(env)
        return subprocess.run(
            ["bash", str(self.script_copy), *args],
            env=run_env,
            text=True,
            capture_output=True,
            cwd=self.root,
            timeout=60,
        )

    def cli_as_nobody(
        self, *args: str, env: dict[str, str] | None = None
    ) -> subprocess.CompletedProcess[str]:
        run_env = self.env.copy()
        if env:
            run_env.update(env)
        if os.geteuid() != 0 or not shutil.which("runuser"):
            return subprocess.run(
                ["bash", str(self.script_copy), *args],
                env=run_env,
                text=True,
                capture_output=True,
                cwd=self.root,
                timeout=60,
            )
        subprocess.run(
            ["chown", "-R", f"{NOBODY_UID}:{NOBODY_GID}", str(self.root)], check=True
        )
        command = ["runuser", "-u", "nobody", "--", "/usr/bin/env"]
        command.extend(f"{key}={value}" for key, value in run_env.items())
        command.extend(["bash", str(self.script_copy), *args])
        return subprocess.run(
            command, text=True, capture_output=True, cwd=self.root, timeout=60
        )

    def bash(
        self, body: str, env: dict[str, str] | None = None, as_nobody: bool = False
    ) -> subprocess.CompletedProcess[str]:
        run_env = self.env.copy()
        if env:
            run_env.update(env)
        code = 'source "$SCRIPT"\nset +e\n' + textwrap.dedent(body)
        if not as_nobody or os.geteuid() != 0 or not shutil.which("runuser"):
            return subprocess.run(
                ["bash", "--noprofile", "--norc", "-c", code],
                env=run_env,
                text=True,
                capture_output=True,
                cwd=self.root,
            )
        subprocess.run(
            ["chown", "-R", f"{NOBODY_UID}:{NOBODY_GID}", str(self.root)], check=True
        )
        args = ["runuser", "-u", "nobody", "--", "env"]
        args.extend(f"{key}={value}" for key, value in run_env.items())
        args.extend(["bash", "--noprofile", "--norc", "-c", code])
        return subprocess.run(args, text=True, capture_output=True, cwd=self.root, timeout=60)

    def combined(self, result: subprocess.CompletedProcess[str]) -> str:
        return result.stdout + result.stderr

    def read_log(self, name: str) -> str:
        path = self.log / name
        return path.read_text(encoding="utf-8") if path.exists() else ""

    def assert_no_log(self, name: str) -> None:
        self.assertEqual(self.read_log(name), "", f"unexpected calls in {name}")

    def make_native_install(
        self, app: Path | None = None, prefs: Path | None = None
    ) -> tuple[Path, Path]:
        app = app or (
            self.data_home
            / "spotify-launcher"
            / "install"
            / "usr"
            / "share"
            / "spotify"
        )
        prefs = prefs or (self.config_home / "spotify" / "prefs")
        (app / "Apps").mkdir(parents=True, exist_ok=True)
        (app / "Apps" / "xpui.spa").write_text("stock\n", encoding="utf-8")
        prefs.parent.mkdir(parents=True, exist_ok=True)
        prefs.write_text("app.last-launched-version=1.2.3\n", encoding="utf-8")
        return app, prefs

    def make_flatpak_install(
        self, location: Path, prefs: Path | None = None
    ) -> tuple[Path, Path]:
        app = location / "files" / "extra" / "share" / "spotify"
        (app / "Apps").mkdir(parents=True, exist_ok=True)
        (app / "Apps" / "xpui.spa").write_text("stock\n", encoding="utf-8")
        prefs = prefs or (
            self.home
            / ".var"
            / "app"
            / "com.spotify.Client"
            / "config"
            / "spotify"
            / "prefs"
        )
        prefs.parent.mkdir(parents=True, exist_ok=True)
        prefs.write_text("app.last-launched-version=1.2.3\n", encoding="utf-8")
        return app, prefs

    def snapshot(self) -> dict[str, tuple[int, str]]:
        result: dict[str, tuple[int, str]] = {}
        for path in sorted(self.home.rglob("*")):
            rel = str(path.relative_to(self.home))
            if path.is_file():
                result[rel] = (path.stat().st_mode, sha256(path))
            elif path.is_dir():
                result[rel] = (path.stat().st_mode, "dir")
            elif path.is_symlink():
                result[rel] = (path.lstat().st_mode, os.readlink(path))
        return result


class ArgumentAndSafetyTests(Harness):
    def test_help_and_version_work_as_root(self) -> None:
        help_result = self.cli("--help")
        self.assertEqual(help_result.returncode, 0, help_result.stderr)
        self.assertIn("--repair", help_result.stdout)
        self.assertIn("EXPERIMENTAL", help_result.stdout)
        version_result = self.cli("--version")
        self.assertEqual(version_result.returncode, 0, version_result.stderr)
        self.assertIn("3.1.0", version_result.stdout)

    def test_conflicting_modes_and_unknown_options(self) -> None:
        conflict = self.cli("--repair", "--restore")
        self.assertNotEqual(conflict.returncode, 0)
        self.assertIn("Conflicting modes", conflict.stderr)
        unknown = self.cli("--not-an-option")
        self.assertEqual(unknown.returncode, 2)
        missing = self.cli("--spotify-path")
        self.assertEqual(missing.returncode, 2)
        relative = self.cli("--spotify-path", "relative/path", "--dry-run")
        self.assertNotEqual(relative.returncode, 0)
        self.assertIn("absolute", relative.stderr)
        bad_type = self.cli("--spotify-type", "snap", "--dry-run")
        self.assertNotEqual(bad_type.returncode, 0)

    def test_duplicate_same_mode_is_allowed(self) -> None:
        result = self.cli("--uninstall", "--uninstall", "--dry-run")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("DRY-RUN", result.stdout)

    def test_help_short_circuits_actions(self) -> None:
        result = self.cli("--uninstall", "--help")
        self.assertEqual(result.returncode, 0)
        self.assertIn("Usage:", result.stdout)
        self.assert_no_log("spicetify.log")

    def test_root_mutating_run_is_refused_without_actions(self) -> None:
        if os.geteuid() != 0:
            self.skipTest("requires root to exercise the root guard")
        result = self.cli("--yes")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Refusing to run setup as root", result.stderr)
        self.assert_no_log("spicetify.log")
        self.assert_no_log("curl.log")

    def test_spicetify_state_override_rejected_before_cli(self) -> None:
        result = self.cli(
            "--dry-run",
            "--uninstall",
            env={"SPICETIFY_STATE": str(self.root / "bad-state")},
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("SPICETIFY_STATE is not supported", result.stderr)
        self.assert_no_log("spicetify.log")

    def test_dry_run_creates_nothing_and_calls_no_boundaries(self) -> None:
        app, prefs = self.make_native_install()
        before = self.snapshot()
        result = self.cli(
            "--dry-run",
            "--yes",
            "--spotify-type",
            "native",
            "--spotify-path",
            str(app),
            "--prefs-path",
            str(prefs),
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(before, self.snapshot())
        self.assert_no_log("curl.log")
        self.assert_no_log("spicetify.log")
        self.assert_no_log("flatpak.log")
        self.assert_no_log("sudo.log")

    def test_dry_run_uninstall_both_orderings_create_nothing(self) -> None:
        (self.home / ".spicetify").mkdir()
        (self.home / ".spicetify" / "spicetify").write_text("fake", encoding="utf-8")
        (self.config_home / "spicetify").mkdir(parents=True)
        (self.config_home / "spicetify" / "config-xpui.ini").write_text(
            "[Setting]\n", encoding="utf-8"
        )
        (self.state_home / "spicetify" / "Backup").mkdir(parents=True)
        (self.state_home / "spicetify" / "Backup" / "xpui.spa").write_text(
            "backup", encoding="utf-8"
        )
        before = self.snapshot()
        for args in (("--dry-run", "--uninstall"), ("--uninstall", "--dry-run")):
            result = self.cli(*args)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(before, self.snapshot())
            self.assert_no_log("spicetify.log")

    def test_dry_run_with_config_does_not_execute_it_or_use_network(self) -> None:
        app, prefs = self.make_native_install()
        config_dir = self.config_home / "spicetify-setup"
        config_dir.mkdir(parents=True)
        marker = self.root / "pwned"
        config = config_dir / "setup.conf"
        config.write_text(
            "\n".join(
                [
                    "SPOTIFY_TYPE=native",
                    f"SPOTIFY_PATH={app}",
                    f"PREFS_PATH={prefs}",
                    "INSTALL_MARKETPLACE=no",
                    f"EVIL=$(touch {marker})",
                    "",
                ]
            ),
            encoding="utf-8",
        )
        config.chmod(0o600)
        before = self.snapshot()
        result = self.cli("--dry-run", "--yes")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(marker.exists())
        self.assertEqual(before, self.snapshot())
        self.assert_no_log("curl.log")
        self.assert_no_log("spicetify.log")


class ConfigTests(Harness):
    def test_deprecated_setup_conf_is_not_read_or_executed(self) -> None:
        config_dir = self.config_home / "spicetify-setup"
        config_dir.mkdir(parents=True)
        marker = self.root / "pwned"
        config = config_dir / "setup.conf"
        config.write_text(
            "\n".join(
                [
                    "SPOTIFY_TYPE=native",
                    f"EVIL=$(touch {marker})",
                    "",
                ]
            ),
            encoding="utf-8",
        )
        config.chmod(0o600)
        result = self.cli("--dry-run", "--yes")
        self.assertNotEqual(result.returncode, 0)  # no Spotify fixture; must not fall through
        self.assertFalse(marker.exists())
        self.assertIn("setup.conf is no longer read", result.stdout)

    def test_xdg_and_zdotdir_paths(self) -> None:
        result = self.bash(
            """
            printf 'config=%s\\nstate=%s\\ninstall=%s\\n' "$SPICETIFY_CONFIG_DIR" "$SPICETIFY_STATE_DIR" "$SPICETIFY_INSTALL_DIR"
            """
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"config={self.config_home}/spicetify", result.stdout)
        self.assertIn(f"state={self.state_home}/spicetify", result.stdout)
        self.assertIn(f"install={self.home}/.spicetify", result.stdout)


class DiscoveryTests(Harness):
    def test_native_spotify_launcher_xdg_path(self) -> None:
        app, prefs = self.make_native_install()
        result = self.bash(
            """
            SPOTIFY_TYPE_OPT=native
            discover_spotify
            printf 'type=%s scope=%s app=%s prefs=%s\\n' "$SPOTIFY_TYPE" "$SPOTIFY_SCOPE" "$SPOTIFY_APP_FILES_PATH" "$SPOTIFY_PREFS_PATH"
            """
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"type=native scope=user app={app} prefs={prefs}", result.stdout)

    def test_flatpak_user_and_system_layouts(self) -> None:
        user_location = self.root / "flatpak-user"
        system_location = self.root / "flatpak-system"
        self.make_flatpak_install(user_location)
        self.make_flatpak_install(system_location)
        result = self.bash(
            """
            SPOTIFY_TYPE_OPT=flatpak
            FAKE_FLATPAK_USER_PATH=%s
            FAKE_FLATPAK_SYSTEM_PATH=%s
            export FAKE_FLATPAK_USER_PATH FAKE_FLATPAK_SYSTEM_PATH
            _discover_flatpak
            printf 'count=%%s types=%%s scopes=%%s\\n' "${#CAND_PATH[@]}" "${CAND_TYPE[*]}" "${CAND_SCOPE[*]}"
            """
            % (user_location, system_location)
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("count=2", result.stdout)
        self.assertIn("flatpak flatpak", result.stdout)
        self.assertIn("user system", result.stdout)

    def test_multiple_flatpaks_require_disambiguation(self) -> None:
        user_location = self.root / "flatpak-user"
        system_location = self.root / "flatpak-system"
        self.make_flatpak_install(user_location)
        self.make_flatpak_install(system_location)
        result = self.bash(
            """
            SPOTIFY_TYPE_OPT=flatpak
            ASSUME_YES=1
            FAKE_FLATPAK_USER_PATH=%s
            FAKE_FLATPAK_SYSTEM_PATH=%s
            export FAKE_FLATPAK_USER_PATH FAKE_FLATPAK_SYSTEM_PATH
            discover_spotify
            printf 'rc=%%s\\n' "$?"
            """
            % (user_location, system_location)
        )
        self.assertIn("Multiple Spotify installations", self.combined(result))
        self.assertNotIn("Using Spotify", result.stdout)

    def test_multiple_mixed_types_require_disambiguation(self) -> None:
        self.make_native_install()
        location = self.root / "flatpak-user"
        self.make_flatpak_install(location)
        result = self.bash(
            """
            SPOTIFY_TYPE_OPT=auto
            ASSUME_YES=1
            FAKE_FLATPAK_USER_PATH=%s
            export FAKE_FLATPAK_USER_PATH
            discover_spotify
            printf 'rc=%%s\\n' "$?"
            """
            % location
        )
        self.assertIn("Multiple Spotify installations", self.combined(result))

    def test_missing_prefs_has_actionable_error(self) -> None:
        app = self.root / "app" / "spotify"
        (app / "Apps").mkdir(parents=True)
        (app / "Apps" / "xpui.spa").write_text("stock", encoding="utf-8")
        result = self.bash(
            """
            SPOTIFY_TYPE_OPT=native
            SPOTIFY_PATH_OPT=%s
            discover_spotify
            printf 'rc=%%s\\n' "$?"
            """
            % app
        )
        self.assertIn("prefs file not found", self.combined(result))
        self.assertIn("Open Spotify once", result.stdout)

    def test_snap_and_nix_paths_rejected(self) -> None:
        result = self.bash(
            """
            for path in /snap/spotify/current/usr/share/spotify /nix/store/abc-spotify/share/spotify; do
                _validate_app "$path"
                printf '%s rc=%s\\n' "$path" "$?"
            done
            """
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("/snap/spotify", result.stdout)
        self.assertIn("Snap and Nix store", self.combined(result))
        self.assertIn("/nix/store", result.stdout)
        self.assertIn("rc=1", result.stdout)

    def test_symlink_to_snap_rejected(self) -> None:
        link = self.root / "spotify-link"
        link.symlink_to("/snap/spotify/current/usr/share/spotify")
        result = self.bash(
            """
            _validate_app %s
            printf 'rc=%%s\\n' "$?"
            """
            % link
        )
        self.assertIn("Snap and Nix store", self.combined(result))
        self.assertIn("rc=1", result.stdout)

    def test_paths_with_spaces(self) -> None:
        app = self.root / "My Spotify" / "app"
        prefs = self.root / "My Spotify" / "prefs file"
        self.make_native_install(app, prefs)
        before = self.snapshot()
        result = self.cli(
            "--dry-run",
            "--yes",
            "--spotify-type",
            "native",
            "--spotify-path",
            str(app),
            "--prefs-path",
            str(prefs),
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(str(app), result.stdout)
        self.assertIn(str(prefs), result.stdout)
        self.assertEqual(before, self.snapshot())

    def test_flatpak_process_check_uses_columns(self) -> None:
        result = self.bash(
            """
            SPOTIFY_TYPE=flatpak
            FAKE_FLATPAK_RUNNING=1
            export FAKE_FLATPAK_RUNNING
            _spotify_running
            printf 'rc=%s\\n' "$?"
            """
        )
        self.assertIn("rc=0", result.stdout)
        self.assertIn("ps --columns=application", self.read_log("flatpak.log"))


class PermissionTests(Harness):
    def test_no_world_writable_or_recursive_chown(self) -> None:
        text = SCRIPT.read_text(encoding="utf-8")
        self.assertNotIn("a+wr", text)
        self.assertNotIn("a+w", text)
        self.assertNotIn("chmod 777", text)
        self.assertNotIn("chown -R", text)
        self.assertIn("setfacl -R -P", text)
        self.assertIn("d:u:", text)

    def test_user_owned_permissions_are_fixed_for_ordinary_user(self) -> None:
        app = self.root / "owned-app"
        (app / "Apps").mkdir(parents=True)
        (app / "Apps" / "xpui.spa").write_text("stock", encoding="utf-8")
        app.chmod(0o555)
        (app / "Apps").chmod(0o555)
        result = self.bash(
            """
            SPOTIFY_APP_FILES_PATH=%s
            _ensure_writable
            printf 'rc=%%s writable=%%s\\n' "$?" "$([ -w %s ] && echo yes || echo no)"
            """
            % (app, app),
            as_nobody=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("rc=0 writable=yes", result.stdout)

    def test_system_install_dry_run_previews_targeted_acl(self) -> None:
        system_root = Path(
            tempfile.mkdtemp(prefix="esl-system.", dir=os.environ.get("TMPDIR", "/tmp"))
        )
        try:
            system_root.chmod(0o755)
            app = system_root / "spotify"
            (app / "Apps").mkdir(parents=True)
            (app / "Apps" / "xpui.spa").write_text("stock", encoding="utf-8")
            (app / "Apps").chmod(0o555)
            result = self.bash(
                """
                # Synthetic non-owner boundary: the fixture may be runner-owned
                # in nonroot CI, so force the system-install ACL preview branch.
                _is_user_owned() { return 1; }
                SPOTIFY_APP_FILES_PATH=%s
                DRY_RUN=1
                _ensure_writable
                """
                % app,
                as_nobody=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("targeted ACL", result.stdout)
            self.assertIn("default ACL", result.stdout)
            self.assert_no_log("sudo.log")
        finally:
            shutil.rmtree(system_root, ignore_errors=True)

    def test_system_scope_normalizes_read_not_write(self) -> None:
        system_root = Path(
            tempfile.mkdtemp(prefix="esl-normalize.", dir=os.environ.get("TMPDIR", "/tmp"))
        )
        try:
            system_root.chmod(0o755)
            app = system_root / "spotify"
            apps = app / "Apps"
            (apps / "xpui").mkdir(parents=True)
            (apps / "xpui" / "index.html").write_text("patched", encoding="utf-8")
            app.chmod(0o755)
            apps.chmod(0o700)
            (apps / "xpui").chmod(0o700)
            (apps / "xpui" / "index.html").chmod(0o700)
            outside = system_root / "outside.txt"
            outside.write_text("secret", encoding="utf-8")
            outside.chmod(0o600)
            (apps / "external-link").symlink_to(outside)
            result = self.bash(
                """
                SPOTIFY_APP_FILES_PATH=%s
                SPOTIFY_SCOPE=system
                DRY_RUN=0
                _normalize_system_read
                printf 'rc=%%s\n' "$?"
                """
                % app
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("rc=0", result.stdout)
            for path in (apps, apps / "xpui", apps / "xpui" / "index.html"):
                mode = stat.S_IMODE(path.stat().st_mode)
                self.assertEqual(mode & 0o002, 0, f"world-writable: {path}")
                self.assertNotEqual(mode & 0o004, 0, f"not world-readable: {path}")
            self.assertEqual(stat.S_IMODE(outside.stat().st_mode), 0o600)
            if os.geteuid() == 0 and shutil.which("runuser"):
                other_read = subprocess.run(
                    ["runuser", "-u", "nobody", "--", "test", "-r", str(apps / "xpui" / "index.html")],
                    timeout=30,
                )
                self.assertEqual(other_read.returncode, 0)
        finally:
            shutil.rmtree(system_root, ignore_errors=True)

    def test_close_spotify_does_not_treat_yes_as_permission_to_patch(self) -> None:
        result = self.bash(
            """
            SPOTIFY_TYPE=native
            ASSUME_YES=1
            FAKE_SPOTIFY_RUNNING=1
            export FAKE_SPOTIFY_RUNNING
            ( close_spotify )
            printf 'rc=%s\\n' "$?"
            """
        )
        self.assertIn("rc=1", result.stdout)
        self.assertIn("refusing to patch while it is open", result.stdout)
        self.assert_no_log("spicetify.log")


class InstallerTests(Harness):
    def test_resolve_release_uses_official_digest(self) -> None:
        result = self.bash(
            """
            _resolve_release
            printf 'rc=%s version=%s url=%s sha=%s\\n' "$?" "$CLI_VERSION" "$CLI_ARCHIVE_URL" "$CLI_ARCHIVE_SHA256"
            """
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("version=2.46.4", result.stdout)
        self.assertIn(f"sha={self.cli_digest}", result.stdout)
        self.assertIn("linux-amd64", result.stdout)

    def test_unsupported_arch_is_honest_and_makes_no_request(self) -> None:
        result = self.bash(
            """
            _resolve_release
            printf 'rc=%s\\n' "$?"
            """,
            env={"FAKE_UNAME_M": "aarch64"},
        )
        self.assertIn("rc=1", result.stdout)
        self.assertIn("linux amd64 only", self.combined(result).lower())
        self.assert_no_log("curl.log")

    def test_official_release_install_verifies_and_installs(self) -> None:
        result = self.bash(
            """
            install_cli
            printf 'rc=%s exists=%s\\n' "$?" "$([ -x "$SPICETIFY_INSTALL_DIR/spicetify" ] && echo yes || echo no)"
            """,
            env={"PATH": self.test_path_nospice},
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("rc=0 exists=yes", result.stdout)
        self.assertTrue((self.home / ".spicetify" / "spicetify").exists())
        self.assertIn("SHA-256 verified", result.stdout)

    def test_checksum_mismatch_fails_and_cleans_temp(self) -> None:
        result = self.bash(
            """
            install_cli
            """,
            env={
                "PATH": self.test_path_nospice,
                "SPICETIFY_INSTALL_URL": "https://example.invalid/spicetify.tar.gz",
                "SPICETIFY_INSTALLER_SHA256": "0" * 64,
            },
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("SHA-256 mismatch", self.combined(result))
        self.assertFalse((self.home / ".spicetify" / "spicetify").exists())
        self.assertEqual(list(self.tmpdir.glob("spicetify-universal.*")), [])

    def test_legacy_installer_failure_propagates(self) -> None:
        legacy_digest = sha256(self.legacy_script)
        result = self.bash(
            """
            install_cli
            """,
            env={
                "PATH": self.test_path_nospice,
                "SPICETIFY_INSTALL_URL": "https://example.invalid/install.sh",
                "SPICETIFY_INSTALLER_SHA256": legacy_digest,
                "FAKE_LEGACY_EXIT": "7",
            },
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("Custom installer failed", self.combined(result))
        self.assertNotIn("installed successfully", result.stdout)
        self.assertIn("legacy", self.read_log("legacy.log"))
        self.assertEqual(list(self.tmpdir.glob("spicetify-universal.*")), [])

    def test_exit_trap_cleans_private_temp_dir(self) -> None:
        result = self.bash(
            """
            _ensure_tmp
            printf '%s\n' "$_TMP_DIR"
            exit 0
            """
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(list(self.tmpdir.glob("spicetify-universal.*")), [])

    def test_existing_cli_is_not_reinstalled(self) -> None:
        result = self.bash(
            """
            install_cli
            printf 'rc=%s\\n' "$?"
            """
        )
        self.assertIn("rc=0", result.stdout)
        self.assertIn("Not reinstalling", result.stdout)
        self.assert_no_log("curl.log")
        self.assertIn("--version", self.read_log("spicetify.log"))

    def test_existing_cli_is_not_executed_during_dry_run(self) -> None:
        result = self.bash(
            """
            DRY_RUN=1
            install_cli
            printf 'rc=%s\\n' "$?"
            """
        )
        self.assertIn("rc=0", result.stdout)
        self.assertIn("would not reinstall", result.stdout)
        self.assert_no_log("spicetify.log")


class RepairTests(Harness):
    def _repair(
        self, extra: str = "", env: dict[str, str] | None = None
    ) -> subprocess.CompletedProcess[str]:
        return self.bash(
            """
            SPOTIFY_TYPE_OPT=native
            SPOTIFY_PATH_OPT=$APP
            PREFS_PATH_OPT=$PREFS
            ASSUME_YES=1
            INSTALL_MARKETPLACE=0
            %s
            ( _run_repair )
            printf 'rc=%%s\\n' "$?"
            """
            % extra,
            env=env,
        )

    def test_repair_stock_runs_backup_apply(self) -> None:
        app, prefs = self.make_native_install()
        result = self._repair(env={"APP": str(app), "PREFS": str(prefs)})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("rc=0", result.stdout)
        log = self.read_log("spicetify.log")
        self.assertIn("config spotify_path", log)
        self.assertIn("backup apply --no-restart", log)
        self.assertNotIn("restore", log)

    def test_repair_mixed_runs_backup_apply(self) -> None:
        app, prefs = self.make_native_install()
        (app / "Apps" / "xpui").mkdir()
        result = self._repair(env={"APP": str(app), "PREFS": str(prefs)})
        self.assertIn("rc=0", result.stdout)
        log = self.read_log("spicetify.log")
        self.assertIn("backup apply --no-restart", log)
        self.assertNotIn("restore", log)

    def test_backup_state_accepts_quoted_prefs_version(self) -> None:
        app, prefs = self.make_native_install()
        (app / "Apps" / "xpui.spa").unlink()
        (app / "Apps" / "xpui").mkdir()
        (app / "Apps" / "xpui" / "index.html").write_text("patched", encoding="utf-8")
        prefs.write_text('app.last-launched-version="1.2.3"\n', encoding="utf-8")
        backup = self.state_home / "spicetify" / "Backup"
        backup.mkdir(parents=True)
        (backup / "xpui.spa").write_text("backup", encoding="utf-8")
        config = self.config_home / "spicetify" / "config-xpui.ini"
        config.parent.mkdir(parents=True)
        config.write_text("[Backup]\nversion = 1.2.3\n", encoding="utf-8")
        result = self.bash(
            """
            SPOTIFY_APP_FILES_PATH=%s
            SPOTIFY_PREFS_PATH=%s
            _backup_state
            """
            % (app, prefs)
        )
        self.assertEqual(result.stdout.strip(), "BACKUPED")

    def test_config_readback_mismatch_aborts_before_patch(self) -> None:
        app, prefs = self.make_native_install()
        result = self.bash(
            """
            SPOTIFY_APP_FILES_PATH=%s
            SPOTIFY_PREFS_PATH=%s
            ( _configure_paths )
            printf 'rc=%%s\n' "$?"
            """
            % (app, prefs),
            env={"FAKE_SPICETIFY_CONFIG_MISMATCH": "1"},
        )
        self.assertIn("rc=1", result.stdout)
        self.assertIn("did not persist", self.combined(result))
        self.assertNotIn("backup apply", self.read_log("spicetify.log"))

    def test_repair_patched_with_matching_backup_runs_restore_backup_apply(
        self,
    ) -> None:
        app, prefs = self.make_native_install()
        (app / "Apps" / "xpui.spa").unlink()
        (app / "Apps" / "xpui").mkdir()
        (app / "Apps" / "xpui" / "index.html").write_text("patched", encoding="utf-8")
        backup = self.state_home / "spicetify" / "Backup"
        backup.mkdir(parents=True)
        (backup / "xpui.spa").write_text("backup", encoding="utf-8")
        config = self.config_home / "spicetify" / "config-xpui.ini"
        config.parent.mkdir(parents=True)
        config.write_text("[Backup]\nversion = 1.2.3\n", encoding="utf-8")
        result = self._repair(env={"APP": str(app), "PREFS": str(prefs)})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("rc=0", result.stdout)
        log = self.read_log("spicetify.log")
        self.assertIn("restore backup apply --no-restart", log)

    def test_repair_patched_with_outdated_backup_fails_without_deletion(self) -> None:
        app, prefs = self.make_native_install()
        (app / "Apps" / "xpui.spa").unlink()
        (app / "Apps" / "xpui").mkdir()
        (app / "Apps" / "xpui" / "index.html").write_text("patched", encoding="utf-8")
        backup = self.state_home / "spicetify" / "Backup"
        backup.mkdir(parents=True)
        backup_file = backup / "xpui.spa"
        backup_file.write_text("precious-backup", encoding="utf-8")
        config = self.config_home / "spicetify" / "config-xpui.ini"
        config.parent.mkdir(parents=True)
        config.write_text("[Backup]\nversion = 0.9.0\n", encoding="utf-8")
        result = self._repair(env={"APP": str(app), "PREFS": str(prefs)})
        self.assertIn("rc=1", result.stdout)
        self.assertIn("Refusing to repair automatically", self.combined(result))
        log = self.read_log("spicetify.log")
        self.assertNotIn("restore", log)
        self.assertNotIn("backup apply", log)
        self.assertEqual(backup_file.read_text(encoding="utf-8"), "precious-backup")

    def test_repair_patched_without_backup_fails(self) -> None:
        app, prefs = self.make_native_install()
        (app / "Apps" / "xpui.spa").unlink()
        (app / "Apps" / "xpui").mkdir()
        (app / "Apps" / "xpui" / "index.html").write_text("patched", encoding="utf-8")
        result = self._repair(env={"APP": str(app), "PREFS": str(prefs)})
        self.assertIn("rc=1", result.stdout)
        self.assertIn("Refusing to repair automatically", self.combined(result))
        self.assertNotIn("restore", self.read_log("spicetify.log"))


class RestoreAndUninstallTests(Harness):
    def _managed_layout(self) -> None:
        self.make_native_install()
        (self.home / ".spicetify").mkdir()
        (self.home / ".spicetify" / "spicetify").write_text("fake", encoding="utf-8")
        (self.config_home / "spicetify").mkdir(parents=True)
        (self.config_home / "spicetify" / "config-xpui.ini").write_text(
            "[Setting]\n", encoding="utf-8"
        )
        (self.config_home / "spicetify" / "Themes").mkdir()
        (self.state_home / "spicetify" / "Backup").mkdir(parents=True)
        (self.state_home / "spicetify" / "Backup" / "xpui.spa").write_text(
            "backup", encoding="utf-8"
        )

    def test_restore_only_runs_restore_no_restart_and_preserves_files(self) -> None:
        self._managed_layout()
        result = self.bash(
            """
            ( _run_restore )
            printf 'rc=%s\\n' "$?"
            """
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("rc=0", result.stdout)
        self.assertIn("restore --no-restart", self.read_log("spicetify.log"))
        self.assertTrue((self.home / ".spicetify" / "spicetify").exists())
        self.assertTrue((self.config_home / "spicetify" / "Themes").exists())
        self.assertTrue(
            (self.state_home / "spicetify" / "Backup" / "xpui.spa").exists()
        )

    def test_restore_failure_preserves_everything(self) -> None:
        self._managed_layout()
        result = self.bash(
            """
            ( _run_restore )
            printf 'rc=%s\\n' "$?"
            """,
            env={
                "FAKE_SPICETIFY_FAIL_PATTERN": "restore",
                "FAKE_SPICETIFY_FAIL_CODE": "1",
            },
        )
        self.assertIn("rc=1", result.stdout)
        self.assertTrue((self.home / ".spicetify" / "spicetify").exists())
        self.assertTrue((self.config_home / "spicetify" / "config-xpui.ini").exists())
        self.assertTrue(
            (self.state_home / "spicetify" / "Backup" / "xpui.spa").exists()
        )

    def test_uninstall_failed_restore_aborts_before_deletion(self) -> None:
        self._managed_layout()
        result = self.bash(
            """
            ( _run_uninstall )
            printf 'rc=%s\\n' "$?"
            """,
            env={
                "FAKE_SPICETIFY_FAIL_PATTERN": "restore",
                "FAKE_SPICETIFY_FAIL_CODE": "1",
            },
        )
        self.assertIn("rc=1", result.stdout)
        self.assertIn("nothing was removed", self.combined(result))
        self.assertTrue((self.home / ".spicetify" / "spicetify").exists())
        self.assertTrue((self.config_home / "spicetify" / "config-xpui.ini").exists())
        self.assertTrue(
            (self.state_home / "spicetify" / "Backup" / "xpui.spa").exists()
        )

    def test_uninstall_removes_only_managed_data_and_keeps_unrelated_lines(
        self,
    ) -> None:
        self._managed_layout()
        unrelated = self.home / "unrelated.txt"
        unrelated.write_text("keep", encoding="utf-8")
        bashrc = self.home / ".bashrc"
        bashrc.write_text(
            "\n".join(
                [
                    "# user line",
                    'export PATH="$HOME/.spicetify-old:$PATH"',
                    "# >>> spicetify-universal >>>",
                    'export PATH="$HOME/.spicetify:$PATH"',
                    "# <<< spicetify-universal <<<",
                    "alias hi='echo hi'",
                    "",
                ]
            ),
            encoding="utf-8",
        )
        result = self.bash(
            """
            ( _run_uninstall )
            printf 'rc=%s\\n' "$?"
            """
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("rc=0", result.stdout)
        self.assertIn("restore --no-restart", self.read_log("spicetify.log"))
        self.assertFalse((self.home / ".spicetify").exists())
        self.assertFalse((self.config_home / "spicetify").exists())
        self.assertFalse((self.state_home / "spicetify").exists())
        self.assertTrue(unrelated.exists())
        content = bashrc.read_text(encoding="utf-8")
        self.assertIn('export PATH="$HOME/.spicetify-old:$PATH"', content)
        self.assertIn("alias hi='echo hi'", content)
        self.assertNotIn("# >>> spicetify-universal >>>", content)

    def test_uninstall_without_cli_and_with_traces_aborts(self) -> None:
        (self.config_home / "spicetify").mkdir(parents=True)
        (self.config_home / "spicetify" / "config-xpui.ini").write_text(
            "[Setting]\n", encoding="utf-8"
        )
        result = self.bash(
            """
            PATH=%s
            export PATH
            ( _run_uninstall )
            printf 'rc=%%s\\n' "$?"
            """
            % self.test_path_nospice,
            env={"PATH": self.test_path_nospice},
        )
        self.assertIn("rc=1", result.stdout)
        self.assertIn("restore cannot be verified", self.combined(result))
        self.assertTrue((self.config_home / "spicetify" / "config-xpui.ini").exists())

    def test_rc_symlink_is_not_edited_or_followed(self) -> None:
        target = self.root / "dotfiles" / "bashrc"
        target.parent.mkdir()
        target.write_text("original\n", encoding="utf-8")
        link = self.home / ".bashrc"
        link.symlink_to(target)
        result = self.bash(
            """
            ASSUME_YES=1
            make_path_persistent
            _remove_path_block %s
            printf 'rc=%%s\\n' "$?"
            """
            % link
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(target.read_text(encoding="utf-8"), "original\n")
        self.assertIn("symlinked shell config", result.stdout)


class ShellPathTests(Harness):
    def test_bash_path_block_is_idempotent_and_uninstall_keeps_unrelated(self) -> None:
        bashrc = self.home / ".bashrc"
        bashrc.write_text(
            'export PATH="$HOME/.spicetify-old:$PATH"\n', encoding="utf-8"
        )
        result = self.bash(
            """
            ASSUME_YES=1
            SHELL=/bin/bash
            make_path_persistent
            make_path_persistent
            printf 'count=%%s\\n' "$(grep -c '^# >>> spicetify-universal >>>' %s)"
            """
            % bashrc
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("count=1", result.stdout)
        content = bashrc.read_text(encoding="utf-8")
        self.assertIn("$HOME/.spicetify-old", content)
        self.assertIn('export PATH="$HOME/.spicetify:$PATH"', content)

    def test_malformed_path_block_is_preserved(self) -> None:
        bashrc = self.home / ".bashrc"
        original = (
            "# <<< spicetify-universal <<<\n"
            'export PATH="$HOME/.spicetify:$PATH"\n'
            "# >>> spicetify-universal >>>\n"
        )
        bashrc.write_text(original, encoding="utf-8")
        result = self.bash(
            """
            ASSUME_YES=1
            SHELL=/bin/bash
            make_path_persistent
            _remove_path_block %s
            printf 'rc=%%s\n' "$?"
            """
            % bashrc
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(bashrc.read_text(encoding="utf-8"), original)
        self.assertIn("malformed", self.combined(result))

    def test_zsh_uses_zdotdir_and_fish_uses_xdg_config(self) -> None:
        result = self.bash(
            """
            ASSUME_YES=1
            SHELL=/bin/zsh
            make_path_persistent
            SHELL=/usr/bin/fish
            make_path_persistent
            printf 'zsh=%%s fish=%%s\\n' "$([ -f %s/.zshrc ] && echo yes || echo no)" "$([ -f %s/fish/config.fish ] && echo yes || echo no)"
            """
            % (self.zdotdir, self.config_home)
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("zsh=yes fish=yes", result.stdout)
        self.assertIn(
            "fish_add_path",
            (self.config_home / "fish" / "config.fish").read_text(encoding="utf-8"),
        )


class MarketplaceTests(Harness):
    def test_marketplace_installs_verified_release_after_apply(self) -> None:
        result = self.bash(
            """
            INSTALL_MARKETPLACE=1
            ASSUME_YES=1
            _maybe_marketplace
            printf 'rc=%s\\n' "$?"
            """
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("rc=0", result.stdout)
        self.assertTrue(
            (
                self.config_home
                / "spicetify"
                / "CustomApps"
                / "marketplace"
                / "manifest.json"
            ).exists()
        )
        log = self.read_log("spicetify.log")
        self.assertIn("config custom_apps marketplace", log)
        self.assertIn("apply --no-restart", log)
        self.assertIn("SHA-256 verified", result.stdout)

    def test_marketplace_failure_is_reported_not_claimed(self) -> None:
        result = self.bash(
            """
            INSTALL_MARKETPLACE=1
            ASSUME_YES=1
            _maybe_marketplace
            printf 'rc=%s\\n' "$?"
            """,
            env={"FAKE_CURL_FAIL": "1"},
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("rc=0", result.stdout)
        self.assertIn("NOT installed", result.stdout)
        self.assertFalse(
            (self.config_home / "spicetify" / "CustomApps" / "marketplace").exists()
        )



class FullCliStrictTests(Harness):
    def _install_fake_cli(self) -> None:
        install_dir = self.home / ".spicetify"
        install_dir.mkdir()
        write_exec(install_dir / "spicetify", FAKE_SPICETIFY_BODY)

    def _args(self, app: Path, prefs: Path) -> list[str]:
        return [
            "--yes",
            "--no-marketplace",
            "--spotify-type",
            "native",
            "--spotify-path",
            str(app),
            "--prefs-path",
            str(prefs),
        ]

    def _run(self, *args: str) -> subprocess.CompletedProcess[str]:
        return self.cli_as_nobody(
            *args,
            env={"PATH": self.test_path_nospice},
        )

    def test_full_cli_setup_strict_as_ordinary_user(self) -> None:
        app, prefs = self.make_native_install()
        result = self._run(*self._args(app, prefs))
        self.assertEqual(result.returncode, 0, self.combined(result))
        self.assertTrue((self.home / ".spicetify" / "spicetify").exists())
        self.assertIn("# >>> spicetify-universal >>>", (self.home / ".bashrc").read_text(encoding="utf-8"))
        self.assertIn("backup apply --no-restart", self.read_log("spicetify.log"))

    def test_full_cli_repair_strict_as_ordinary_user(self) -> None:
        self._install_fake_cli()
        app, prefs = self.make_native_install()
        result = self._run("--repair", *self._args(app, prefs))
        self.assertEqual(result.returncode, 0, self.combined(result))
        self.assertIn("backup apply --no-restart", self.read_log("spicetify.log"))

    def test_full_cli_restore_strict_as_ordinary_user(self) -> None:
        self._install_fake_cli()
        app, prefs = self.make_native_install()
        result = self._run("--restore", *self._args(app, prefs))
        self.assertEqual(result.returncode, 0, self.combined(result))
        self.assertIn("restore --no-restart", self.read_log("spicetify.log"))

    def test_full_cli_uninstall_strict_as_ordinary_user(self) -> None:
        self._install_fake_cli()
        app, prefs = self.make_native_install()
        config = self.config_home / "spicetify" / "config-xpui.ini"
        config.parent.mkdir(parents=True)
        config.write_text("[Setting]\n", encoding="utf-8")
        backup = self.state_home / "spicetify" / "Backup"
        backup.mkdir(parents=True)
        (backup / "xpui.spa").write_text("backup", encoding="utf-8")
        result = self._run("--uninstall", *self._args(app, prefs))
        self.assertEqual(result.returncode, 0, self.combined(result))
        self.assertFalse((self.home / ".spicetify").exists())
        self.assertFalse((self.config_home / "spicetify").exists())
        self.assertFalse((self.state_home / "spicetify").exists())
        self.assertIn("restore --no-restart", self.read_log("spicetify.log"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
