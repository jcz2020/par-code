#!/usr/bin/env bash
#
# build-macos.sh — build par-code for darwin-arm64 and bundle dylibs.
#
# Run on a `macos-15` GitHub Actions runner (Apple Silicon). Produces
# `par-v<ver>-darwin-arm64.zip` containing:
#   par-darwin-arm64-<ver>/
#     par                       ← the binary
#     libsqlite3.0.dylib        ← bundled (par links sqlite3-ocaml)
#     libgmp.10.dylib           ← bundled (par links mirage-crypto-rng → libgmp)
#
# macOS dylib bundling pattern:
#   - Binary gets -add_rpath @loader_path  → @rpath contains the binary's dir.
#   - Each dylib gets -id @rpath/<name>     → its install name.
#   - Binary's link refs get -change <abspath> @rpath/<name> → look up via @rpath.
# This is exactly what delocate / macdylibbundler do.
#
# Assumptions:
#   - Invoked from the par-code repo root (cwd = repo root).
#   - opam + an OCaml switch are already installed on the runner.
#   - libsqlite3.0.dylib + libgmp.10.dylib are present on the host
#     (runner images ship them; locally, `brew install sqlite gmp`).
#
# v0.2.1 does NOT codesign or notarize the CLI. curl|bash install never
# passes through Gatekeeper; Safari-downloaded users get the quarantine
# xattr cleared by install.sh post-extract. See README callout (Wave 4).
#
# Usage: scripts/build-macos.sh [version-override]
#   version-override: e.g. v0.2.1 (CI passes the tag explicitly).
#                     If omitted, version is read from dune-project.

set -euo pipefail
set -x  # echo every command for CI debugging

# --- helpers -----------------------------------------------------------------

info()    { printf '\033[1m[info]\033[0m %s\n' "$*" >&2; }
warn()    { printf '\033[33m[warn]\033[0m %s\n' "$*" >&2; }
error()   { printf '\033[31m[error]\033[0m %s\n' "$*" >&2; }
success() { printf '\033[32m[success]\033[0m %s\n' "$*" >&2; }
die()     { error "$*"; exit 1; }

# --- sqlite3 amalgamation build ----------------------------------------------
build_sqlite3_amalgamation() {
    local ver_file="scripts/sqlite-amalgamation.version"
    local sqlite_ver
    if [ -f "$ver_file" ]; then
        sqlite_ver=$(grep -vE '^\s*(#|$)' "$ver_file" | head -1 | tr -d '[:space:]')
    fi
    sqlite_ver="${sqlite_ver:-3460000}"
    info "sqlite3 amalgamation version: $sqlite_ver"

    # sqlite download URLs use the release year (e.g. 2024 for 3.46.x).
    local year=2024

    local out_dir="/tmp/sqlite3-amalgamation"
    rm -rf "$out_dir"
    mkdir -p "$out_dir"

    local zip_name="sqlite-amalgamation-${sqlite_ver}.zip"
    local url="https://www.sqlite.org/${year}/${zip_name}"
    info "downloading $url ..."
    curl -fsSL "$url" -o "$out_dir/$zip_name"

    info "extracting amalgamation ..."
    unzip -q "$out_dir/$zip_name" -d "$out_dir"

    local src_dir="$out_dir/sqlite-amalgamation-${sqlite_ver}"
    [ -f "$src_dir/sqlite3.c" ] || die "sqlite3.c not found in amalgamation zip"

    info "compiling sqlite3 amalgamation → libsqlite3.0.dylib (arm64, FTS5+JSON1) ..."
    clang -O2 -fPIC -dynamiclib \
        -arch arm64 \
        -install_name @rpath/libsqlite3.0.dylib \
        -DSQLITE_ENABLE_FTS5 \
        -DSQLITE_ENABLE_JSON1 \
        -DSQLITE_THREADSAFE=1 \
        -DSQLITE_DEFAULT_MEMSTATUS=0 \
        -I"$src_dir" \
        "$src_dir/sqlite3.c" \
        -o "$out_dir/libsqlite3.0.dylib" \
        -lpthread -ldl

    [ -f "$out_dir/libsqlite3.0.dylib" ] || die "failed to build libsqlite3.0.dylib"
    info "sqlite3 amalgamation dylib built: $out_dir/libsqlite3.0.dylib"
    printf '%s\n' "$out_dir/libsqlite3.0.dylib"
}

