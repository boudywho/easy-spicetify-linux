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
