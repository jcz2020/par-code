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

set -eu

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
SRC_DIR=""
cleanup() {
    [ -n "$PARTIAL_FILE" ] && [ -f "$PARTIAL_FILE" ] && rm -f "$PARTIAL_FILE" || true
    [ -n "$SRC_DIR" ] && [ -d "$SRC_DIR" ] && rm -rf "$SRC_DIR" || true
}
trap cleanup EXIT

# detect_platform: uname -s/-m → linux-x64 | darwin-arm64. Falls through to source compile for others.
PLATFORM=""
detect_platform() {
    _os="$(uname -s | tr '[:upper:]' '[:lower:]')"
    _arch="$(uname -m | tr '[:upper:]' '[:lower:]')"
    PLATFORM=""
    case "$_os" in
        linux)
            case "$_arch" in
                x86_64|amd64) PLATFORM="linux-x64" ;;
                aarch64|arm64) PLATFORM="linux-arm64" ;;
            esac ;;
        darwin)
            case "$_arch" in
                arm64|aarch64) PLATFORM="darwin-arm64" ;;
            esac ;;
    esac
    if [ -n "$PLATFORM" ]; then
        info "platform: $PLATFORM"
    else
        info "platform: $_os-$_arch (no pre-built binary; will compile from source)"
    fi
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
        _tag="$(curl -fsSLI "$_url" 2>/dev/null | grep -i '^location:' | tail -1 | sed 's|.*/||' | tr -d '\r\n' || true)"
    elif command -v wget >/dev/null 2>&1; then
        _tag="$(wget --spider -S "$_url" 2>&1 | grep -i 'Location:' | tail -1 | sed 's|.*/||' | tr -d '\r\n' || true)"
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
        curl -fsSL -o "$_ck_file" "$_ck_url" 2>/dev/null && [ -s "$_ck_file" ] && _expected="$(awk '{print $1}' "$_ck_file" | tr -d '\r\n')" || true
    elif command -v wget >/dev/null 2>&1; then
        wget -q -O "$_ck_file" "$_ck_url" 2>/dev/null && [ -s "$_ck_file" ] && _expected="$(awk '{print $1}' "$_ck_file" | tr -d '\r\n')" || true
    fi
    # Fallback: checksums.txt
    if [ -z "$_expected" ]; then
        if command -v curl >/dev/null 2>&1; then curl -fsSL -o "$_cs_file" "$_cs_url" 2>/dev/null || true
        elif command -v wget >/dev/null 2>&1; then wget -q -O "$_cs_file" "$_cs_url" 2>/dev/null || true; fi
        [ -s "$_cs_file" ] && _expected="$(grep "$(basename "$_asset_url")" "$_cs_file" 2>/dev/null | head -1 | awk '{print $1}' | tr -d ' \r\n')" || true
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
# Detects $SHELL and writes to ~/.bashrc / ~/.zshrc / fish config.
# Non-interactive (curl|bash): auto-adds without prompting.
# Interactive: prompts [Y/n], defaults to yes.
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
    [ -f "$_rc" ] && grep -q '# >>> par >>>' "$_rc" 2>/dev/null && { info "PATH block already in $_rc"; return 0; } || true
    if [ -t 0 ]; then
        printf "Add %s/bin to PATH in %s? [Y/n] " "$PREFIX" "$_rc"
        _ans=""; read -r _ans 2>/dev/null || _ans="y"
        case "$_ans" in n|N|no|NO) info "skipped. Run: export PATH=\"$PREFIX/bin:\$PATH\""; return 0 ;; esac
    fi
    _line="export PATH=\"$PREFIX/bin:\$PATH\""
    if [ "$_shell" = "fish" ]; then
        if command -v fish_add_path >/dev/null 2>&1; then _line="fish_add_path -g $PREFIX/bin"
        else _line="set -gx PATH $PREFIX/bin \$PATH"; fi
    fi
    printf '\n# >>> par >>>\n%s\n# <<< par <<<\n' "$_line" >> "$_rc" || {
        warn "write failed"; info "export PATH=\"$PREFIX/bin:\$PATH\""; return 0; }
    success "added to PATH in $_rc"
    [ -t 0 ] || info "restart your shell or run: source $_rc"
}

