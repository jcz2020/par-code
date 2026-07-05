#!/bin/sh
# par-code installer — POSIX sh (dash/bash/zsh/ksh compatible, no bashisms)
#
# Functions: detect_platform, resolve_prefix, fetch_latest_tag,
#            download_asset, verify_sha256, install_binary, maybe_update_path
#
# Env: PAR_PREFIX (install dir), PAR_MIRROR (mirror host, default: github.com),
#      PAR_DISABLE_UPDATE_CHECK (skip version fetch)
# Flags: --prefix <path>, --version <ver>, --help
#
# Integrity: HTTPS + GitHub infrastructure + SHA256 = transport-corruption
# detection only. Not adversarial integrity — checksums ship with the binary.

set -u

# Colors (portable: gated on tty)
if [ -t 1 ]; then
    C_R='\033[0;31m'; C_G='\033[0;32m'; C_Y='\033[0;33m'; C_B='\033[1m'; C_0='\033[0m'
else
    C_R=''; C_G=''; C_Y=''; C_B=''; C_0=''
fi
info()    { printf "${C_B}[info]${C_0} %s\n" "$*"; }
warn()    { printf "${C_Y}[warn]${C_0} %s\n" "$*" >&2; }
error()   { printf "${C_R}[error]${C_0} %s\n" "$*" >&2; }
success() { printf "${C_G}[success]${C_0} %s\n" "$*"; }

# Cleanup trap for temp files
TMPDIR_RESOLVED="${TMPDIR:-/tmp}"
PARTIAL_FILE=""
cleanup() { [ -n "$PARTIAL_FILE" ] && [ -f "$PARTIAL_FILE" ] && rm -f "$PARTIAL_FILE"; }
trap cleanup EXIT

# detect_platform: uname -s/-m → linux-x64 | darwin-arm64. Reject others.
PLATFORM=""
detect_platform() {
    _os="$(uname -s | tr '[:upper:]' '[:lower:]')"
    _arch="$(uname -m | tr '[:upper:]' '[:lower:]')"
    case "$_os" in
        linux)
            case "$_arch" in
                x86_64|amd64) PLATFORM="linux-x64" ;;
                *) error "unsupported architecture: $_arch (x86_64 only)"; exit 1 ;;
            esac ;;
        darwin)
            case "$_arch" in
                arm64|aarch64) PLATFORM="darwin-arm64" ;;
                *) error "unsupported architecture: $_arch (arm64 only)"; exit 1 ;;
            esac ;;
        *) error "unsupported OS: $_os (Linux/macOS only)"; exit 1 ;;
    esac
    info "platform: $PLATFORM"
}

# resolve_prefix: --prefix > $PAR_PREFIX > $HOME/.par. Fail if HOME unset.
PREFIX=""
resolve_prefix() {
    [ -n "$PREFIX" ] && return
    if [ "${PAR_PREFIX+_}" = "_" ]; then PREFIX="$PAR_PREFIX"; fi
    if [ -z "$PREFIX" ]; then
        _home=""
        if [ "${HOME+_}" = "_" ] && [ -n "$HOME" ]; then
            _home="$HOME"
        else
            _home="$(getent passwd "$(id -u)" 2>/dev/null | cut -d: -f6)" || true
        fi
        if [ -z "$_home" ]; then
            error "cannot determine home directory; use --prefix or export PAR_PREFIX"
            exit 1
        fi
        PREFIX="$_home/.par"
    fi
    case "$PREFIX" in
        /|/bin|/usr|/usr/bin|/usr/local)
            error "refusing to install to system directory: $PREFIX"; exit 1 ;;
    esac
    info "prefix: $PREFIX"
}

# fetch_latest_tag: query GitHub /releases/latest redirect. Honors PAR_MIRROR.
TAG=""
fetch_latest_tag() {
    [ -n "$TAG" ] && { info "version: $TAG (requested)"; return; }
    if [ "${PAR_DISABLE_UPDATE_CHECK+_}" = "_" ]; then
        error "PAR_DISABLE_UPDATE_CHECK set but no --version specified"; exit 1
    fi
    _mirror="github.com"
    if [ "${PAR_MIRROR+_}" = "_" ] && [ -n "$PAR_MIRROR" ]; then _mirror="$PAR_MIRROR"; fi
    _url="https://$_mirror/jcz2020/par-code/releases/latest"
    info "fetching latest version from $_url ..."
    if command -v curl >/dev/null 2>&1; then
        _tag="$(curl -fsSLI "$_url" 2>/dev/null | grep -i '^location:' | tail -1 | sed 's|.*/||' | tr -d '\r\n')"
    elif command -v wget >/dev/null 2>&1; then
        _tag="$(wget --spider -S "$_url" 2>&1 | grep -i 'Location:' | tail -1 | sed 's|.*/||' | tr -d '\r\n')"
    else
        error "neither curl nor wget found"; exit 1
    fi
    if [ -z "$_tag" ]; then
        error "could not determine latest version; use --version <tag>"; exit 1
    fi
    TAG="$_tag"
    info "latest: $TAG"
}

