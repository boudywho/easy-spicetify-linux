# Native Spotify support and recovery — design

## Goal

Modernize the single-script installer for `easy-spicetify-linux` without turning it into a
framework. Keep the friendly Flatpak flow, add clearly experimental native Spotify support
(Debian/Ubuntu, Arch/AUR, `spotify-launcher`), make dry-run genuinely non-mutating, replace
blanket permission changes with targeted ownership/ACL handling, and add explicit recovery modes
for Spotify updates (`--repair`, `--restore`) and a safe uninstall.

## Architecture

One Bash entry point (`spicetify-universal.sh`) with a source-safe `main` guard:

- **Argument layer** — parse every argument first, with precedence `CLI > environment > default`.
  `setup.conf` is deprecated and never sourced; its presence is reported and ignored.
- **Discovery layer** — collect Flatpak and native candidates, validate the app tree and prefs
  file, canonicalise paths, reject Snap/Nix/immutable and broad targets, and never create a fake
  installation. Ambiguity is resolved by the user or by an explicit selector.
- **Safety layer** — root guard, noninteractive consent, private temp dirs with signal cleanup,
  HTTPS-only downloads with checksums, targeted permissions, Spotify process close before each
  actual patch, and a dry-run path that only reads and prints.
- **Action layer** — setup, repair, restore, uninstall. Each action has an explicit success
  boundary and propagates failures; no destructive fallback after a generic failure.
- **Output layer** — existing help/debug/dry-run/uninstall/version/verbose UX preserved, plus
  experimental/native warnings and exact recovery guidance.

External boundaries (`curl`, `flatpak`, `spicetify`, `sudo`, `setfacl`, `pkill`/`pgrep`,
`uname`) are called through small helpers so tests can intercept them. Missing dependencies are
reported with explicit install commands; the script does not run broad package installs.

## Tech Stack

- Bash >= 4, `curl`, `tar`, `sha256sum` (or `shasum`), `unzip` only for Marketplace.
- Python 3 standard-library `unittest` for tests; no Python runtime dependency for the script.
- GitHub Actions on Ubuntu 22.04/24.04: Bash syntax, ShellCheck, Python tests.

## Spec

### CLI contract

```
spicetify-universal.sh [OPTIONS]
  -h, --help                 Show help
  -d, --debug                set -x
  -n, --dry-run              Preview only; create nothing, no network/package/spicetify calls
  -u, --uninstall            Restore, then remove only script-managed data
      --repair, --fix        Conservative recovery after a Spotify update
      --restore              Run `spicetify restore` only
  -y, --yes                  Explicit noninteractive consent
      --spotify-type TYPE    auto | flatpak | native
      --spotify-path ABS     Explicit Spotify app directory
      --prefs-path ABS       Explicit Spotify prefs file
      --no-marketplace       Skip Marketplace installation
  -v, --version              Show version
  -V, --verbose              Verbose output
```

Modes are mutually exclusive. Parse all arguments before any action, including
`--dry-run --uninstall`. Unknown options and missing values fail with usage.

### Discovery and validation

- Flatpak: `flatpak info --user/--system --show-location com.spotify.Client`, then
  `files/extra/share/spotify` or `files/share/spotify`.
- Native known paths: `/usr/share/spotify` (Debian/Ubuntu), `/opt/spotify` (Arch/AUR),
  `${XDG_DATA_HOME:-$HOME/.local/share}/spotify-launcher/install/usr/share/spotify`.
- Prefs: Flatpak `~/.var/app/com.spotify.Client/config/spotify/prefs`; native
  `${XDG_CONFIG_HOME:-$HOME/.config}/spotify/prefs`.
- An app directory must be a real directory containing `Apps/` with `xpui.spa` or clearly
  patched content. Prefs must already exist; the error tells the user to open Spotify once.
- Canonical paths must not be `/`, `$HOME`, an ancestor of `$HOME`, or broad system roots.
  `/snap/...`, `/nix/store/...` and symlinks resolving there are rejected, never removed.
- One valid candidate is selected. Multiple candidates prompt interactively or fail
  noninteractively with an instruction to pass `--spotify-type`/`--spotify-path`.

### Config and environment

- `setup.conf` is deprecated: report it and ignore it. It was an undocumented shell-execution
  risk; CLI flags/environment replace it (breaking change in 3.1.0).
- Environment: `DEBUG`, `DRY_RUN`, `VERBOSE`, `SPICETIFY_INSTALL_URL`,
  `SPICETIFY_INSTALLER_SHA256`, `SPICETIFY_CONFIG`, and the XDG/ZDOTDIR variables.
- Respect `XDG_CONFIG_HOME`, `XDG_STATE_HOME`, `XDG_DATA_HOME`, `SPICETIFY_CONFIG`,
  `ZDOTDIR`, and `SHELL` for rc-file selection. The CLI installs to the upstream
  `$HOME/.spicetify` directory. Reject a nonempty `SPICETIFY_STATE` with actionable
  guidance: Spicetify v2.46.4's override branch does not append `/Backup`, so recovery
  would inspect the wrong directory; use `XDG_STATE_HOME` instead.