install_opam() {
    info "opam not found; installing..."
    case "$_os" in
        darwin)
            if command -v brew >/dev/null 2>&1; then
                info "installing opam via Homebrew..."
                HOMEBREW_NO_AUTO_UPDATE=1 brew install opam || { error "brew install opam failed"; exit 1; }
            else
                error "Homebrew is required for source compilation on macOS."
                error "Install from https://brew.sh then re-run this installer."
                exit 1
            fi ;;
        linux)
            _sudo=""
            if [ "$(id -u)" != "0" ] && ! command -v sudo >/dev/null 2>&1; then
                error "not root and sudo unavailable; cannot install system packages"
                exit 1
            fi
            if [ "$(id -u)" != "0" ] && command -v sudo >/dev/null 2>&1; then
                _sudo="sudo"
            fi
            if command -v apt-get >/dev/null 2>&1; then
                info "installing opam + build dependencies via apt..."
                $_sudo apt-get update -qq || true
                $_sudo apt-get install -y -qq opam build-essential pkg-config libgmp-dev libsqlite3-dev git || {
                    error "apt install failed"; exit 1; }
            elif command -v dnf >/dev/null 2>&1; then
                info "installing opam + build dependencies via dnf..."
                $_sudo dnf install -y opam gcc gcc-c++ make pkgconf-pkg-config gmp-devel sqlite-devel git || {
                    error "dnf install failed"; exit 1; }
            elif command -v pacman >/dev/null 2>&1; then
                info "installing opam + build dependencies via pacman..."
                $_sudo pacman -S --noconfirm opam base-devel pkgconf gmp sqlite git || {
                    error "pacman install failed"; exit 1; }
            elif command -v apk >/dev/null 2>&1; then
                warn "Alpine/musl support is experimental; build may fail"
                info "installing opam + build dependencies via apk..."
                $_sudo apk add --no-cache opam build-base pkgconf gmp-dev sqlite-dev git || {
                    error "apk install failed"; exit 1; }
            else
                error "no supported package manager found."
                error "Install opam manually from https://opam.ml, then re-run."
                exit 1
            fi ;;
        *)
            error "source compilation not supported on $_os"
            exit 1 ;;
    esac
}

ensure_opam() {
    if command -v opam >/dev/null 2>&1; then
        info "opam found: $(opam --version)"
    else
        install_opam
    fi

    if ! opam var root >/dev/null 2>&1; then
        info "initializing opam..."
        opam init --bare --disable-sandboxing -y || { error "opam init failed"; exit 1; }
    fi

    eval "$(opam env)" 2>/dev/null || true
    if command -v ocaml >/dev/null 2>&1; then
        _ocaml_major="$(ocaml -version 2>&1 | sed -n 's/.*version \([0-9][0-9]*\)\..*/\1/p')"
        if [ -n "$_ocaml_major" ] && [ "$_ocaml_major" -ge 5 ] 2>/dev/null; then
            info "using existing OCaml: $(ocaml -version 2>&1 | head -1)"
            return
        fi
    fi

    info "creating OCaml 5.4.1 switch (takes 5-15 minutes)..."
    if opam switch list 2>/dev/null | grep -q 'par-code'; then
        info "switch 'par-code' already exists; reusing"
        opam switch par-code || { error "opam switch par-code failed"; exit 1; }
    else
        opam switch create par-code ocaml-base-compiler.5.4.1 -y --disable-sandboxing || {
            error "opam switch creation failed."
            error "Try: opam switch create par-code ocaml-base-compiler.5.4.1 -y"
            exit 1
        }
    fi
    eval "$(opam env --switch=par-code)" 2>/dev/null || true
    info "OCaml switch ready"
}

ensure_system_libs() {
    info "checking system libraries..."
    case "$_os" in
        darwin)
            if command -v brew >/dev/null 2>&1; then
                for _lib in sqlite gmp pkg-config; do
                    if ! brew list "$_lib" >/dev/null 2>&1; then
                        info "installing $_lib via Homebrew..."
                        HOMEBREW_NO_AUTO_UPDATE=1 brew install "$_lib" || warn "brew install $_lib failed (may already be present)"
                    fi
                done
            fi ;;
        linux)
            if ! command -v pkg-config >/dev/null 2>&1; then
                warn "pkg-config not found; SQLite3 detection may fail"
            fi ;;
    esac
}

