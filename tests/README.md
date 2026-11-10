# Tests

Run from the repository root:

```bash
bash -n spicetify-universal.sh
shellcheck spicetify-universal.sh
python3 -m unittest discover -s tests -v
```

The suite uses only the Python standard library, isolated temporary `HOME`/XDG trees, and fake
`curl`, `flatpak`, `spicetify`, `sudo`, `setfacl`, `pgrep`, `pkill`, `uname`, and package-command
boundaries. It never installs packages, touches real Spotify, or makes network requests.
When run as root, strict full-CLI tests use `runuser -u nobody` so ordinary-user behavior and
the root guard are exercised separately.

## Verification

- Final `c61e40d`: root `60 tests PASS`; nonroot `60 tests OK (skipped=1, root-guard test)`.
- `bash -n`, ShellCheck, and `git diff --check`: PASS.
- Real Spotify `1.3.4.258.gc60b10b0946a` + official Spicetify `2.46.4`, user-native:
  setup → patched repair → restore PASS on `6fed868`; final `c61e40d` uninstall PASS
  (removes CLI/config/state/managed PATH; retains prefs and Spotify SPA bytes).
- Final `c61e40d` system-wide root-owned `/usr/share/spotify`: setup + restore actual ACL
  tested by the integration worker. Controller independently re-ran real restore: app
  `getfacl` shows named-user `rwx` + default ACL, `nobody` read/traverse PASS, both restored
  SPA trees byte-identical, no `o+w`.
- Synthetic quoted-prefs case uses no account; no GUI verification is claimed.
- Flatpak and Marketplace coverage is mocked regression only; no real desktop run.
- CI was not remotely run. Test artifacts are removed by the integration worker; the host
  package snapshot remains unchanged (1106 entries).