# --- version -----------------------------------------------------------------

if [ $# -ge 1 ]; then
    VER="$1"
else
    VER=$(grep -oE '\(version "[^"]+"\)' dune-project \
          | head -1 \
          | sed -E 's/\(version "([^"]+)"\)/\1/')
fi
# Strip leading 'v' — CI passes 'v0.2.1' but filenames want 'par-v0.2.1' not 'par-vv0.2.1'.
VER="${VER#v}"
[ -n "$VER" ] || die "could not determine version (pass it as \$1 or set dune-project (version ...))"
info "version: $VER"

# macOS tooling sanity (fail fast — these only exist on Darwin).
command -v install_name_tool >/dev/null || die "install_name_tool not found (not macOS?)"
command -v otool              >/dev/null || die "otool not found (not macOS?)"
command -v zip                >/dev/null || die "zip not found"

# Bundle C dylib (libgmp). macos-15 GitHub runners do NOT ship it by
# default — install via brew if missing. Idempotent: skip if present.
# (libsqlite3 is built from amalgamation source — see build_sqlite3_amalgamation.)
install_dylib() {
    local pkg="$1" name_no_ver="$2" name_with_ver="$3"
    if find_dylib "$name_with_ver" 2>/dev/null | head -1 | grep -q . \
       || find_dylib "$name_no_ver" 2>/dev/null | head -1 | grep -q .; then
        info "$pkg dylib already present"
    else
        info "installing $pkg via brew ..."
        brew install "$pkg" || die "brew install $pkg failed"
    fi
}
install_dylib gmp    libgmp.dylib    libgmp.10.dylib

# --- build -------------------------------------------------------------------

info "setting up opam environment ..."
eval "$(opam env)"

# Pin PAR SDK (idempotent — `opam list` check avoids re-pin churn in CI).
if ! opam list --columns=name 2>/dev/null | grep -qx par; then
    info "pinning PAR SDK ..."
    opam pin add par https://github.com/jcz2020/par.git -y
fi

# Deps (idempotent; --with-test is harmless when no test deps are missing).
info "installing deps ..."
opam install . --deps-only --with-test -y || true

info "building ..."
dune build

BIN=_build/default/bin/main.exe
[ -f "$BIN" ] || die "built binary not found at $BIN"

# --- locate dylibs -----------------------------------------------------------
# libsqlite3 is built from amalgamation (build_sqlite3_amalgamation above).
# libgmp is looked up from Homebrew via find_dylib.
find_dylib() {
    local name="$1"
    for p in \
        "/opt/homebrew/lib/$name" \
        "/usr/local/lib/$name"; do
        [ -f "$p" ] && { printf '%s\n' "$p"; return 0; }
    done
    # `|| true` defeats pipefail: `head -1` closes find's stdin, find exits
    # 141 (SIGPIPE), pipefail propagates the failure, set -e kills the script
    # before the caller's fallback lookup runs.
    find /usr/lib /usr/local/lib /opt/homebrew/lib /Library/Apple/usr/lib -name "$name" 2>/dev/null | head -1 || true
}

SQLITE_DYLIB=$(build_sqlite3_amalgamation)
GMP_DYLIB=$(find_dylib libgmp.10.dylib)
[ -n "$GMP_DYLIB" ] || GMP_DYLIB=$(find_dylib libgmp.dylib)
[ -n "$GMP_DYLIB" ] || die "libgmp*.dylib not found on the build host — install gmp via 'brew install gmp'"
info "sqlite3 dylib: $SQLITE_DYLIB"
info "gmp dylib:     $GMP_DYLIB"

# --- stage -------------------------------------------------------------------

PKG_DIR="par-darwin-arm64-$VER"
STAGING="/tmp/$PKG_DIR"
info "staging into $STAGING ..."
rm -rf "$STAGING"
mkdir -p "$STAGING"

cp "$BIN" "$STAGING/par"
cp "$SQLITE_DYLIB" "$STAGING/libsqlite3.0.dylib"
cp "$GMP_DYLIB"    "$STAGING/libgmp.10.dylib"
chmod +x "$STAGING/par"

cd "$STAGING"

# --- patch rpath on binary ---------------------------------------------------
# Idempotent: delete first (ignore failure if absent), then add.
info "patching @loader_path rpath on par ..."
install_name_tool -delete_rpath @loader_path par 2>/dev/null || true
install_name_tool -add_rpath    @loader_path par

# --- patch dylib install names ----------------------------------------------
# So the loader (resolving @rpath) can find them by their @rpath/<name> id.
info "patching dylib install names ..."
install_name_tool -id @rpath/libsqlite3.0.dylib libsqlite3.0.dylib
install_name_tool -id @rpath/libgmp.10.dylib     libgmp.10.dylib

# --- patch binary's dylib references ----------------------------------------
# otool -L lists the binary's link refs as absolute paths; rewrite each
# to @rpath/<name> so the loader resolves via @rpath (which contains
# @loader_path, i.e. the dir next to `par`).
info "patching binary dylib references ..."
patch_ref() {
    local lib_basename="$1"
    local current
    current=$(otool -L par | grep -E "/[^ ]*$lib_basename" | awk '{print $1}' | head -1 || true)
    if [ -z "$current" ]; then
        warn "no link ref for $lib_basename in par (already @rpath?)"
        return 0
    fi
    if [ "$current" = "@rpath/$lib_basename" ]; then
        info "  $lib_basename already @rpath-relative — skipping"
        return 0
    fi
    info "  $current → @rpath/$lib_basename"
    install_name_tool -change "$current" "@rpath/$lib_basename" par
}
patch_ref libsqlite3.0.dylib
patch_ref libgmp.10.dylib

# par may link Apple's system /usr/lib/libsqlite3.dylib (no version suffix)
# instead of Homebrew's libsqlite3.0.dylib. Rewrite it to @rpath so the
# bundled libsqlite3.0.dylib is used at runtime.
install_name_tool -change /usr/lib/libsqlite3.dylib @rpath/libsqlite3.0.dylib par 2>/dev/null || true

# --- verify ------------------------------------------------------------------

info "otool -L par (post-patch):"
otool -L par | head -20 >&2

otool -L par | grep -q '@rpath/libsqlite3.0.dylib' \
    || die "par binary does not reference @rpath/libsqlite3.0.dylib"
otool -L par | grep -q '@rpath/libgmp.10.dylib' \
    || die "par binary does not reference @rpath/libgmp.10.dylib"
otool -l par | grep -A 2 LC_RPATH | grep -q '@loader_path' \
    || die "par binary missing @loader_path rpath entry"

# Note on xattr: we do NOT clear com.apple.quarantine here. End-users who
# download the zip via curl|bash never get the quarantine bit set (it only
# applies to Safari/Downloads-folder files). install.sh handles the
# Safari path with `xattr -d com.apple.quarantine` post-extract.

# --- package -----------------------------------------------------------------

ZIP_NAME="par-v$VER-darwin-arm64.zip"
info "packaging $ZIP_NAME ..."
rm -f "/tmp/$ZIP_NAME"
cd /tmp
zip -r "$ZIP_NAME" "$PKG_DIR" >/dev/null

# Place artifacts back in the repo root (release.yml gh-action picks them up).
# ORIGINAL_CWD is the CI contract: release.yml exports it = $GITHUB_WORKSPACE.
# Local devs running this by hand won't set it, so we fall back to /tmp
# (loudly) rather than dying — they can find the zip there.
if [ -n "${ORIGINAL_CWD:-}" ] && [ -d "$ORIGINAL_CWD" ]; then
    mv -f "$ZIP_NAME" "$ORIGINAL_CWD/"
    ZIP_PATH="$ORIGINAL_CWD/$ZIP_NAME"
else
    warn "ORIGINAL_CWD unset/invalid; leaving $ZIP_NAME in /tmp"
    warn "release.yml must export ORIGINAL_CWD=\$GITHUB_WORKSPACE"
    ZIP_PATH="/tmp/$ZIP_NAME"
fi

# --- checksum ----------------------------------------------------------------

info "generating sha256 ..."
shasum -a 256 "$ZIP_PATH" | awk '{print $1}' > "$ZIP_PATH.sha256"

# --- summary -----------------------------------------------------------------

printf '\n' >&2
success "Built: $ZIP_NAME ($(du -h "$ZIP_PATH" | cut -f1))"
info   "sha256: $(cat "$ZIP_PATH.sha256")"
info   "contents:"
( cd "$(dirname "$ZIP_PATH")" && unzip -l "$ZIP_NAME" ) >&2
