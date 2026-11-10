#!/usr/bin/env bash
#
# Spicetify Universal Setup Script
# Version 3.1.0
# Flatpak + experimental native Spotify support for Linux.
# Official docs: https://spicetify.app/docs/getting-started
#

set -eEuo pipefail

readonly SCRIPT_VERSION="3.1.0"
readonly SPOTIFY_FLATPAK_ID="com.spotify.Client"
readonly OFFICIAL_DOCS_URL="https://spicetify.app/docs/getting-started"
readonly CLI_RELEASES_API="https://api.github.com/repos/spicetify/cli/releases/latest"
readonly MARKETPLACE_RELEASES_API="https://api.github.com/repos/spicetify/marketplace/releases/latest"
readonly PATH_START="# >>> spicetify-universal >>>"
readonly PATH_END="# <<< spicetify-universal <<<"

DEBUG="${DEBUG:-0}"
DRY_RUN="${DRY_RUN:-0}"
VERBOSE="${VERBOSE:-0}"

CONFIG_FILE="${CONFIG_FILE:-${XDG_CONFIG_HOME:-${HOME:-}/.config}/spicetify-setup/setup.conf}"
SPICETIFY_CONFIG_DIR="${SPICETIFY_CONFIG:-${XDG_CONFIG_HOME:-${HOME:-}/.config}/spicetify}"
SPICETIFY_STATE_DIR="${XDG_STATE_HOME:-${HOME:-}/.local/state}/spicetify"
SPICETIFY_INSTALL_DIR="${HOME:-}/.spicetify"

INSTALL_URL="${SPICETIFY_INSTALL_URL:-}"
INSTALLER_SHA256="${SPICETIFY_INSTALLER_SHA256:-}"

MODE="setup"
SHOW_HELP=0
SHOW_VERSION=0
SPOTIFY_TYPE_OPT="auto"
SPOTIFY_PATH_OPT=""
PREFS_PATH_OPT=""
INSTALL_MARKETPLACE=1
ASSUME_YES=0

SPOTIFY_TYPE=""
SPOTIFY_SCOPE=""
SPOTIFY_APP_FILES_PATH=""
SPOTIFY_PREFS_PATH=""
SPICETIFY_BIN=""
SELECTED_INDEX=0
CLI_VERSION=""
CLI_ARCHIVE_URL=""
CLI_ARCHIVE_SHA256=""

declare -a _TMP_FILES=()
_TMP_DIR=""
declare -a CAND_TYPE=() CAND_SCOPE=() CAND_PATH=() CAND_PREFS=()
declare -a SAFE_TARGETS=() SAFE_LABELS=()

_VALIDATED_PATH=""
_VALIDATED_PREFS=""

_cleanup_tmp() {
    local f
    for f in "${_TMP_FILES[@]:-}"; do
        if [[ -n "${f}" ]]; then
            rm -rf -- "${f}" 2>/dev/null || true
        fi
    done
    _TMP_FILES=()
    _TMP_DIR=""
}

_on_signal() {
    trap - EXIT
    _cleanup_tmp
    exit "$1"
}

trap '_cleanup_tmp' EXIT
trap '_on_signal 130' INT
trap '_on_signal 143' TERM

_ensure_tmp() {
    [[ -n "${_TMP_DIR}" ]] && return 0
    local old
    old=$(umask)
    umask 077
    _TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/spicetify-universal.XXXXXX") || { umask "${old}"; return 1; }
    umask "${old}"
    _TMP_FILES+=("${_TMP_DIR}")
}

_color_on() {
    [[ -n "${NO_COLOR:-}" ]] && return 1
    [[ -t 1 ]] || return 1
    case "${TERM:-}" in dumb|unknown|''|native) return 1 ;; esac
}

_color() { _color_on || return 0; printf '%s' "$1"; }
C_RESET="$(_color $'\x1b[0m')"
C_RED="$(_color $'\x1b[0;31m')"
C_GREEN="$(_color $'\x1b[0;32m')"
C_YELLOW="$(_color $'\x1b[0;33m')"
C_BLUE="$(_color $'\x1b[0;34m')"
C_CYAN="$(_color $'\x1b[0;36m')"
C_PINK="$(_color $'\x1b[38;5;199m')"
C_BOLD="$(_color $'\x1b[1m')"
C_DIM="$(_color $'\x1b[2m')"

title() { printf '\n%s%s%s%s\n%s%s───────────────────────────────────────────────────%s\n' "${C_PINK}" "${C_BOLD}" "$1" "${C_RESET}" "${C_BLUE}" "${C_DIM}" "${C_RESET}"; }
header() { printf '\n%s%s==> %s%s\n' "${C_BLUE}" "${C_BOLD}" "$1" "${C_RESET}"; }
running() { printf '  %s↪ %s%s\n' "${C_CYAN}" "$1" "${C_RESET}"; }
detail() { printf '    %s› %s%s\n' "${C_DIM}" "$1" "${C_RESET}"; }
info() { printf '  %sⓘ %s%s\n' "${C_CYAN}" "$1" "${C_RESET}"; }
ok() { printf '  %s✓ %s%s\n' "${C_GREEN}" "$1" "${C_RESET}"; }
warn() { printf '  %s⚠ %s%s\n' "${C_YELLOW}" "$1" "${C_RESET}"; }
err() { printf '  %s%s✗ ERROR: %s%s\n' "${C_RED}" "${C_BOLD}" "$1" "${C_RESET}" >&2; }
die() { err "$*"; exit 1; }
debug() {
    if [[ "${DEBUG}" == "1" ]]; then
        printf '  %s[DEBUG]%s %s\n' "${C_DIM}" "${C_RESET}" "$1" >&2
    fi
}

verbose() {
    if [[ "${VERBOSE}" == "1" ]]; then
        detail "$1"
    fi
}

command_exists() { command -v "$1" >/dev/null 2>&1; }
is_root() { [[ "${EUID:-$(id -u)}" -eq 0 ]]; }
interactive() { [[ -t 0 && -t 1 && -r /dev/tty ]]; }

confirm() {
    local prompt="${1:-Are you sure?}" default="${2:-N}" answer=""
    [[ "${ASSUME_YES}" == "1" ]] && return 0
    interactive || return 1
    while true; do
        printf '  %s? %s [%s]: %s' "${C_YELLOW}" "${prompt}" "${default}" "${C_RESET}"
        read -r answer < /dev/tty || return 1
        answer="${answer:-${default}}"
        case "${answer,,}" in
            y|yes) return 0 ;;
            n|no) return 1 ;;
            *) printf '  %sPlease answer y or n.%s\n' "${C_RED}" "${C_RESET}" ;;
        esac
    done
}

