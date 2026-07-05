# linux-bundle.Dockerfile — build par-code on AlmaLinux 8.
#
# Produces a portable Linux x86_64 tarball:
#   par-v<VERSION>-linux-x64.tar.gz
#     par                — the binary (RPATH=$ORIGIN)
#     libsqlite3.so.0    — bundled sqlite3 (sqlite3-ocaml linkage)
#     libgmp.so.10       — bundled gmp (mirage-crypto-rng linkage)
#
# Why AlmaLinux 8 (not CentOS 7 + devtoolset-11)?
#   Original plan targeted CentOS 7 for the glibc 2.17 baseline (covers
#   virtually all Linux distros). But CentOS 7 hit EOL June 2024, the
#   mirror.centos.org / mirrorlist.centos.org DNS is dead, and the
#   SCL (devtoolset-11) package path is unreliable on the vault archive.
#   Five release.yml iterations failed to make the EOL detour work.
#   Decision: switch to AlmaLinux 8 (glibc 2.28, gcc 8.5 stock — meets
#   OCaml 5.x's C11 atomics requirement without needing SCL).
#   Cost: lose coverage for CentOS 7 / Debian 10 / Ubuntu 18.04 (all EOL).
#   See docs/DECISIONS.md "[2026-07-03] Linux bundle base: AlmaLinux 8".
#
# Usage:
#   docker build --build-arg VERSION=v0.2.1 \
#     -f scripts/docker/linux-bundle.Dockerfile \
#     --output type=local,dest=artifacts/ .
#
# Or in CI: docker cp the /tmp/par-v*.tar.gz* out of the container.

# ---------------------------------------------------------------------------
# Stage 1: full build environment
# ---------------------------------------------------------------------------
FROM almalinux:8 AS builder

# All deps in one layer. AlmaLinux 8's stock gcc 8.5 already supports
# C11 atomics (>= gcc 4.9) so no SCL/devtoolset dance is required.
# - `dnf config-manager --set-enabled powertools`: libsqlite3-devel lives in PowerTools.
# - `epel-release`: required for patchelf and bubblewrap (not in base RHEL 8 repos).
RUN dnf config-manager --set-enabled powertools || true && \
    dnf install -y epel-release && \
    dnf install -y \
      gcc gcc-c++ make patch m4 perl git curl tar gzip unzip bzip2 diffutils \
      sqlite-devel gmp-devel \
      patchelf bubblewrap \
    && dnf clean all

# opam binary (pinned to 2.1.5 stable).
RUN curl -fsSL https://github.com/ocaml/opam/releases/download/2.1.5/opam-2.1.5-x86_64-linux \
      -o /usr/local/bin/opam && \
    chmod +x /usr/local/bin/opam

# OCaml switch. --disable-sandboxing: bubblewrap + Docker is unreliable.
# opam 2.1.5 rejects 'switch create NAME VER --packages=X' (can't mix
# positional version + --packages); use --packages with ocaml.VER instead.
RUN opam init --disable-sandboxing -y --bare --no-setup && \
    opam switch create default --packages=ocaml-variants,ocaml.5.4.0 -y && \
    eval $(opam env --switch=default)

# Pin the PAR SDK (not yet on the public opam repository).
RUN eval $(opam env --switch=default) && \
    opam pin add par https://github.com/jcz2020/par.git -y

# Copy par-code source into the build context.
COPY . /src/par-code
WORKDIR /src/par-code

# Install par-code deps and build.
RUN eval $(opam env --switch=default) && \
    opam install . --deps-only --with-test -y && \
    dune build

# ---------------------------------------------------------------------------
# Stage 2: bundle binary + shared libs, patch RPATH, package tarball.
# ---------------------------------------------------------------------------
ARG VERSION=dev

RUN mkdir -p /out && \
    cp _build/default/bin/main.exe /out/par && \
    cp /usr/lib64/libsqlite3.so.0 /out/ && \
    cp /usr/lib64/libgmp.so.10 /out/ && \
    chmod +x /out/par

RUN patchelf --set-rpath '$ORIGIN' /out/par

RUN readelf -d /out/par | grep -E 'RUNPATH|RPATH' | grep -q '\$ORIGIN' || \
    { echo "ERROR: RPATH patch failed"; exit 1; }

RUN ldd /out/par | grep -E 'libsqlite3|libgmp' && \
    echo "Shared library resolution looks correct."

# Package: strip leading 'v' from VERSION (CI passes 'v0.2.1', filenames
# want 'par-v0.2.1' not 'par-vv0.2.1').
RUN VER="${VERSION#v}" && \
    cd /out && \
    tar czf "/tmp/par-v${VER}-linux-x64.tar.gz" par libsqlite3.so.0 libgmp.so.10 && \
    sha256sum "/tmp/par-v${VER}-linux-x64.tar.gz" | awk '{print $1}' \
      > "/tmp/par-v${VER}-linux-x64.tar.gz.sha256"
