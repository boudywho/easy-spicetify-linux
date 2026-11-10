# Changelog

All notable changes to easy-spicetify-linux are documented in this file.

## [3.1.0] - 2026-11-10

### Breaking changes
- **`setup.conf` is no longer sourced.** It was an undocumented shell-execution risk. Existing
  files are reported and ignored; use the CLI flags/environment instead.
- **Dependency auto-install was removed.** Missing commands now produce explicit, distro-aware
  install hints instead of running broad package-manager operations.
- **`SPICETIFY_STATE` is rejected.** Spicetify v2.46.4 treats that override differently (it skips
  the `/Backup` suffix), so recovery would be unsafe. Use `XDG_STATE_HOME`.

### Added
- Experimental native Spotify discovery for Debian/Ubuntu `/usr/share/spotify`, Arch/AUR
  `/opt/spotify`, and `spotify-launcher` under `$XDG_DATA_HOME`.
- `--repair`/`--fix`: state-aware recovery after Spotify updates. Stock/mixed uses
  `spicetify backup apply --no-restart`; already-patched with a matching backup uses
  `spicetify restore backup apply --no-restart`; outdated/empty backups fail safely.
- `--restore`: runs only `spicetify restore --no-restart` and preserves CLI/themes/settings/backups.
- `--yes`, `--spotify-type`, `--spotify-path`, `--prefs-path`, and `--no-marketplace`.
- Verified direct Marketplace release installation after a successful apply.

### Changed
- Genuinely read-only `--dry-run` in every mode and ordering; no config sourcing, downloads,
  package/spicetify calls, process signals, rc edits, or deletions.
- Official Spicetify releases are downloaded over HTTPS with retries/timeouts and required
  SHA-256 verification from the release API. Custom URLs remain supported; a supplied checksum is
  always verified.
- Existing CLI installations are never reinstalled automatically.
- Permissions use narrow `u+rwX` for user-owned trees and consented targeted `setfacl` ACLs for
  system installs. System-wide installs get read/traverse-only normalization after apply/restore.
- Repair/restore/uninstall rediscover the Spotify target and verify config read-back before
  destructive work; system paths are supported without guessing.
- PATH blocks are marker-validated, malformed blocks are preserved, and uninstall removes only the
  managed block.
- Uninstall prevalidates all targets before restoring and removes only directories with evidence
  (`spicetify` binary, `config-xpui.ini`, `Backup`/`Extracted`); symlinked/untrusted paths are
  preserved with manual instructions.
- README identity/links corrected to `easy-spicetify-linux`; native support documented as
  experimental, with limitations and no GUI proof claimed.

### Fixed
- Dry-run no longer calls `spicetify config`, writes rc files, downloads, or removes anything.
- Temp files are tracked correctly and cleaned on failure/signals.
- `printf` argument mismatches, nounset `EUID`/`SUDO_USER` paths, and Flatpak process detection
  (`--columns=application`) fixed.
- Quoted Spotify prefs versions are handled when comparing backup state.
- Nested symlinks under `Apps` are rejected except the exact upstream `xpui/extensions/node_modules` link to a trusted `Extensions/node_modules` directory; arbitrary internal containment is not trusted.
- Marketplace no longer inherits the upstream theme-replacement bug and no longer resets extra
  settings.

### Security
- No world-writable `chmod`, no recursive `chown`, no broad XDG/root deletions, and no
  unverified official artifacts.

## [3.0.6] - 2026-05-02
### Added
- **Strict Mode & Safety Flags:** Script now uses `set -eEuo pipefail` for safer execution. Added `DEBUG`, `DRY_RUN`, and `VERBOSE` environment variables for flexible control.
- **Custom Installer URL:** Can override Spicetify installer URL via `SPICETIFY_INSTALL_URL` environment variable.
- **SHA256 Integrity Check:** Added optional `SPICETIFY_INSTALLER_SHA256` env var to verify installer integrity.
- **Temp File Management:** New `_cleanup_tmp` trap and `_mktemp` function ensures proper temp file cleanup on exit.
- **Dry-Run Mode:** Run with `DRY_RUN=1` or `-n/--dry-run` to see what would be executed without making changes.
- **Uninstall Support:** New `-u/--uninstall` flag to remove Spicetify and restore Spotify to vanilla state. Cleans up CLI, config, and PATH entries.
- **Pre-flight Checks:** New `preflight_checks()` function displays distro, package manager, user, shell, and bash version info.
- **Distro-Specific Hints:** New `show_distro_hints()` provides tailored instructions for Alpine, Arch, Debian, Ubuntu, Fedora, RHEL, and CentOS.
- **Config File Support:** Optional `~/.config/spicetify-setup/setup.conf` for pre-configuration. Validates permissions before sourcing.