_validate_runtime() {
    [[ -n "${ZSH_VERSION:-}" ]] && die "Run this script with Bash, not zsh: bash spicetify-universal.sh"
    [[ -n "${FISH_VERSION:-}" ]] && die "Run this script with Bash, not fish: bash spicetify-universal.sh"
    if [[ -z "${BASH_VERSINFO:-}" ]] || (( BASH_VERSINFO[0] < 4 )); then
        die "Bash 4 or newer is required (found: ${BASH_VERSION:-unknown})."
    fi
    [[ -n "${HOME:-}" && "${HOME}" == /* ]] || die "HOME must be set to an absolute path."
    if [[ -n "${SPICETIFY_STATE:-}" ]]; then
        die "SPICETIFY_STATE is not supported. Spicetify v2.46.4 treats that override differently (no /Backup suffix), so recovery would be unsafe. Unset SPICETIFY_STATE and use XDG_STATE_HOME instead."
    fi
    if [[ -f "${CONFIG_FILE}" ]]; then
        warn "setup.conf is no longer read (shell-free CLI options replace it): ${CONFIG_FILE}"
    fi
}

_require_consent() {
    [[ "${ASSUME_YES}" == "1" ]] && return 0
    interactive && return 0
    die "Refusing to make changes non-interactively without --yes. Re-run with --yes, or use --dry-run."
}

detect_distro() {
    if [[ -f /etc/os-release ]]; then
        local id
        id=$(grep -m1 '^ID=' /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"' | tr '[:upper:]' '[:lower:]') || id=""
        printf '%s' "${id:-unknown}"
    else
        printf 'unknown'
    fi
}

detect_pkg_manager() {
    local combined=""
    if [[ -f /etc/os-release ]]; then
        combined=$(grep -m1 '^ID=' /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')
        combined+=" $(grep -m1 '^ID_LIKE=' /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')"
        case "${combined}" in
            *arch*|*manjaro*|*endeavour*|*garuda*|*cachyos*) printf 'pacman'; return ;;
            *debian*|*ubuntu*|*mint*|*pop*|*zorin*|*elementary*|*kali*) printf 'apt'; return ;;
            *fedora*|*rhel*|*centos*|*rocky*|*alma*) if command_exists dnf; then printf 'dnf'; else printf 'yum'; fi; return ;;
            *suse*|*gecko*) printf 'zypper'; return ;;
            *alpine*) printf 'apk'; return ;;
        esac
    fi
    command_exists pacman && { printf 'pacman'; return; }
    command_exists apt-get && { printf 'apt'; return; }
    command_exists dnf && { printf 'dnf'; return; }
    command_exists zypper && { printf 'zypper'; return; }
    command_exists apk && { printf 'apk'; return; }
    printf 'unknown'
}

_install_hint() {
    local mgr
    mgr=$(detect_pkg_manager)
    case "${mgr}" in
        pacman) printf '  sudo pacman -S --needed -- %s\n' "$*" ;;
        apt)    printf '  sudo apt-get install -y -- %s\n' "$*" ;;
        dnf)    printf '  sudo dnf install -y -- %s\n' "$*" ;;
        yum)    printf '  sudo yum install -y -- %s\n' "$*" ;;
        zypper) printf '  sudo zypper --non-interactive install -- %s\n' "$*" ;;
        apk)    printf '  sudo apk add -- %s\n' "$*" ;;
        *)      printf '  Install with your package manager: %s\n' "$*" ;;
    esac
}

ensure_deps() {
    local cmd
    local -a missing=()
    for cmd in "$@"; do command_exists "${cmd}" || missing+=("${cmd}"); done
    if (( ${#missing[@]} == 0 )); then
        return 0
    fi
    if [[ "${DRY_RUN}" == "1" ]]; then
        info "[DRY-RUN] Missing dependencies: ${missing[*]}"
        _install_hint "${missing[@]}"
        return 0
    fi
    err "Missing required commands: ${missing[*]}"
    _install_hint "${missing[@]}"
    exit 1
}

_sha256_file() {
    if command_exists sha256sum; then
        sha256sum -- "$1" | awk '{print $1}'
    elif command_exists shasum; then
        shasum -a 256 -- "$1" | awk '{print $1}'
    else
        return 1
    fi
}

_run_sudo() {
    [[ "${DRY_RUN}" == "1" ]] && { info "[DRY-RUN] Would run: sudo $*"; return 0; }
    command_exists sudo || die "sudo is required for this privileged step."
    sudo "$@"
}

_curl_https() {
    curl --proto '=https' --proto-redir '=https' --tlsv1.2 -fsSL \
        --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 300 "$@"
}

_github_json() {
    _curl_https -H 'Accept: application/vnd.github+json' -H 'User-Agent: easy-spicetify-linux' --url "$1"
}

_download() {
    local url="$1" dest="$2" expected="${3:-}" actual=""
    [[ "${url}" == https://* ]] || { err "Refusing a non-HTTPS URL: ${url}"; return 1; }
    debug "Downloading ${url}"
    _curl_https --output "${dest}" --url "${url}" || { err "Download failed: ${url}"; return 1; }
    if [[ -n "${expected}" ]]; then
        actual=$(_sha256_file "${dest}") || { err "Could not compute SHA-256."; rm -f -- "${dest}"; return 1; }
        if [[ "${actual,,}" != "${expected,,}" ]]; then
            err "SHA-256 mismatch for ${url}"
            detail "Expected: ${expected}"
            detail "Got:      ${actual}"
            rm -f -- "${dest}"
            return 1
        fi
        ok "SHA-256 verified."
    fi
}

_json_tag() {
    local out
    out=$(tr -d '\n\r' | grep -oE '"tag_name"[[:space:]]*:[[:space:]]*"[^"]+"' | head -n1 | sed -E 's/.*"([^"]+)"$/\1/' || true)
    printf '%s' "${out}"
}

_json_digest() {
    local asset="$1" flat out
    flat=$(tr -d '\n\r')
    out=$(printf '%s' "${flat}" \
        | grep -oE "\"name\"[[:space:]]*:[[:space:]]*\"${asset}\".*" \
        | grep -oE '"digest"[[:space:]]*:[[:space:]]*"sha256:[0-9a-fA-F]+"' \
        | head -n1 | grep -oE '[0-9a-fA-F]{64}' | tr 'A-F' 'a-f' || true)
    printf '%s' "${out}"
}

_arch() {
    case "$(uname -m)" in
        x86_64|amd64) printf 'amd64' ;;
        aarch64|arm64)
            err "Official Spicetify release binaries are currently Linux amd64 only."
            detail "No linux-arm64 asset exists, so this script will not fabricate a URL."
            detail "Install Spicetify from your package manager (for example AUR) or build it from source."
            return 1 ;;
        *)
            err "Unsupported architecture for official Spicetify release binaries: $(uname -m)"
            return 1 ;;
    esac
}

_resolve_release() {
    local arch json tag asset
    arch=$(_arch) || return 1
    json=$(_github_json "${CLI_RELEASES_API}") || { err "Could not query the Spicetify release API."; return 1; }
    tag=$(_json_tag <<<"${json}")
    [[ -n "${tag}" ]] || { err "Could not determine the latest Spicetify release."; return 1; }
    tag="${tag#v}"
    asset="spicetify-${tag}-linux-${arch}.tar.gz"
    CLI_VERSION="${tag}"
    CLI_ARCHIVE_URL="https://github.com/spicetify/cli/releases/download/v${tag}/${asset}"
    if [[ -n "${INSTALLER_SHA256}" ]]; then
        CLI_ARCHIVE_SHA256="${INSTALLER_SHA256}"
    else
        CLI_ARCHIVE_SHA256=$(_json_digest "${asset}" <<<"${json}")
        [[ -n "${CLI_ARCHIVE_SHA256}" ]] || { err "No official SHA-256 digest was published for ${asset}."; return 1; }
    fi
}

_find_spicetify() {
    if [[ -x "${SPICETIFY_INSTALL_DIR}/spicetify" ]]; then
        SPICETIFY_BIN="${SPICETIFY_INSTALL_DIR}/spicetify"; return 0
    fi
    if command_exists spicetify; then
        SPICETIFY_BIN=$(command -v spicetify); return 0
    fi
    return 1
}

_spicetify() {
    _find_spicetify || { err "Spicetify CLI not found."; return 127; }
    "${SPICETIFY_BIN}" "$@"
}

_require_cli() { _find_spicetify || die "Spicetify CLI is not installed. Run setup first."; }

_export_path() {
    case ":${PATH}:" in *":${SPICETIFY_INSTALL_DIR}:"*) ;; *) export PATH="${SPICETIFY_INSTALL_DIR}:${PATH}" ;; esac
}

_install_archive() {
    local archive="$1" extract="$2"
    mkdir -p -- "${extract}" "${SPICETIFY_INSTALL_DIR}" || { err "Could not create Spicetify directories."; return 1; }
    tar -xzf "${archive}" -C "${extract}" --no-same-owner || { err "Could not extract the Spicetify archive."; return 1; }
    [[ -f "${extract}/spicetify" ]] || { err "Archive did not contain a spicetify binary."; return 1; }
    cp -a -- "${extract}/." "${SPICETIFY_INSTALL_DIR}/" || { err "Could not install Spicetify files."; return 1; }
    chmod 755 -- "${SPICETIFY_INSTALL_DIR}/spicetify" || { err "Could not make spicetify executable."; return 1; }
}

_install_custom() {
    local dest="" extract="" runner=()
    _ensure_tmp || { err "Could not create a private temporary directory."; return 1; }
    dest="${_TMP_DIR}/custom-download"
    extract="${_TMP_DIR}/extract"
    [[ -n "${INSTALLER_SHA256}" ]] || warn "No SPICETIFY_INSTALLER_SHA256 supplied; the custom download will not be checksum-verified."
    running "Downloading custom Spicetify source..."
    _download "${INSTALL_URL}" "${dest}" "${INSTALLER_SHA256}" || return 1
    case "${INSTALL_URL}" in
        *.tar.gz|*.tgz)
            _install_archive "${dest}" "${extract}" || return 1 ;;
        *)
            warn "Custom URL is not a release archive; running the legacy installer in an isolated temporary directory."
            command_exists setsid && runner+=(setsid)
            command_exists timeout && runner=(timeout 600 "${runner[@]}")
            if (( ${#runner[@]} > 0 )); then
                (cd "${_TMP_DIR}" && "${runner[@]}" bash "${dest}" </dev/null) || { err "Custom installer failed."; return 1; }
            else
                (cd "${_TMP_DIR}" && bash "${dest}" </dev/null) || { err "Custom installer failed."; return 1; }
            fi ;;
    esac
}

install_cli() {
    header "Installing Spicetify CLI"
    _export_path
    if _find_spicetify; then
        if [[ "${DRY_RUN}" == "1" ]]; then
            info "[DRY-RUN] Spicetify CLI already installed at ${SPICETIFY_BIN}; would not reinstall."
        else
            info "Spicetify CLI already installed: $("${SPICETIFY_BIN}" --version 2>/dev/null || printf 'unknown')"
        fi
        info "Not reinstalling automatically. Update it with: spicetify upgrade"
        return 0
    fi
    if [[ "${DRY_RUN}" == "1" ]]; then
        if [[ -n "${INSTALL_URL}" ]]; then
            info "[DRY-RUN] Would download custom source: ${INSTALL_URL}"
        else
            info "[DRY-RUN] Would resolve the latest official Spicetify release and install it to ${SPICETIFY_INSTALL_DIR}."
        fi
        info "[DRY-RUN] Would verify the official SHA-256 digest before installing."
        return 0
    fi
    ensure_deps curl tar
    command_exists sha256sum || command_exists shasum || die "A SHA-256 tool is required (install coreutils)."
    if [[ -n "${INSTALL_URL}" ]]; then
        _install_custom || die "Spicetify CLI installation failed."
    else
        _ensure_tmp || die "Could not create a private temporary directory."
        _resolve_release || die "Could not resolve the official Spicetify release."
        running "Downloading Spicetify CLI v${CLI_VERSION} (linux-amd64)..."
        _download "${CLI_ARCHIVE_URL}" "${_TMP_DIR}/spicetify.tar.gz" "${CLI_ARCHIVE_SHA256}" || die "Spicetify CLI download failed."
        _install_archive "${_TMP_DIR}/spicetify.tar.gz" "${_TMP_DIR}/extract" || die "Spicetify CLI installation failed."
    fi
    _export_path
    _find_spicetify || die "Spicetify command not found after installation."
    "${SPICETIFY_BIN}" --version >/dev/null 2>&1 || die "Installed Spicetify binary could not run."
    ok "Spicetify CLI installed: $("${SPICETIFY_BIN}" --version 2>/dev/null || printf 'unknown')"
}

_canonical() {
    if command_exists realpath; then realpath -m -- "$1"; else readlink -f -- "$1"; fi
}

_unsupported_path() {
    case "$1" in /snap|/snap/*|/nix/store|/nix/store/*) return 0 ;; esac
    return 1
}

_broad_path() {
    case "$1" in /|/usr|/usr/share|/usr/lib|/opt|/var|/var/lib|/etc|/home|/tmp|/nix|/nix/store|/snap) return 0 ;; esac
    [[ -n "${HOME:-}" && ( "$1" == "${HOME}" || "${HOME}" == "$1/"* ) ]] && return 0
    return 1
}

_scope() {
    if [[ -n "${HOME:-}" && ( "$1" == "${HOME}" || "$1" == "${HOME}/"* ) ]]; then printf 'user'; else printf 'system'; fi
}

_prefs_for() {
    case "$1" in
        flatpak) printf '%s' "${HOME}/.var/app/${SPOTIFY_FLATPAK_ID}/config/spotify/prefs" ;;
        native)  printf '%s' "${XDG_CONFIG_HOME:-${HOME}/.config}/spotify/prefs" ;;
        *) return 1 ;;
    esac
}

_infer_type() {
    case "$1" in
        "${HOME}/.var/app/${SPOTIFY_FLATPAK_ID}/"*|*"/flatpak/app/${SPOTIFY_FLATPAK_ID}/"*) printf 'flatpak' ;;
        *) printf 'native' ;;
    esac
}

_validate_app_links() {
    local resolved="$1" link target
    command_exists find || return 0
    while IFS= read -r -d '' link; do
        target=$(_canonical "${link}") || { err "Could not resolve symlink inside Apps: ${link}"; return 1; }
        if [[ "${target}" != "${resolved}/Apps" && "${target}" != "${resolved}/Apps/"* ]]; then
            err "Refusing a symlink inside Apps that escapes the installation: ${link} -> ${target}"
            return 1
        fi
    done < <(find "${resolved}/Apps" -type l -print0)
}

_validate_app() {
    local raw="$1" resolved="" entry="" found=0
    local -a entries=()
    _VALIDATED_PATH=""
    [[ -n "${raw}" ]] || { err "Spotify path is empty."; return 1; }
    resolved=$(_canonical "${raw}") || { err "Could not resolve Spotify path: ${raw}"; return 1; }
    if _unsupported_path "${raw}" || _unsupported_path "${resolved}"; then
        err "Snap and Nix store Spotify installations are unsupported and must not be modified."
        detail "Install Spotify from apt, AUR, spotify-launcher, or Flatpak instead."
        return 1
    fi
    _broad_path "${resolved}" && { err "Refusing a broad/system path: ${resolved}"; return 1; }
    [[ -d "${resolved}" ]] || { err "Spotify app directory not found: ${resolved}"; detail "Install Spotify and open it once."; return 1; }
    [[ -d "${resolved}/Apps" ]] || { err "Not a Spotify app directory (missing Apps): ${resolved}"; return 1; }
    [[ -L "${resolved}/Apps" ]] && { err "Refusing a Spotify installation with a symlinked Apps folder: ${resolved}/Apps"; return 1; }
    _validate_app_links "${resolved}" || return 1
    shopt -s nullglob dotglob
    entries=("${resolved}/Apps/"*)
    shopt -u nullglob dotglob
    (( ${#entries[@]} > 0 )) || { err "Spotify Apps folder is empty: ${resolved}/Apps"; detail "Open Spotify once, then re-run."; return 1; }
    [[ -f "${resolved}/Apps/xpui.spa" || -f "${resolved}/Apps/xpui/index.html" ]] && found=1
    (( found == 1 )) || { err "Apps folder does not look like Spotify (expected xpui.spa or patched xpui/index.html): ${resolved}/Apps"; return 1; }
    _VALIDATED_PATH="${resolved}"
}

_validate_prefs() {
    local raw="$1" resolved=""
    _VALIDATED_PREFS=""
    [[ -n "${raw}" ]] || { err "Spotify prefs path is empty."; return 1; }
    resolved=$(_canonical "${raw}") || { err "Could not resolve prefs path: ${raw}"; return 1; }
    if _unsupported_path "${raw}" || _unsupported_path "${resolved}"; then err "Refusing Snap/Nix prefs path: ${resolved}"; return 1; fi
    _broad_path "${resolved}" && { err "Refusing broad/system prefs path: ${resolved}"; return 1; }
    [[ -f "${resolved}" ]] || { err "Spotify prefs file not found: ${resolved}"; detail "Open Spotify once, log in, close it, and re-run."; return 1; }
    _VALIDATED_PREFS="${resolved}"
}

_reset_candidates() { CAND_TYPE=(); CAND_SCOPE=(); CAND_PATH=(); CAND_PREFS=(); }

_add_candidate() {
    local existing
    for existing in "${CAND_PATH[@]:-}"; do [[ "${existing}" == "$3" ]] && return 0; done
    CAND_TYPE+=("$1"); CAND_SCOPE+=("$2"); CAND_PATH+=("$3"); CAND_PREFS+=("$4")
}

_flatpak_app_path() {
    if [[ -d "$1/files/extra/share/spotify" ]]; then printf '%s' "$1/files/extra/share/spotify"; return 0; fi
    if [[ -d "$1/files/share/spotify" ]]; then printf '%s' "$1/files/share/spotify"; return 0; fi
    return 1
}

_discover_flatpak_known() {
    local base location app prefs
    prefs=$(_prefs_for flatpak)
    for base in "${HOME}/.local/share/flatpak/app/${SPOTIFY_FLATPAK_ID}" "/var/lib/flatpak/app/${SPOTIFY_FLATPAK_ID}"; do
        [[ -d "${base}" ]] || continue
        shopt -s nullglob
        for location in "${base}"/*/*/active; do
            [[ -d "${location}" ]] || continue
            app=$(_flatpak_app_path "${location}") || continue
            _validate_app "${app}" || continue
            _add_candidate flatpak "$(_scope "${_VALIDATED_PATH}")" "${_VALIDATED_PATH}" "${prefs}"
        done
        shopt -u nullglob
    done
}

_discover_flatpak() {
    local location app prefs
    prefs=$(_prefs_for flatpak)
    if ! command_exists flatpak; then
        [[ "${SPOTIFY_TYPE_OPT}" == "flatpak" ]] && { err "Flatpak is not installed."; detail "Install Flatpak and Spotify from Flathub, open Spotify once, then re-run."; return 1; }
        return 0
    fi
    if [[ "${DRY_RUN}" == "1" ]]; then
        info "[DRY-RUN] Would query flatpak info --user/--system for ${SPOTIFY_FLATPAK_ID}."
        _discover_flatpak_known
        return 0
    fi
    location=$(flatpak info --user --show-location "${SPOTIFY_FLATPAK_ID}" 2>/dev/null) || location=""
    if [[ -n "${location}" && -d "${location}" ]]; then
        app=$(_flatpak_app_path "${location}") || app=""
        [[ -n "${app}" ]] && _validate_app "${app}" && _add_candidate flatpak user "${_VALIDATED_PATH}" "${prefs}"
    fi
    location=$(flatpak info --system --show-location "${SPOTIFY_FLATPAK_ID}" 2>/dev/null) || location=""
    if [[ -n "${location}" && -d "${location}" ]]; then
        app=$(_flatpak_app_path "${location}") || app=""
        [[ -n "${app}" ]] && _validate_app "${app}" && _add_candidate flatpak system "${_VALIDATED_PATH}" "${prefs}"
    fi
    _discover_flatpak_known
}

_discover_native() {
    local path prefs
    prefs=$(_prefs_for native)
    for path in "/usr/share/spotify" "/opt/spotify" "${XDG_DATA_HOME:-${HOME}/.local/share}/spotify-launcher/install/usr/share/spotify"; do
        [[ -e "${path}" ]] || continue
        if _validate_app "${path}"; then
            _add_candidate native "$(_scope "${_VALIDATED_PATH}")" "${_VALIDATED_PATH}" "${prefs}"
        else
            warn "Skipping unusable Spotify candidate: ${path}"
        fi
    done
}

_select_candidate() {
    local count=${#CAND_PATH[@]} choice i
    (( count == 1 )) && { SELECTED_INDEX=0; return 0; }
    err "Multiple Spotify installations found; refusing to guess which one to patch."
    for ((i = 0; i < count; i++)); do detail "$((i + 1)). ${CAND_TYPE[i]} (${CAND_SCOPE[i]}): ${CAND_PATH[i]}"; done
    if [[ "${ASSUME_YES}" == "1" ]] || ! interactive; then
        detail "Use --spotify-type flatpak|native or --spotify-path ABS to choose explicitly."
        return 1
    fi
    while true; do
        printf '  %s? Select Spotify installation [1-%d]: %s' "${C_YELLOW}" "${count}" "${C_RESET}"
        read -r choice < /dev/tty || return 1
        if [[ "${choice}" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= count )); then
            SELECTED_INDEX=$((choice - 1)); return 0
        fi
    done
}

discover_spotify() {
    local type prefs
    if [[ -n "${SPOTIFY_PATH_OPT}" ]]; then
        _validate_app "${SPOTIFY_PATH_OPT}" || return 1
        SPOTIFY_APP_FILES_PATH="${_VALIDATED_PATH}"
        type="${SPOTIFY_TYPE_OPT}"
        [[ "${type}" == "auto" ]] && type=$(_infer_type "${SPOTIFY_APP_FILES_PATH}")
        if [[ -n "${PREFS_PATH_OPT}" ]]; then
            _validate_prefs "${PREFS_PATH_OPT}" || return 1
        else
            prefs=$(_prefs_for "${type}")
            _validate_prefs "${prefs}" || return 1
        fi
        SPOTIFY_TYPE="${type}"
        SPOTIFY_SCOPE="$(_scope "${SPOTIFY_APP_FILES_PATH}")"
        SPOTIFY_PREFS_PATH="${_VALIDATED_PREFS}"
        export SPOTIFY_APP_FILES_PATH SPOTIFY_PREFS_PATH
        ok "Using Spotify (${SPOTIFY_TYPE}, ${SPOTIFY_SCOPE}): ${SPOTIFY_APP_FILES_PATH}"
        return 0
    fi
    _reset_candidates
    case "${SPOTIFY_TYPE_OPT}" in
        auto) _discover_flatpak || return 1; _discover_native ;;
        flatpak) _discover_flatpak || return 1 ;;
        native) _discover_native ;;
    esac
    (( ${#CAND_PATH[@]} > 0 )) || { err "No usable Spotify installation found."; detail "Install Spotify (Flatpak, apt/AUR, or spotify-launcher), open it once, and re-run."; detail "Docs: ${OFFICIAL_DOCS_URL}"; return 1; }
    _select_candidate || return 1
    SPOTIFY_TYPE="${CAND_TYPE[SELECTED_INDEX]}"
    SPOTIFY_SCOPE="${CAND_SCOPE[SELECTED_INDEX]}"
    SPOTIFY_APP_FILES_PATH="${CAND_PATH[SELECTED_INDEX]}"
    if [[ -n "${PREFS_PATH_OPT}" ]]; then _validate_prefs "${PREFS_PATH_OPT}" || return 1; else _validate_prefs "${CAND_PREFS[SELECTED_INDEX]}" || return 1; fi
    SPOTIFY_PREFS_PATH="${_VALIDATED_PREFS}"
    export SPOTIFY_APP_FILES_PATH SPOTIFY_PREFS_PATH
    ok "Using Spotify (${SPOTIFY_TYPE}, ${SPOTIFY_SCOPE}): ${SPOTIFY_APP_FILES_PATH}"
}

_is_user_owned() { [[ "$(stat -c '%u' -- "$1" 2>/dev/null || printf '')" == "$(id -u)" ]]; }

_ensure_setfacl() {
    command_exists setfacl && return 0
    warn "setfacl is required for a system-wide Spotify installation."
    _install_hint acl
    return 1
}

_ensure_writable() {
    local app="${SPOTIFY_APP_FILES_PATH}" user
    header "Checking Spotify write access"
    [[ -n "${app}" ]] || { err "Spotify path is not set."; return 1; }
    [[ -L "${app}/Apps" ]] && { err "Refusing a symlinked Apps folder: ${app}/Apps"; return 1; }
    if [[ -w "${app}" && -w "${app}/Apps" ]]; then ok "Spotify app directory is writable."; return 0; fi
    if [[ "${DRY_RUN}" == "1" ]]; then
        if _is_user_owned "${app}"; then
            info "[DRY-RUN] Would run targeted user-only permission repair (u+rwX) on ${app}."
        else
            info "[DRY-RUN] Would ask consent, then grant '$(id -un)' a targeted ACL on ${app}."
            info "[DRY-RUN] Would add a default ACL so a recreated Apps folder inherits access."
        fi
        return 0
    fi
    if _is_user_owned "${app}"; then
        running "Granting user-only write access to ${app} and ${app}/Apps..."
        chmod u+rwX -- "${app}" || { err "Could not grant app-root access."; return 1; }
        find "${app}/Apps" -type d -exec chmod u+rwX -- {} + || { err "Could not grant Apps directory access."; return 1; }
        find "${app}/Apps" -type f -exec chmod u+rw -- {} + || { err "Could not grant Apps file access."; return 1; }
        [[ -w "${app}" && -w "${app}/Apps" ]] || { err "Spotify is still not writable: ${app}"; return 1; }
        ok "User write access granted."
        return 0
    fi
    user=$(id -un)
    _ensure_setfacl || return 1
    confirm "Grant '${user}' targeted ACL access to ${app}? Spicetify needs this to patch Spotify." "Y" || { err "Spotify needs write access."; return 1; }
    running "Granting targeted ACL access (app root + Apps; no recursive chmod/chown)..."
    _run_sudo setfacl -m "u:${user}:rwX" -- "${app}" || { err "setfacl failed for ${app}."; return 1; }
    _run_sudo setfacl -R -P -m "u:${user}:rwX" -- "${app}/Apps" || { err "setfacl failed for ${app}/Apps."; return 1; }
    _run_sudo setfacl -m "d:u:${user}:rwX" -- "${app}" || { err "Could not set default ACL on ${app}."; return 1; }
    _run_sudo setfacl -m "d:u:${user}:rwX" -- "${app}/Apps" || { err "Could not set default ACL on ${app}/Apps."; return 1; }
    [[ -w "${app}" && -w "${app}/Apps" ]] || { err "Targeted ACL did not grant write access."; return 1; }
    ok "Targeted ACL access granted."
}

_spotify_running() {
    case "${SPOTIFY_TYPE:-auto}" in
        flatpak) command_exists flatpak && flatpak ps --columns=application 2>/dev/null | grep -Fxq "${SPOTIFY_FLATPAK_ID}" ;;
        native) command_exists pgrep && pgrep -u "$(id -u)" -x spotify >/dev/null 2>&1 ;;
        *)
            if command_exists flatpak && flatpak ps --columns=application 2>/dev/null | grep -Fxq "${SPOTIFY_FLATPAK_ID}"; then return 0; fi
            command_exists pgrep && pgrep -u "$(id -u)" -x spotify >/dev/null 2>&1 ;;
    esac
}

