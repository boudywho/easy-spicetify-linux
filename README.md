# 🌶️ easy-spicetify-linux

One friendly Bash script for Spicetify on Linux, with **Flatpak** and **experimental native
Spotify** support. It discovers your Spotify installation, installs the official Spicetify CLI
when needed, configures the paths, applies your theme, and gives you conservative recovery modes
for Spotify updates.

> Native Spotify support is experimental. The verified official Spicetify release binaries are
> currently **Linux amd64 only**; on other architectures the script fails honestly with
> package-manager/source guidance instead of inventing a download URL.

[![License](https://img.shields.io/badge/License-MIT-blue?style=for-the-badge)](./LICENSE)

## Quick start

### Flatpak Spotify (supported)

```bash
flatpak install flathub com.spotify.Client
flatpak run com.spotify.Client   # open once, log in, then close it
git clone https://github.com/boudywho/easy-spicetify-linux.git
cd easy-spicetify-linux
./spicetify-universal.sh
```

### Native Spotify (experimental)

Supported layouts:

- Debian/Ubuntu: `/usr/share/spotify`
- Arch/AUR: `/opt/spotify`
- `spotify-launcher`: `$XDG_DATA_HOME/spotify-launcher/install/usr/share/spotify`

Open Spotify once so `prefs` exists, then run:

```bash
./spicetify-universal.sh --spotify-type native
```

Snap and Nix store installations are unsupported and are never modified. If several Spotify
installations exist, the script asks which one to use; noninteractive runs must pass
`--spotify-type` or `--spotify-path`.

## After a Spotify update

```bash
./spicetify-universal.sh --repair
```

`--repair` inspects the actual Spotify and backup state:

- stock or mixed Apps → `spicetify backup apply --no-restart`
- already patched with a matching backup → `spicetify restore backup apply --no-restart`
- patched with an outdated/empty backup, or an invalid Apps folder → fails with exact guidance

It never restores a stale backup over a newer Spotify client. The script itself never deletes or
clears your backup; the upstream CLI may refresh a validated stock/mixed backup during
`backup apply`. If automatic recovery is unsupported, update Spicetify and reinstall Spotify to
stock before running `spicetify backup apply`.

## Commands

| Option | Description |
| --- | --- |
| `-h, --help` | Show help |
| `-d, --debug` | Enable `set -x` |
| `-n, --dry-run` | Preview only: creates nothing, downloads nothing, calls no mutating tool |
| `-u, --uninstall` | Restore first, then remove only validated Spicetify-managed data |
| `--repair`, `--fix` | Conservative recovery after a Spotify update |
| `--restore` | Run `spicetify restore --no-restart` only |
| `-y, --yes` | Explicit consent for noninteractive runs |
| `--spotify-type auto\|flatpak\|native` | Choose the Spotify installation type |
| `--spotify-path ABS` | Explicit Spotify app directory (must contain `Apps/`) |
| `--prefs-path ABS` | Explicit Spotify prefs file |
| `--no-marketplace` | Skip Marketplace installation |
| `-v, --version` | Show version |
| `-V, --verbose` | Extra preflight detail |

Root may run `--help`, `--version` and `--dry-run`; real setup/repair/restore/uninstall runs are
refused as root.

## Environment

| Variable | Description |
| --- | --- |
| `DEBUG=1`, `DRY_RUN=1`, `VERBOSE=1` | Same as the flags |
| `SPICETIFY_INSTALL_URL=https://...` | Custom HTTPS release archive or legacy installer |
| `SPICETIFY_INSTALLER_SHA256=...` | Recommended integrity check for custom downloads (warns if absent) |
| `SPICETIFY_CONFIG` | Upstream Spicetify config directory |
| `XDG_CONFIG_HOME`, `XDG_STATE_HOME`, `XDG_DATA_HOME`, `ZDOTDIR` | Standard XDG/shell paths |

`SPICETIFY_STATE` is rejected with an explanation: Spicetify v2.46.4 treats that override
differently (it skips the `/Backup` suffix), so recovery would be unsafe. Use `XDG_STATE_HOME`.

`setup.conf` is **no longer sourced**. It was an undocumented shell-execution risk; use the CLI
options above instead. Existing files are reported and ignored.

## Safety and limitations

- Dry-run is read-only across every mode, including `--dry-run --uninstall` in either order.
- Downloads are HTTPS-only with redirects restricted to HTTPS, retries, timeouts, and SHA-256
  verification from the official GitHub release API. Checksums are never silently ignored.
- Existing Spicetify CLI installations are never reinstalled automatically.
- Permissions are targeted: user-owned trees get `u+rwX`; system-wide trees get a consented
  `setfacl` ACL on the app root and `Apps`, with a default ACL for recreated `Apps`. There is no
  world-writable mode and no recursive chown. System-wide installs get read/traverse
  normalization (`a+rX`, never write) so other users can still use Spotify.
- Uninstall requires a successful restore first and removes only validated directories with
  evidence (`config-xpui.ini`, `Backup`/`Extracted`, or a `spicetify` binary) and only the marked
  PATH block. Symlinked or untrusted paths are preserved with manual instructions.
- Marketplace is installed only after valid paths and a successful apply, with consent, from the
  verified Marketplace release zip. If it is skipped or fails, the script says so.
- Missing dependencies are reported with explicit install commands; the script does not run
  broad automatic package installations or install Flatpak for native setups.
- No GUI/desktop proof is claimed for Flatpak or native flows. Native support is tested against
  the layouts above, not every distro or Spotify build.

## Testing

Tests use Python 3 stdlib `unittest`, isolated temporary `HOME`/XDG trees, and fake external
commands. They do not install packages, touch real Spotify, or make network requests.

```bash
bash -n spicetify-universal.sh
shellcheck spicetify-universal.sh
python3 -m unittest discover -s tests -v
```

## Troubleshooting

- **Prefs file not found**: open Spotify once, log in, close it, and re-run.
- **Multiple installations**: pass `--spotify-type flatpak|native` or `--spotify-path`.
- **Permission errors on a system install**: install `acl` (for `setfacl`) and re-run; the script
  asks before granting a targeted ACL.
- **After an update**: run `--repair`. If it refuses, do not delete the backup; follow its printed
  guidance and update Spicetify first.

Official Spicetify docs: <https://spicetify.app/docs/getting-started>
