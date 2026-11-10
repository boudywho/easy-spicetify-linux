# Native support and recovery — implementation plan

## Goal

Deliver the approved design in `docs/superpowers/specs/2026-11-10-native-support-and-recovery-design.md`:
a safer, testable `easy-spicetify-linux` script with experimental native Spotify support,
genuinely safe dry-run, targeted permissions, verified installation, and conservative
repair/restore/uninstall.

## Architecture

Single Bash script with a source-safe main guard; small helpers at every mutating external
boundary. Python stdlib tests drive both sourced unit functions and subprocess CLI flows.
GitHub Actions runs syntax, ShellCheck and tests on Ubuntu 22.04/24.04.

## Tech Stack

Bash >= 4, curl, tar, sha256sum/shasum, unzip (Marketplace only), Python 3 stdlib unittest,
GitHub Actions, ShellCheck.

## Spec

See `docs/superpowers/specs/2026-11-10-native-support-and-recovery-design.md` (CLI contract,
path rules, permission model, installer/network rules, recovery matrix, dry-run guarantees).

## Global Constraints

- No host package installation, no live Spotify process/config changes, no network in tests.
- Tests isolate HOME/XDG/ZDOTDIR and intercept sudo/flatpak/spicetify/curl/package tools.
- Keep Flatpak behavior; label native EXPERIMENTAL.
- No stubs/TODOs, no framework, no new runtime dependency.
- Commit coherent milestones only after the real gates pass.

## Review Focus

Dry-run side effects, wrong-install prevention, permission safety, checksum/failure propagation,
backup protection, uninstall scope, and test evidence.

## Slice 1 — safety, parsing, discovery

- [x] Rewrite argument parser: all args before actions, modes, `--yes`, selectors, duplicate
      conflicts, root help/version/dry-run, bash >= 4 / not zsh/fish. Test: conflicting modes,
      unknown option, help/version as root, duplicate same mode allowed.
- [x] Deprecate `setup.conf` without sourcing it; report and ignore it. Test: injected `$(...)`
      does not execute and the warning is printed. CLI/environment only.
- [x] Fix temp handling (`_TMP_FILES`, signal cleanup), printf arity, nounset guards, XDG/ZDOTDIR
      paths, `SHELL`-based rc selection. Test: cleanup after failure, spaces, XDG paths.
- [x] Implement discovery/validation: Flatpak user/system, Debian/Ubuntu, Arch/AUR,
      spotify-launcher, manual paths, prefs existence, ambiguity, Snap/Nix/symlink rejection,
      no fake dirs. Test each layout, ambiguity noninteractive, missing prefs message.
- [x] Implement `--dry-run` as read-only across all modes; no temp/network/package/spicetify/
      process/rc actions. Test file snapshots and fake-command logs for setup/uninstall ordering.
- [x] Implement targeted permissions: user `u+rwX` only, system `setfacl` ACL with default ACL,
      physical/no-follow, consent, no sudo for discovery. Test no `a+wr`; fake ACL args; dry-run
      preview.
- [x] Implement verified installer: release API + digest, HTTPS/timeouts/retries, amd64-only
      honesty, custom URL/checksum compatibility, legacy script isolation, no auto reinstall.
      Test checksum mismatch/failure, temp cleanup, unsupported arch, legacy failure propagation.

## Slice 2 — setup, repair, restore, uninstall

- [x] Implement setup flow: explicit dependency hints, CLI install, path config/read-back,
      state-aware `backup apply` vs `apply`, process close before patches, no Spotify launch,
      optional verified Marketplace after apply. Test stock/mixed/applied commands and full CLI
      strict runs as an ordinary user.
- [x] Implement `--repair`/`--fix`: state + backup inspection, `backup apply` for stock/mixed,
      `restore backup apply` only for applied + matching backup, explicit failure for outdated/
      empty/invalid, no reinstall/marketplace/download, no wrapper-issued backup deletion or
      `spicetify clear` (upstream may replace after stock/mixed validation). Reject nonempty
      `SPICETIFY_STATE` before any mutating CLI call. Test both post-update states, mixed state,
      failure guidance.
- [x] Implement `--restore`: only `spicetify restore --no-restart`, preserve
      CLI/themes/settings/backup. Test command log and file preservation.
- [x] Implement `--uninstall`: successful `spicetify restore --no-restart` required first; abort
      leaves everything; validate/remove only managed dirs under HOME; remove only marked PATH
      block. Test restore failure, missing CLI with traces, unrelated rc/dir preservation, rc
      symlinks skipped.
- [x] Implement shell PATH block (bash/zsh/fish) idempotently with markers. Test repeated runs and
      uninstall preserving unrelated `.spicetify`-looking lines.

## Slice 3 — documentation, CI, tests

- [x] Add `tests/test_spicetify_universal.py` (stdlib unittest, isolated HOME/PATH, fake
      boundaries) covering all observable outcomes above; ensure deterministic cleanup.
- [x] Add `.github/workflows/ci.yml`: `contents: read`, pinned checkout SHA, Ubuntu 22.04/24.04,
      `bash -n`, ShellCheck, `python3 -m unittest discover -s tests -v`.
- [x] Rewrite README for `easy-spicetify-linux`: identity/links, quickstart Flatpak/native,
      repair-after-update, command/env tables, limitations (experimental native, amd64 official
      binary, no Snap/Nix, no GUI proof), testing commands.
- [x] Bump changelog to 3.1.0 with added/changed/fixed/security sections.
- [x] Run final gates: `bash -n`, ShellCheck, Python tests; inspect diff; commit milestones.

## Progress

- [x] Design/plan docs created.
- [x] Slice 1.
- [x] Slice 2.
- [x] Slice 3.