close_spotify() {
    local attempt=0
    [[ "${DRY_RUN}" == "1" ]] && { info "[DRY-RUN] Would close Spotify if it is running."; return 0; }
    if [[ "${SPOTIFY_TYPE:-auto}" == "native" || "${SPOTIFY_TYPE:-auto}" == "auto" ]]; then
        if ! command_exists pgrep; then
            err "pgrep (procps) is required to check whether native Spotify is running."
            _install_hint procps
            die "Install procps or close Spotify manually and use --spotify-type flatpak where applicable."
        fi
    fi
    while _spotify_running; do
        attempt=$((attempt + 1))
        if (( attempt > 5 )); then
            warn "Spotify is still running after ${attempt} attempts."
            if confirm "Spotify is still detected. Have you closed it manually?" "N"; then
                _spotify_running || return 0
                warn "Spotify is still running; refusing to patch while it is open."
            fi
            die "Close Spotify and re-run this script."
        fi
        running "Closing Spotify (attempt ${attempt}/5)..."
        case "${SPOTIFY_TYPE:-auto}" in
            flatpak) command_exists flatpak && { flatpak kill "${SPOTIFY_FLATPAK_ID}" >/dev/null 2>&1 || true; } ;;
            native) command_exists pkill && { pkill -u "$(id -u)" -TERM -x spotify >/dev/null 2>&1 || true; } ;;
            *) command_exists flatpak && { flatpak kill "${SPOTIFY_FLATPAK_ID}" >/dev/null 2>&1 || true; }
               command_exists pkill && { pkill -u "$(id -u)" -TERM -x spotify >/dev/null 2>&1 || true; } ;;
        esac
        sleep 1
    done
    ok "Spotify is not running."
}