### Changed
- **Improved Color Handling:** New `_color_support()` and `_color()` functions properly detect dumb/non-color terminals and fall back gracefully.
- **Enhanced Package Manager Detection:** Now reads `/etc/os-release` for ID and ID_LIKE for more accurate distro detection.
- **Extended Distro Support:** Added support for Alpine (apk), Gentoo (emerge), Void (xbps), Solus (eopkg), Clear (swupd), and NixOS (nix) package managers.
- **Improved Path Detection:** Now checks user installation first before system-wide for Spotify Flatpak detection.
- **Better Shell Detection:** Uses `/proc/$$/exe` as primary method for shell detection, falling back to `$SHELL`.

### Fixed
- **Debug Output:** New `log_debug()` function properly outputs debug information only when `DEBUG=1`.
- **Interactive Detection:** New `_is_interactive()` function correctly detects if stdin/stdout are connected to a TTY.
- **Better Error Messages:** Installer failure now shows "Spicetify command not found after installation" instead of generic message.

## [3.0.4] - 2026-04-30
### Added
- **Auto-Kill Spotify:** Added a `kill_spotify` function that silently checks if the Spotify Flatpak is running in the background and automatically terminates it. This prevents file lock errors when the script attempts to patch or restore Spotify files.
- Added automatic hooks to ensure Spotify is closed right before configuring, patching, and applying the theme.

## [3.0.3] - 2026-04-30
### Fixed
- **Color Rendering Bug:** Fixed an issue where the terminal would print raw ANSI escape codes (e.g., `\033[0;36m`) instead of actual colors in the "Next Steps" output at the end of the script. Replaced `%s` with `%b` in the UI helper functions to correctly parse string escape sequences.

## [3.0.2] - 2026-04-30
### Added
- **Dependency check for `unzip`**: Added `unzip` to the automated package installation checks, as it is strictly required by the official Spicetify Marketplace installer.

### Changed
- Improved Spicetify install command execution by downloading to a temporary file (`mktemp`). This preserves terminal standard input, allowing users to interactively answer the "Install Marketplace?" prompt without issues.

### Fixed
- **Marketplace Crash Loophole:** Fixed a bug where installing the Spicetify Marketplace would cause the script to abort prematurely. The Marketplace installer runs `spicetify apply` at the end, which throws an error code because the Flatpak paths aren't configured yet. The script now correctly anticipates and bypasses this specific error.

## [3.0.1] - 2026-04-30
### Added
- **Sudo Execution Safeguard:** Added a check that prevents users from running the entire script as root (e.g., `sudo ./script.sh`), which breaks local directory configurations. The script now explicitly tells the user to run it normally, as it handles privilege escalation internally when needed.

### Changed
- **Flatpak Install Flow:** If Flatpak is not installed, the script will offer to install it but will now safely exit afterward with instructions to install Spotify manually, preventing a crash from trying to immediately locate a non-existent Spotify instance.

### Fixed
- **Silent Network Failures:** Fixed a critical flaw where a failure to download the Spicetify script via `curl` would pass an empty string to `bash`, resulting in a false "Success" message. Errors are now properly caught and exit the script.
- **`chmod` Syntax Issue:** Corrected POSIX compliance for the `chmod` command (changed `chmod a+wr -R` to `chmod -R a+wr`) which previously threw invalid operand errors on some environments.
- **Fish Shell Config Bug:** Fixed an issue where persistent PATH exporting for the Fish shell would fail if the user's `~/.config/fish` directory had never been created.

## [3.0.0] - Universal Release
### Added
- **Universal Distro Support:** The script is no longer fragmented into two files. It dynamically detects `pacman`, `apt`, `dnf`, `yum`, or `zypper` and acts accordingly.
- Native PATH persistence handling for `bash`, `zsh`, and `fish` shells.
- Completely rewritten codebase for enhanced UI layout and helper logic.

## [2.3.3] - 2025-02-12
### Fixed
- Changed the order of operations. The script now grants filesystem permissions **before** running the Spicetify installer. This prevents the "fatal: permission denied" error when the installer tries to apply patches immediately.
- Reset `color_scheme` to auto/empty to prevent "scheme not found" warnings on fresh installs.

## [2.3.2] - 2025-02-11
### Fixed
- Addressed the "Color scheme 'dark' not found" warning by ensuring the config defaults to a valid scheme or auto-detection.

## [2.3.1] - 2025-02-11
### Fixed
- Stopped relying on sourcing `.bashrc` or `.zshrc` to find the spicetify binary, which often failed in non-interactive modes. The script now explicitly adds `~/.spicetify` to the PATH for the current session.
- Added a manual trigger for the Marketplace installer if the main installer exits with code 127.

## [2.3.0] - 2025-02-09
### Changed
- **Major Reliability Update**: Correct shell detection uses `$SHELL` to avoid sourcing the wrong rc file.
- Applies `set +e` after loading shell configs to prevent user-defined options from breaking the installer.
- Automatically detects and edits the correct Spicetify config file using `spicetify -c`.

## [2.2.0] - 2025-02-08
### Changed
- Replaced ad-hoc echo spam with structured output helpers (`script_title`, `task_running`, etc).
- Introduced a more consistent color scheme and layout for better readability.

*(For full historical changes, please refer to commit history).*