# download_asset: curl -fL --retry 3 -C - (resume). Write .partial, rename on success.
download_asset() {
    _url="$1"; _dest="$2"
    PARTIAL_FILE="${_dest}.partial"
    info "downloading $_url ..."
    if command -v curl >/dev/null 2>&1; then
        _code="$(curl -fL --retry 3 --retry-delay 2 -C - -w '%{http_code}' -o "$PARTIAL_FILE" "$_url" 2>/dev/null)" || {
            error "download failed"; rm -f "$PARTIAL_FILE"; PARTIAL_FILE=""; exit 1; }
        [ "$_code" = "200" ] || {
            error "HTTP $_code"; rm -f "$PARTIAL_FILE"; PARTIAL_FILE=""; exit 1; }
    elif command -v wget >/dev/null 2>&1; then
        wget -c -q -O "$PARTIAL_FILE" "$_url" 2>/dev/null || {
            error "download failed"; rm -f "$PARTIAL_FILE"; PARTIAL_FILE=""; exit 1; }
    else
        error "neither curl nor wget found"; exit 1
    fi
    [ -s "$PARTIAL_FILE" ] || { error "empty download"; rm -f "$PARTIAL_FILE"; PARTIAL_FILE=""; exit 1; }
    mv "$PARTIAL_FILE" "$_dest"; PARTIAL_FILE=""
    success "downloaded $(basename "$_dest")"
}

# verify_sha256: download checksum, compare via sha256sum/shasum/openssl.
verify_sha256() {
    _asset_url="$1"; _asset_path="$2"
    _ck_url="${_asset_url}.sha256"
    _ck_file="${_asset_path}.sha256"
    _cs_url="$(printf '%s' "$_asset_url" | sed 's|/[^/]*$||')/checksums.txt"
    _cs_file="${_asset_path}.checksums.txt"
    _expected=""
    # Try per-asset .sha256
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL -o "$_ck_file" "$_ck_url" 2>/dev/null && [ -s "$_ck_file" ] && _expected="$(awk '{print $1}' "$_ck_file" | tr -d '\r\n')"
    elif command -v wget >/dev/null 2>&1; then
        wget -q -O "$_ck_file" "$_ck_url" 2>/dev/null && [ -s "$_ck_file" ] && _expected="$(awk '{print $1}' "$_ck_file" | tr -d '\r\n')"
    fi
    # Fallback: checksums.txt
    if [ -z "$_expected" ]; then
        if command -v curl >/dev/null 2>&1; then curl -fsSL -o "$_cs_file" "$_cs_url" 2>/dev/null || true
        elif command -v wget >/dev/null 2>&1; then wget -q -O "$_cs_file" "$_cs_url" 2>/dev/null || true; fi
        [ -s "$_cs_file" ] && _expected="$(grep "$(basename "$_asset_url")" "$_cs_file" 2>/dev/null | head -1 | awk '{print $1}' | tr -d ' \r\n')"
    fi
    rm -f "$_ck_file" "$_cs_file"
    if [ -z "$_expected" ]; then warn "checksum not found; skipping verification"; return 0; fi
    # Compute actual hash (portable: sha256sum → shasum → openssl)
    _actual=""
    if command -v sha256sum >/dev/null 2>&1; then _actual="$(sha256sum "$_asset_path" | awk '{print $1}')"
    elif command -v shasum >/dev/null 2>&1; then _actual="$(shasum -a 256 "$_asset_path" | awk '{print $1}')"
    elif command -v openssl >/dev/null 2>&1; then _actual="$(openssl dgst -sha256 "$_asset_path" | awk '{print $NF}')"
    else warn "no SHA256 tool; skipping"; return 0; fi
    if [ "$_actual" != "$_expected" ]; then
        error "checksum mismatch (expected: $_expected, got: $_actual)"
        rm -f "$_asset_path"; exit 1
    fi
    success "checksum verified"
}

# install_binary: extract tar.gz/zip to $PREFIX/bin/, chmod +x, strip macOS quarantine.
install_binary() {
    _asset="$1"
    mkdir -p "$PREFIX/bin"
    info "installing to $PREFIX/bin/ ..."
    case "$PLATFORM" in
        linux-*)
            tar -xzf "$_asset" -C "$PREFIX/bin" 2>/dev/null || { error "extract failed"; exit 1; } ;;
        darwin-*)
            unzip -oq "$_asset" -d "$PREFIX/bin" 2>/dev/null || { error "extract failed"; exit 1; }
            xattr -d com.apple.quarantine "$PREFIX/bin/par" 2>/dev/null || true
            xattr -d com.apple.quarantine "$PREFIX/bin/"*.dylib 2>/dev/null || true ;;
    esac
    chmod +x "$PREFIX/bin/par" || { error "chmod failed"; exit 1; }
    rm -f "$_asset"
    success "installed $PREFIX/bin/par"
}