_ini_value() {
    [[ -f "$1" ]] || return 0
    awk -v section="[$2]" -v key="$3" '
        /^[[:space:]]*\[/ { in_section = ($0 == section); next }
        in_section && $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
            sub(/^[^=]*=[[:space:]]*/, ""); sub(/[[:space:]]*$/, ""); print; exit
        }
    ' "$1"
}

_prefs_version() {
    [[ -f "$1" ]] || return 0
    awk -F= '$1 == "app.last-launched-version" { sub(/^[^=]*=/, ""); gsub(/^"|"$/, ""); print; exit }' "$1"
}

_spotify_state() {
    local apps="${SPOTIFY_APP_FILES_PATH}/Apps" entry spa=0 dir=0
    local -a entries=()
    [[ -d "${apps}" ]] || { printf 'INVALID'; return; }
    shopt -s nullglob dotglob
    entries=("${apps}/"*)
    shopt -u nullglob dotglob
    for entry in "${entries[@]}"; do
        if [[ -d "${entry}" ]]; then dir=$((dir + 1)); elif [[ -f "${entry}" && "${entry}" == *.spa ]]; then spa=$((spa + 1)); fi
    done
    if (( spa > 0 && dir > 0 )); then printf 'MIXED'
    elif (( spa > 0 )); then printf 'STOCK'
    elif (( dir > 0 )); then printf 'APPLIED'
    else printf 'INVALID'; fi
}