### Permissions

- Never `chmod a+wr`, never recursive chown, never world-writable.
- User-owned app tree: `chmod -R u+rwX` only when write access is missing.
- Root-owned/system app tree: explain the `setfacl` dependency and ask consent; grant a
  targeted ACL to the current user on the app root, existing `Apps` children, and a default ACL
  on the app root and `Apps` (so recreated content inherits it). Use physical/no-follow
  semantics so external symlink targets are never touched. No sudo for discovery, help or preview.
- After apply/restore for a system-wide install, normalize read/traverse only (`a+rX`, never
  write) on the user-owned recreated `Apps` tree so other users can still read Spotify. Do not
  use broad sudo `find`; fail with an explicit command if the tree is not user-owned.

### Installation and network

- Prefer verified official release archives over the upstream interactive installer. Resolve
  latest, require the GitHub API SHA-256 digest, download
  over HTTPS with redirects restricted to HTTPS, retries and timeouts, extract into a private
  temp dir, then install into the upstream `$HOME/.spicetify` directory.
- Official CLI release assets are currently Linux amd64 only. On other architectures fail
  honestly with package-manager/source guidance; do not fabricate a URL.
- `SPICETIFY_INSTALL_URL`/`SPICETIFY_INSTALLER_SHA256` remain supported for a custom release
  archive or legacy installer script. A supplied checksum is always verified; failures are
  never ignored. Legacy scripts run in a private temp cwd with no controlling tty.
- Existing CLI is never reinstalled automatically.
- Marketplace is installed only after valid paths and a successful backup/apply, with explicit
  consent/`--yes`, from the verified release zip. It never resets an existing theme or extra
  settings, and is never claimed installed when skipped or failed.
- Missing dependencies are reported with explicit `pacman`/`apt`/`dnf`/`yum`/`zypper`/`apk`
  hints. The script does not auto-install packages. Flatpak is not required for native mode and
  is not installed automatically.

### Recovery

- Detect Spotify state from `Apps`: `STOCK` (only `.spa`), `MIXED` (`.spa` + dirs), `APPLIED`
  (only dirs), `INVALID` (empty).
- Detect backup state from `${XDG_STATE_HOME:-$HOME/.local/state}/spicetify/Backup`, the
  config `[Backup] version`, and the prefs `app.last-launched-version`. Reject a nonempty
  `SPICETIFY_STATE` before any mutating CLI call (v2.46.4 quirk).
- Setup: `STOCK`/`MIXED` → `spicetify backup apply --no-restart`; `APPLIED` →
  `spicetify apply --no-restart`; never restore over a freshly updated install.
- Repair: make the target writable, then `STOCK`/`MIXED` → `spicetify backup apply --no-restart`;
  `APPLIED` with a matching backup → `spicetify restore backup apply --no-restart`; `APPLIED`
  with an outdated/empty backup or `INVALID` → fail with exact guidance. The wrapper never issues
  backup deletion or `spicetify clear`; the upstream CLI may refresh a validated stock/mixed
  backup. Never run a destructive fallback or chain `spicetify update` after an arbitrary failure.
- Restore: rediscover/verify the target, make it writable, then run
  `spicetify restore --no-restart`; leave CLI, themes, settings and backups.
- Uninstall: require a successful `spicetify restore --no-restart` before removing anything;
  abort on failure. Remove
  only validated script-managed directories under `$HOME` (not symlinks, not XDG roots) and only
  the marked PATH block. Preserve unrelated rc lines.

### Dry-run

Dry-run may read files and inspect state, but must create no files/dirs, download nothing,
invoke no package manager, no `spicetify config/apply/restore/backup`, no process kill, no rc
edit and no uninstall. It prints truthful planned commands.

## Global Constraints

- Keep the script simple and friendly; no framework, no new runtime dependency.
- Preserve Flatpak support; native support is labelled EXPERIMENTAL at runtime, help and docs.
- Root may run `--help`, `--version` and `--dry-run`; all real mutating actions are refused.
- Do not touch real Spotify processes/config or install host packages during development/tests.
- Tests use isolated temporary HOME/XDG trees and fake external commands; cleanup is deterministic.
- CI is least privilege (`permissions: contents: read`) and pinned actions.

## Review Focus

- Dry-run has no side effects in every mode and ordering.
- No wrong-install patching; ambiguity and unsupported Snap/Nix paths fail safely.
- No world-writable/recursive chown; system ACL is targeted, consent-based and symlink-safe.
- Checksums/failures are never swallowed; temp dirs clean up on failure/signals.
- Repair never restores a stale backup over a new Spotify update; the wrapper never deletes
  backups or calls `spicetify clear` (upstream may refresh a validated stock/mixed backup).
- Uninstall cannot delete arbitrary XDG roots or unrelated rc lines.