# maybe_update_path: add $PREFIX/bin to shell rc via idempotent markers.
# Interactive: prompt y/N. Non-interactive: print instructions only.
maybe_update_path() {
    case ":${PATH}:" in *":${PREFIX}/bin:"*) info "$PREFIX/bin already in PATH"; return 0 ;; esac
    _shell="$(basename "${SHELL:-sh}" 2>/dev/null || printf 'sh')"
    _rc=""
    case "$_shell" in
        bash) _rc="$HOME/.bashrc" ;; zsh) _rc="$HOME/.zshrc" ;; fish) _rc="$HOME/.config/fish/config.fish" ;;
        *) info "add $PREFIX/bin to PATH: export PATH=\"$PREFIX/bin:\$PATH\""; return 0 ;;
    esac
    _rc_dir="$(dirname "$_rc")"
    [ -d "$_rc_dir" ] || mkdir -p "$_rc_dir" 2>/dev/null || {
        warn "cannot create $_rc_dir"; info "export PATH=\"$PREFIX/bin:\$PATH\""; return 0; }
    [ -f "$_rc" ] && grep -q '# >>> par >>>' "$_rc" 2>/dev/null && { info "PATH block in $_rc"; return 0; }
    if [ -t 0 ]; then
        printf "Add %s/bin to PATH in %s? [y/N] " "$PREFIX" "$_rc"
        _ans=""; read -r _ans 2>/dev/null || _ans="n"
        case "$_ans" in y|Y|yes|YES) ;; *) info "skipped. Run: export PATH=\"$PREFIX/bin:\$PATH\""; return 0 ;; esac
    else
        info "non-interactive; add to PATH: export PATH=\"$PREFIX/bin:\$PATH\""
        return 0
    fi
    _line="export PATH=\"\$HOME/.par/bin:\$PATH\""
    if [ "$_shell" = "fish" ]; then
        if command -v fish_add_path >/dev/null 2>&1; then _line="fish_add_path -g \$HOME/.par/bin"
        else _line="set -gx PATH \$HOME/.par/bin \$PATH"; fi
    fi
    printf '\n# >>> par >>>\n%s\n# <<< par <<<\n' "$_line" >> "$_rc" || {
        warn "write failed"; info "export PATH=\"$PREFIX/bin:\$PATH\""; return 0; }
    success "added to PATH in $_rc"
}

show_help() {
    cat <<'EOF'
par-code installer

Usage: install.sh [OPTIONS]

Options:
  --prefix <path>  Install directory (default: $HOME/.par)
  --version <ver>  Pin specific version (e.g. v0.2.1)
  --help           Show this help

Environment:
  PAR_PREFIX                Install directory override
  PAR_MIRROR                Mirror host (default: github.com)
  PAR_DISABLE_UPDATE_CHECK  Skip version fetch (for par upgrade)

Examples:
  curl -fsSL https://github.com/jcz2020/par-code/releases/latest/download/install.sh | sh
  curl -fsSL .../install.sh | sh -s -- --version v0.2.1
  PAR_MIRROR=mirror.example.com curl -fsSL .../install.sh | sh

Integrity: HTTPS + SHA256 = transport corruption check only.
EOF
}

# CLI flags (manual parsing: getopts doesn't support long options)
TAG=""; PREFIX=""
while [ $# -gt 0 ]; do
    case "$1" in
        --prefix)  [ $# -lt 2 ] && { error "--prefix needs <path>"; exit 1; }; PREFIX="$2"; shift 2 ;;
        --version) [ $# -lt 2 ] && { error "--version needs <tag>"; exit 1; }; TAG="$2"; shift 2 ;;
        --help|-h) show_help; exit 0 ;;
        -*) error "unknown: $1 (see --help)"; exit 1 ;;
        *)  error "unexpected: $1 (see --help)"; exit 1 ;;
    esac
done

# Validate version format
if [ -n "$TAG" ]; then
    case "$TAG" in v[0-9]*.[0-9]*.[0-9]*) ;; *) error "bad version: $TAG (expected v<major>.<minor>.<patch>)"; exit 1 ;; esac
fi

info "par-code installer"
detect_platform
resolve_prefix
fetch_latest_tag

_mirror="github.com"
if [ "${PAR_MIRROR+_}" = "_" ] && [ -n "$PAR_MIRROR" ]; then _mirror="$PAR_MIRROR"; fi
_base="https://$_mirror/jcz2020/par-code/releases/download/$TAG"
case "$PLATFORM" in
    linux-*)  _name="par-${TAG}-linux-x64.tar.gz" ;;
    darwin-*) _name="par-${TAG}-darwin-arm64.zip" ;;
esac
_url="${_base}/${_name}"
_path="${TMPDIR_RESOLVED}/${_name}"

download_asset "$_url" "$_path"
verify_sha256 "$_url" "$_path"
install_binary "$_path"
maybe_update_path

printf '\n'
success "par-code $TAG installed!"
info "run: $PREFIX/bin/par --version"