_backup_state() {
    local backup="${SPICETIFY_STATE_DIR}/Backup" entry spa=0 bv sv
    local -a entries=()
    [[ -d "${backup}" ]] || { printf 'EMPTY'; return; }
    shopt -s nullglob dotglob
    entries=("${backup}/"*)
    shopt -u nullglob dotglob
    for entry in "${entries[@]}"; do [[ -f "${entry}" && "${entry}" == *.spa ]] && spa=$((spa + 1)); done
    (( spa > 0 )) || { printf 'EMPTY'; return; }
    bv=$(_ini_value "${SPICETIFY_CONFIG_DIR}/config-xpui.ini" "Backup" "version")
    sv=$(_prefs_version "${SPOTIFY_PREFS_PATH}")
    if [[ -n "${bv}" && -n "${sv}" && "${bv}" == "${sv}" ]]; then printf 'BACKUPED'; else printf 'OUTDATED'; fi
}

_configure_paths() {
    header "Configuring Spicetify paths"
    if [[ "${DRY_RUN}" == "1" ]]; then
        info "[DRY-RUN] Would set spotify_path to: ${SPOTIFY_APP_FILES_PATH}"
        info "[DRY-RUN] Would set prefs_path to: ${SPOTIFY_PREFS_PATH}"
        return 0
    fi
    _require_cli
    export SPICETIFY_CONFIG="${SPICETIFY_CONFIG_DIR}"
    if ! _spicetify config spotify_path "${SPOTIFY_APP_FILES_PATH}"; then
        warn "Could not write Spicetify config; trying to generate it first."
        _spicetify >/dev/null 2>&1 || die "Could not generate Spicetify config."
        _spicetify config spotify_path "${SPOTIFY_APP_FILES_PATH}" || die "Could not set spotify_path."
    fi
    _spicetify config prefs_path "${SPOTIFY_PREFS_PATH}" || die "Could not set prefs_path."
    local got_spotify got_prefs
    got_spotify=$(_spicetify config spotify_path 2>&1) || die "Could not read back spotify_path."
    got_prefs=$(_spicetify config prefs_path 2>&1) || die "Could not read back prefs_path."
    if [[ "${got_spotify}" != "${SPOTIFY_APP_FILES_PATH}" || "${got_prefs}" != "${SPOTIFY_PREFS_PATH}" ]]; then
        die "Spicetify did not persist the selected paths (spotify_path='${got_spotify}', prefs_path='${got_prefs}'). Refusing to patch or restore the wrong installation."
    fi
    ok "Spicetify paths updated and verified; themes/extensions/config preserved."
}