install_from_source() {
    info "installing par-code from source..."
    echo ""

    for _tool in git cc make; do
        if ! command -v "$_tool" >/dev/null 2>&1; then
            error "$_tool is required but not found"
            case "$_os" in
                darwin) info "install Xcode Command Line Tools: xcode-select --install" ;;
                *) info "install build tools via your package manager" ;;
            esac
            exit 1
        fi
    done

    ensure_opam
    ensure_system_libs

    _src_dir="${TMPDIR_RESOLVED}/par-code-src"
    SRC_DIR="$_src_dir"
    rm -rf "$_src_dir"
    _clone_url="https://${_mirror}/jcz2020/par-code.git"
    info "cloning par-code..."
    if [ -n "$TAG" ]; then
        git clone --depth 1 --branch "$TAG" "$_clone_url" "$_src_dir" || {
            error "git clone failed (tag $TAG)"; exit 1; }
    else
        git clone --depth 1 "$_clone_url" "$_src_dir" || {
            error "git clone failed"; exit 1; }
    fi

    cd "$_src_dir" || { error "cannot enter source directory"; exit 1; }
    eval "$(opam env)" 2>/dev/null || true

    _par_mirror="${PAR_PAR_MIRROR:-$_mirror}"
    _par_url="https://${_par_mirror}/jcz2020/par.git"
    info "pinning PAR SDK..."
    if opam pin list 2>/dev/null | grep -q '^par '; then
        info "PAR SDK already pinned; skipping"
    else
        _pin_log="${TMPDIR_RESOLVED}/par_opam_pin.log"
        opam pin add par "$_par_url" -y > "$_pin_log" 2>&1 || {
            error "opam pin add par failed (exit $?)"
            tail -10 "$_pin_log" >&2; rm -f "$_pin_log"
            exit 1
        }
        rm -f "$_pin_log"
    fi

    info "installing dependencies (several minutes)..."
    _inst_log="${TMPDIR_RESOLVED}/par_opam_install.log"
    opam install . --deps-only -y > "$_inst_log" 2>&1 || {
        error "opam install --deps-only failed"
        tail -15 "$_inst_log" >&2; rm -f "$_inst_log"
        exit 1
    }
    rm -f "$_inst_log"

    info "building par-code..."
    eval "$(opam env)" 2>/dev/null || true
    _build_log="${TMPDIR_RESOLVED}/par_dune_build.log"
    dune build > "$_build_log" 2>&1 || {
        error "dune build failed"
        tail -20 "$_build_log" >&2; rm -f "$_build_log"
        exit 1
    }
    rm -f "$_build_log"

    info "verifying FTS5 support (system sqlite3 CLI)..."
    if command -v sqlite3 >/dev/null 2>&1; then
        if printf "SELECT fts5_source_id();" | sqlite3 2>/dev/null | grep -q '.'; then
            info "system sqlite3 has FTS5"
        else
            warn "system sqlite3 CLI lacks FTS5; memory search may not work"
            warn "the built binary links a different lib; verify at runtime with: par memory list"
        fi
    else
        warn "sqlite3 CLI not found; skipping FTS5 check"
    fi

    _built="_build/default/bin/main.exe"
    if [ ! -f "$_built" ]; then
        error "built binary not found at $_built"
        exit 1
    fi
    mkdir -p "$PREFIX/bin"
    cp "$_built" "$PREFIX/bin/par"
    chmod +x "$PREFIX/bin/par"

    SRC_DIR=""
    cd - >/dev/null 2>&1 || true
    rm -rf "$_src_dir"

    success "compiled and installed par-code to $PREFIX/bin/par"
    maybe_update_path

    printf '\n'
    if [ -n "$TAG" ]; then
        info "par-code $TAG installed (from source)"
    else
        info "par-code installed from source (latest)"
    fi
    info "run: $PREFIX/bin/par --version"
}

show_help() {
    cat <<'EOF'
par-code installer

Usage: install.sh [OPTIONS]

Options:
  --prefix <path>  Install directory (default: $HOME/.par)
  --version <ver>  Pin specific version (e.g. v0.2.1)
  --from-source    Compile from source instead of downloading pre-built binary
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
TAG=""; PREFIX=""; FROM_SOURCE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --prefix)  [ $# -lt 2 ] && { error "--prefix needs <path>"; exit 1; }; PREFIX="$2"; shift 2 ;;
        --version) [ $# -lt 2 ] && { error "--version needs <tag>"; exit 1; }; TAG="$2"; shift 2 ;;
        --from-source) FROM_SOURCE=1; shift ;;
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

_mirror="github.com"
if [ "${PAR_MIRROR+_}" = "_" ] && [ -n "$PAR_MIRROR" ]; then _mirror="$PAR_MIRROR"; fi

if [ -z "$PLATFORM" ] || [ "$FROM_SOURCE" = "1" ]; then
    install_from_source
    exit 0
fi

fetch_latest_tag

_base="https://$_mirror/jcz2020/par-code/releases/download/$TAG"
case "$PLATFORM" in
    linux-*)  _name="par-${TAG}-${PLATFORM}.tar.gz" ;;
    darwin-*) _name="par-${TAG}-${PLATFORM}.zip" ;;
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