_normalize_system_read() {
    [[ "${SPOTIFY_SCOPE}" == "system" ]] || return 0
    local app="${SPOTIFY_APP_FILES_PATH}" apps="${SPOTIFY_APP_FILES_PATH}/Apps"
    [[ -d "${apps}" && ! -L "${apps}" ]] || return 0
    if [[ "${DRY_RUN}" == "1" ]]; then
        info "[DRY-RUN] Would normalize read/traverse permissions for the system-wide Spotify tree."
        return 0
    fi
    if [[ ! -r "${app}" || ! -x "${app}" ]]; then
        warn "System Spotify app root is not readable/traversable by other users: ${app}"
        detail "Run: sudo chmod a+rX -- \"${app}\" (read/traverse only, no write)."
        return 1
    fi
    if ! _is_user_owned "${apps}"; then
        warn "System Apps folder is not owned by the current user: ${apps}"
        detail "Run: sudo chmod -R a+rX -- \"${apps}\" (read/traverse only, no write)."
        return 1
    fi
    find -P "${apps}" -type d -exec chmod a+rX -- {} + || { err "Could not normalize Apps directory read access."; return 1; }
    find -P "${apps}" -type f -exec chmod a+rX -- {} + || { err "Could not normalize Apps file read access."; return 1; }
    ok "System-wide Spotify read/traverse permissions normalized (no world write)."
}

_run_patch() {
    local -a command=("$@")
    close_spotify || return 1
    if [[ "${DRY_RUN}" == "1" ]]; then info "[DRY-RUN] Would run: spicetify ${command[*]} --no-restart"; return 0; fi
    running "Running: spicetify ${command[*]} --no-restart"
    _spicetify "${command[@]}" --no-restart || { err "spicetify ${command[*]} --no-restart failed."; return 1; }
    _normalize_system_read || return 1
    ok "spicetify ${command[*]} completed."
}

_install_marketplace() {
    local json tag digest url zip extract app
    _ensure_tmp || { err "Could not create a private temporary directory."; return 1; }
    json=$(_github_json "${MARKETPLACE_RELEASES_API}") || { err "Could not query the Marketplace release API."; return 1; }
    tag=$(_json_tag <<<"${json}")
    [[ -n "${tag}" ]] || { err "Could not determine the latest Marketplace release."; return 1; }
    tag="${tag#v}"
    digest=$(_json_digest "marketplace.zip" <<<"${json}")
    [[ -n "${digest}" ]] || { err "No official SHA-256 digest for marketplace.zip."; return 1; }
    url="https://github.com/spicetify/marketplace/releases/download/v${tag}/marketplace.zip"
    zip="${_TMP_DIR}/marketplace.zip"
    extract="${_TMP_DIR}/marketplace-extract"
    running "Downloading Spicetify Marketplace v${tag}..."
    _download "${url}" "${zip}" "${digest}" || return 1
    mkdir -p -- "${extract}" "${SPICETIFY_CONFIG_DIR}/CustomApps" || { err "Could not create Marketplace directories."; return 1; }
    unzip -q -d "${extract}" "${zip}" || { err "Could not extract Marketplace archive."; return 1; }
    app="${extract}/marketplace-dist"
    [[ -d "${app}" ]] || { err "Marketplace archive did not contain marketplace-dist."; return 1; }
    cp -a -- "${app}" "${SPICETIFY_CONFIG_DIR}/CustomApps/marketplace" || { err "Could not copy Marketplace."; return 1; }
    _spicetify config custom_apps marketplace || { err "Could not enable Marketplace."; return 1; }
    _run_patch apply
}

_maybe_marketplace() {
    header "Spicetify Marketplace"
    [[ "${INSTALL_MARKETPLACE}" == "1" ]] || { info "Marketplace skipped (--no-marketplace)."; return 0; }
    [[ -d "${SPICETIFY_CONFIG_DIR}/CustomApps/marketplace" ]] && { ok "Marketplace is already installed."; return 0; }
    if [[ "${DRY_RUN}" == "1" ]]; then info "[DRY-RUN] Would ask consent, then install the verified Marketplace release after applying patches."; return 0; fi
    confirm "Install the Spicetify Marketplace now?" "Y" || { warn "Marketplace skipped. Spicetify is set up without Marketplace."; return 0; }
    ensure_deps unzip
    if ! _install_marketplace; then warn "Marketplace installation failed. Marketplace was NOT installed; Spicetify itself is still set up."; return 0; fi
    ok "Marketplace installed."
}

_preflight() {
    header "Pre-flight checks"
    info "Distro: $(detect_distro)"
    info "Package manager: $(detect_pkg_manager)"
    info "User: $(id -un)"
    info "Login shell: ${SHELL:-unknown}"
    info "Bash: ${BASH_VERSION}"
    info "Spicetify config: ${SPICETIFY_CONFIG_DIR}"
    info "Spicetify state: ${SPICETIFY_STATE_DIR}"
    info "Spicetify CLI: ${SPICETIFY_INSTALL_DIR}"
    if [[ "${VERBOSE}" == "1" ]]; then
        detail "Config file (deprecated, not read): ${CONFIG_FILE}"
        detail "Custom install URL: ${INSTALL_URL:-none}"
        detail "Marketplace install: ${INSTALL_MARKETPLACE}"
    fi
}

_apply_setup() {
    local state
    state=$(_spotify_state)
    info "Spotify Apps state: ${state}"
    case "${state}" in
        STOCK|MIXED) _run_patch backup apply ;;
        APPLIED) info "Spotify is already patched; reapplying without restoring."; _run_patch apply ;;
        *) err "Spotify Apps folder is empty or invalid; cannot apply Spicetify."; detail "Reinstall Spotify, open it once, then run setup again."; return 1 ;;
    esac
}

_run_setup() {
    _preflight
    discover_spotify || die "Spotify discovery failed."
    _ensure_writable || die "Could not make Spotify writable."
    install_cli
    make_path_persistent
    _configure_paths
    _apply_setup || die "Applying Spicetify failed."
    _maybe_marketplace
    if [[ "${DRY_RUN}" == "1" ]]; then printf '\n%s%sDRY-RUN complete: no changes were made.%s\n\n' "${C_YELLOW}" "${C_BOLD}" "${C_RESET}"; return 0; fi
    printf '\n%s%s🎉 SUCCESS! Spotify is now spiced up!%s\n\n' "${C_GREEN}" "${C_BOLD}" "${C_RESET}"
    detail "Restart Spotify to see your changes."
    detail "After a Spotify update, run: ./spicetify-universal.sh --repair"
    detail "Docs: ${OFFICIAL_DOCS_URL}"
}

_repair_guidance() {
    err "Repair failed; no destructive fallback was attempted."
    detail "Official recovery after a Spotify update: spicetify backup apply"
    detail "If Spotify is already patched and the backup matches: spicetify restore backup apply"
    detail "If the CLI is outdated, update Spicetify and retry; a newer release may add compatibility."
    detail "Do not delete the Spicetify backup; it is needed for recovery."
}

_repair_unsupported() {
    err "Refusing to repair automatically (Spotify state: $1, backup: $2)."
    detail "A stale backup must not be restored over a newer Spotify client."
    detail "Update/upgrade Spicetify CLI first; a newer release may support this Spotify version."
    detail "If Spotify is still broken, reinstall Spotify to stock, then run: spicetify backup apply"
    detail "The CLI 'spicetify update' command can reapply patches; run it only after checking the current state."
    detail "Do not delete the Spicetify backup."
}

_run_repair() {
    local state backup
    _preflight
    discover_spotify || die "Spotify discovery failed."
    _ensure_writable || die "Could not make Spotify writable for repair."
    _require_cli
    _configure_paths
    state=$(_spotify_state)
    backup=$(_backup_state)
    info "Spotify Apps state: ${state}"
    info "Backup state: ${backup}"
    case "${state}" in
        STOCK|MIXED)
            if [[ "${DRY_RUN}" == "1" ]]; then _run_patch backup apply; return 0; fi
            _run_patch backup apply || { _repair_guidance; exit 1; } ;;
        APPLIED)
            if [[ "${backup}" != "BACKUPED" ]]; then _repair_unsupported "${state}" "${backup}"; exit 1; fi
            if [[ "${DRY_RUN}" == "1" ]]; then _run_patch restore backup apply; return 0; fi
            _run_patch restore backup apply || { _repair_guidance; exit 1; } ;;
        *) _repair_unsupported "${state}" "${backup}"; exit 1 ;;
    esac
    [[ "${DRY_RUN}" == "1" ]] && { printf '\n%s%sDRY-RUN complete: no changes were made.%s\n\n' "${C_YELLOW}" "${C_BOLD}" "${C_RESET}"; return 0; }
    ok "Repair completed. Settings were preserved; the upstream CLI may refresh its backup as needed."
}

_prepare_restore() {
    discover_spotify || return 1
    _configure_paths
}

_run_restore() {
    _require_cli
    _prepare_restore || die "Could not determine which Spotify installation to restore. Use --spotify-path/--prefs-path if needed."
    _ensure_writable || die "Could not make Spotify writable for restore."
    if [[ "${DRY_RUN}" == "1" ]]; then info "[DRY-RUN] Would run: spicetify restore --no-restart"; return 0; fi
    close_spotify
    _spicetify restore --no-restart || die "spicetify restore failed. No files were removed by this script."
    _normalize_system_read || die "Spotify restored, but system-wide read permissions could not be normalized."
    ok "Spotify restored. CLI, themes, settings and backups were preserved."
}

_consider_target() {
    local path="$1" leaf="$2" kind="$3" resolved=""
    [[ -e "${path}" ]] || return 0
    if [[ -L "${path}" ]]; then warn "Preserving symlinked ${kind} path: ${path}"; detail "Remove it manually if it is genuinely Spicetify-managed."; return 0; fi
    resolved=$(_canonical "${path}") || { warn "Preserving unresolvable ${kind} path: ${path}"; return 0; }
    if _broad_path "${resolved}" || [[ "${resolved}" != "${HOME}/"* || "$(basename -- "${resolved}")" != "${leaf}" ]]; then
        warn "Preserving untrusted ${kind} path (expected a dedicated '${leaf}' directory under HOME): ${resolved}"
        detail "Remove it manually only after verifying it is Spicetify-managed."
        return 0
    fi
    case "${kind}" in
        "Spicetify CLI") [[ -f "${resolved}/spicetify" ]] || { warn "Preserving CLI directory without a spicetify binary: ${resolved}"; return 0; } ;;
        "Spicetify config") [[ -f "${resolved}/config-xpui.ini" ]] || { warn "Preserving config directory without config-xpui.ini: ${resolved}"; return 0; } ;;
        "Spicetify state") [[ -d "${resolved}/Backup" || -d "${resolved}/Extracted" ]] || { warn "Preserving state directory without Backup/Extracted: ${resolved}"; return 0; } ;;
    esac
    local existing
    for existing in "${SAFE_TARGETS[@]:-}"; do [[ "${existing}" == "${resolved}" ]] && return 0; done
    SAFE_TARGETS+=("${resolved}")
    SAFE_LABELS+=("${kind}")
}

_collect_targets() {
    SAFE_TARGETS=(); SAFE_LABELS=()
    _consider_target "${SPICETIFY_INSTALL_DIR}" ".spicetify" "Spicetify CLI"
    _consider_target "${SPICETIFY_CONFIG_DIR}" "spicetify" "Spicetify config"
    _consider_target "${SPICETIFY_STATE_DIR}" "spicetify" "Spicetify state"
}

_remove_targets() {
    local i
    for i in "${!SAFE_TARGETS[@]}"; do
        if [[ "${DRY_RUN}" == "1" ]]; then info "[DRY-RUN] Would remove ${SAFE_LABELS[i]}: ${SAFE_TARGETS[i]}"; continue; fi
        running "Removing ${SAFE_LABELS[i]}: ${SAFE_TARGETS[i]}"
        rm -rf -- "${SAFE_TARGETS[i]}" || { err "Could not remove ${SAFE_LABELS[i]}: ${SAFE_TARGETS[i]}"; return 1; }
        ok "Removed ${SAFE_LABELS[i]}."
    done
}

_remove_path_block() {
    local rc="$1" tmp
    [[ -f "${rc}" ]] || return 0
    [[ -L "${rc}" ]] && { warn "Refusing to edit symlinked shell config: ${rc}"; return 0; }
    case "$(_path_block_state "${rc}")" in
        none) return 0 ;;
        malformed) warn "Skipping malformed spicetify-universal PATH block in ${rc}; preserving the file."; return 0 ;;
    esac
    if [[ "${DRY_RUN}" == "1" ]]; then info "[DRY-RUN] Would remove managed PATH block from ${rc}"; return 0; fi
    tmp=$(mktemp "${rc}.spicetify-universal.XXXXXX") || { err "Could not create temporary file for ${rc}."; return 1; }
    awk -v start="${PATH_START}" -v end="${PATH_END}" '$0 == start { skip=1; next } skip && $0 == end { skip=0; next } !skip { print }' "${rc}" > "${tmp}" || { rm -f -- "${tmp}"; return 1; }
    cat -- "${tmp}" > "${rc}" || { rm -f -- "${tmp}"; return 1; }
    rm -f -- "${tmp}"
    ok "Removed managed PATH block from ${rc}."
}

_remove_path_blocks() {
    local file
    for file in "${HOME}/.bashrc" "${ZDOTDIR:-${HOME}}/.zshrc" "${XDG_CONFIG_HOME:-${HOME}/.config}/fish/config.fish"; do
        _remove_path_block "${file}" || return 1
    done
}

_run_uninstall() {
    _collect_targets
    if [[ "${DRY_RUN}" == "1" ]]; then
        if ! _prepare_restore; then
            warn "An actual uninstall would abort before deleting anything because the Spotify target is unknown."
            printf '\n%s%sDRY-RUN complete: no changes were made.%s\n\n' "${C_YELLOW}" "${C_BOLD}" "${C_RESET}"
            return 0
        fi
        _ensure_writable || { warn "An actual uninstall would abort because Spotify is not writable."; return 0; }
        info "[DRY-RUN] Would run 'spicetify restore --no-restart' first."
        _remove_targets
        _remove_path_blocks
        printf '\n%s%sDRY-RUN complete: no changes were made.%s\n\n' "${C_YELLOW}" "${C_BOLD}" "${C_RESET}"
        return 0
    fi
    if ! _find_spicetify; then
        if [[ -e "${SPICETIFY_INSTALL_DIR}" || -e "${SPICETIFY_CONFIG_DIR}" || -e "${SPICETIFY_STATE_DIR}" ]]; then
            die "Spicetify CLI not found, so a restore cannot be verified. Nothing was removed. Reinstall the CLI or restore Spotify manually, then retry."
        fi
        ok "No Spicetify installation found."
        return 0
    fi
    _prepare_restore || die "Could not determine which Spotify installation to restore. Uninstall aborted; nothing was removed."
    _ensure_writable || die "Could not make Spotify writable for restore. Uninstall aborted; nothing was removed."
    close_spotify
    _spicetify restore --no-restart || die "spicetify restore failed. Uninstall aborted; nothing was removed."
    _normalize_system_read || die "Spotify restored, but system-wide read permissions could not be normalized. Uninstall aborted."
    ok "Spotify restored. Removing only validated Spicetify-managed data."
    _remove_targets || die "Uninstall stopped while removing validated data."
    _remove_path_blocks || die "Uninstall stopped while removing managed PATH blocks."
    ok "Spicetify uninstalled."
}

_shell_name() {
    local shell_path="${SHELL:-}"
    if [[ -z "${shell_path}" ]] && command_exists getent; then
        shell_path=$(getent passwd "$(id -un)" 2>/dev/null | cut -d: -f7) || shell_path=""
    fi
    basename -- "${shell_path:-unknown}"
}

_path_line() {
    if [[ "$1" == "fish" ]]; then
        # shellcheck disable=SC2016
        printf 'fish_add_path "$HOME/.spicetify"'
    else
        # shellcheck disable=SC2016
        printf 'export PATH="$HOME/.spicetify:$PATH"'
    fi
}

_path_block_state() {
    local rc="$1"
    [[ -f "${rc}" ]] || { printf 'none'; return; }
    awk -v s="${PATH_START}" -v e="${PATH_END}" '
        $0 == s { if (open) bad=1; open=1; starts++; next }
        $0 == e { if (!open) bad=1; open=0; ends++; next }
        END {
            if (starts == 0 && ends == 0 && !bad && !open) print "none"
            else if (bad || open || starts != 1 || ends != 1) print "malformed"
            else print "ok"
        }
    ' "${rc}"
}

make_path_persistent() {
    local shell_name rc line state
    header "Making Spicetify available in new terminals"
    shell_name=$(_shell_name)
    case "${shell_name}" in
        bash) rc="${HOME}/.bashrc" ;;
        zsh)  rc="${ZDOTDIR:-${HOME}}/.zshrc" ;;
        fish) rc="${XDG_CONFIG_HOME:-${HOME}/.config}/fish/config.fish" ;;
        *) warn "Unknown login shell: ${shell_name}"; detail "Add this manually: $(_path_line bash)"; return 0 ;;
    esac
    if [[ -L "${rc}" ]]; then
        warn "Refusing to edit symlinked shell config: ${rc}"
        detail "Add this manually to the symlink target: $(_path_line "${shell_name}")"
        return 0
    fi
    state=$(_path_block_state "${rc}")
    case "${state}" in
        ok) ok "PATH already configured in ${rc}."; return 0 ;;
        malformed) warn "Refusing to edit ${rc}: malformed spicetify-universal PATH block. Preserving the file."; return 0 ;;
    esac
    confirm "Add Spicetify to PATH permanently in ${rc}?" "Y" || { warn "Skipped PATH persistence. Add it manually later."; return 0; }
    line=$(_path_line "${shell_name}")
    if [[ "${DRY_RUN}" == "1" ]]; then info "[DRY-RUN] Would add the managed PATH block to ${rc}."; return 0; fi
    mkdir -p -- "$(dirname -- "${rc}")" || { err "Could not create shell config directory for ${rc}."; return 1; }
    printf '\n%s\n%s\n%s\n' "${PATH_START}" "${line}" "${PATH_END}" >> "${rc}" || { err "Could not write ${rc}."; return 1; }
    ok "Added Spicetify to PATH in ${rc}. Restart your terminal or source it."
}

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Spicetify Universal Setup v${SCRIPT_VERSION}
Flatpak support + EXPERIMENTAL native Spotify support.

Modes (mutually exclusive):
  -u, --uninstall         Restore Spotify, then remove validated Spicetify data
      --repair, --fix     Conservative recovery after a Spotify update
      --restore           Run 'spicetify restore --no-restart' only

Options:
  -h, --help              Show this help
  -d, --debug             set -x
  -n, --dry-run           Preview only; create nothing and call no mutating tool
  -y, --yes               Explicit consent for noninteractive runs
      --spotify-type T    auto | flatpak | native (default: auto)
      --spotify-path ABS  Explicit Spotify app directory (contains Apps/)
      --prefs-path ABS    Explicit Spotify prefs file
      --no-marketplace    Do not install the Spicetify Marketplace
  -v, --version           Show version
  -V, --verbose           Verbose output

Native Spotify support is EXPERIMENTAL. Supported layouts:
  /usr/share/spotify (Debian/Ubuntu), /opt/spotify (Arch/AUR),
  \$XDG_DATA_HOME/spotify-launcher/install/usr/share/spotify.
Snap and Nix store installations are unsupported and are never modified.

Environment:
  DEBUG=1, DRY_RUN=1, VERBOSE=1
  SPICETIFY_INSTALL_URL=https://...   Custom HTTPS release archive or legacy installer
  SPICETIFY_INSTALLER_SHA256=...      Integrity check for custom downloads
  CONFIG_FILE=...                     Deprecated; setup.conf is no longer read
  SPICETIFY_CONFIG                    Upstream Spicetify config directory
  XDG_CONFIG_HOME / XDG_STATE_HOME / XDG_DATA_HOME / ZDOTDIR
  SPICETIFY_STATE is rejected: use XDG_STATE_HOME (upstream v2.46.4 quirk).

Examples:
  ./spicetify-universal.sh --dry-run
  ./spicetify-universal.sh --spotify-type native
  ./spicetify-universal.sh --repair
  ./spicetify-universal.sh --restore
  ./spicetify-universal.sh --uninstall --yes

Official docs: ${OFFICIAL_DOCS_URL}
EOF
}

_usage_error() { printf 'ERROR: %s\n\n' "$*" >&2; usage >&2; exit 2; }

_set_mode() {
    [[ "${MODE}" != "setup" && "${MODE}" != "$1" ]] && _usage_error "Conflicting modes: --${MODE} and --$1"
    MODE="$1"
}

parse_args() {
    while (( $# > 0 )); do
        case "$1" in
            -h|--help) SHOW_HELP=1; shift ;;
            -v|--version) SHOW_VERSION=1; shift ;;
            -d|--debug) DEBUG=1; shift ;;
            -n|--dry-run) DRY_RUN=1; shift ;;
            -V|--verbose) VERBOSE=1; shift ;;
            -u|--uninstall) _set_mode uninstall; shift ;;
            --repair|--fix) _set_mode repair; shift ;;
            --restore) _set_mode restore; shift ;;
            -y|--yes) ASSUME_YES=1; shift ;;
            --no-marketplace) INSTALL_MARKETPLACE=0; shift ;;
            --spotify-type) [[ $# -ge 2 ]] || _usage_error "Missing value for --spotify-type"; SPOTIFY_TYPE_OPT="$2"; shift 2 ;;
            --spotify-type=*) SPOTIFY_TYPE_OPT="${1#*=}"; shift ;;
            --spotify-path) [[ $# -ge 2 ]] || _usage_error "Missing value for --spotify-path"; SPOTIFY_PATH_OPT="$2"; shift 2 ;;
            --spotify-path=*) SPOTIFY_PATH_OPT="${1#*=}"; shift ;;
            --prefs-path) [[ $# -ge 2 ]] || _usage_error "Missing value for --prefs-path"; PREFS_PATH_OPT="$2"; shift 2 ;;
            --prefs-path=*) PREFS_PATH_OPT="${1#*=}"; shift ;;
            --) shift; break ;;
            -*) _usage_error "Unknown option: $1" ;;
            *) _usage_error "Unexpected argument: $1" ;;
        esac
    done
    (( $# == 0 )) || _usage_error "Unexpected argument: $1"
    case "${SPOTIFY_TYPE_OPT}" in auto|flatpak|native) ;; *) _usage_error "Invalid Spotify type '${SPOTIFY_TYPE_OPT}'." ;; esac
    [[ -z "${SPOTIFY_PATH_OPT}" || "${SPOTIFY_PATH_OPT}" == /* ]] || _usage_error "Spotify path must be absolute."
    [[ -z "${PREFS_PATH_OPT}" || "${PREFS_PATH_OPT}" == /* ]] || _usage_error "Spotify prefs path must be absolute."
    [[ -z "${INSTALL_URL}" || "${INSTALL_URL}" == https://* ]] || _usage_error "SPICETIFY_INSTALL_URL must use HTTPS."
    [[ -z "${INSTALLER_SHA256}" || "${INSTALLER_SHA256}" =~ ^[0-9a-fA-F]{64}$ ]] || _usage_error "SPICETIFY_INSTALLER_SHA256 must be 64 hex characters."
}

_print_banner() {
    title "🌶️  Spicetify Universal Setup v${SCRIPT_VERSION} 🌶️"
    printf '   Flatpak + EXPERIMENTAL native Spotify support\n'
    printf '   Modes: setup • repair • restore • uninstall\n\n'
    [[ "${DRY_RUN}" == "1" ]] && printf '  %s%s⚠ DRY-RUN mode — no changes will be made%s\n\n' "${C_YELLOW}" "${C_BOLD}" "${C_RESET}"
    [[ "${SPOTIFY_TYPE_OPT}" == "native" ]] && printf '  %s%s⚠ Native Spotify support is EXPERIMENTAL%s\n\n' "${C_YELLOW}" "${C_BOLD}" "${C_RESET}"
    return 0
}

main() {
    parse_args "$@"
    [[ "${SHOW_HELP}" == "1" ]] && { usage; exit 0; }
    [[ "${SHOW_VERSION}" == "1" ]] && { printf 'Spicetify Universal Setup v%s\n' "${SCRIPT_VERSION}"; exit 0; }
    [[ "${DEBUG}" == "1" ]] && set -x
    _validate_runtime
    if [[ "${DRY_RUN}" != "1" ]]; then
        is_root && die "Refusing to run ${MODE} as root. Run as your normal user; root --help, --version and --dry-run are allowed."
        _require_consent
    fi
    _print_banner
    case "${MODE}" in
        setup) _run_setup ;;
        repair) _run_repair ;;
        restore) _run_restore ;;
        uninstall) _run_uninstall ;;
        *) die "Unknown mode: ${MODE}" ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
