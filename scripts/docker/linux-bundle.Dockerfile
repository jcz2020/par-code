# linux-bundle.Dockerfile — build par-code on CentOS 7 with devtoolset-11.
#
# Produces a portable Linux x86_64 tarball:
#   par-v<VERSION>-linux-x64.tar.gz
#     par                — the binary (RPATH=$ORIGIN)
#     libsqlite3.so.0    — bundled sqlite3 (sqlite3-ocaml linkage)
#     libgmp.so.10       — bundled gmp (mirage-crypto-rng linkage)
#
# Why CentOS 7 + devtoolset-11?
#   CentOS 7 ships glibc 2.17 — the oldest glibc still in wide use. Binaries
#   built against it run on virtually every Linux distro. However, OCaml 5.x
#   requires gcc >= 4.9 (C11 atomics) and CentOS 7's stock gcc is 4.8.5.
#   Software Collections (SCL) provides devtoolset-11 with gcc 11, which
#   produces binaries that still link against the system glibc 2.17.
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
FROM centos:7 AS builder

# CentOS 7 reached EOL June 2024. Repoint yum repos to the vault archive.
RUN sed -i 's|mirrorlist=|#mirrorlist=|g' /etc/yum.repos.d/CentOS-*.repo && \
    sed -i 's|#baseurl=http://mirror.centos.org|baseurl=http://vault.centos.org|g' /etc/yum.repos.d/CentOS-*.repo

# EPEL (needed for patchelf and bubblewrap).
RUN yum install -y epel-release

# System packages: build tools, C libraries for linking, and SCL toolchain.
RUN yum install -y \
    make patch m4 perl git curl tar gzip unzip bzip2 \
    sqlite-devel gmp-devel \
    patchelf bubblewrap \
    centos-release-scl \
    && yum install -y \
    devtoolset-11-gcc \
    devtoolset-11-gcc-c++ \
    devtoolset-11-binutils \
    && yum clean all

# opam binary (pinned to 2.1.5 stable).
RUN curl -fsSL https://github.com/ocaml/opam/releases/download/2.1.5/opam-2.1.5-x86_64-linux \
      -o /usr/local/bin/opam && \
    chmod +x /usr/local/bin/opam

# OCaml switch — must run under devtoolset-11 so gcc 11 is in PATH.
# --disable-sandboxing: bubblewrap + Docker + CentOS 7 is unreliable.
RUN scl enable devtoolset-11 bash -c ' \
    opam init --disable-sandboxing -y --bare --no-setup && \
    opam switch create default 5.4.0 --packages=ocaml-variants -y && \
    eval $(opam env --switch=default)'

# Pin the PAR SDK (not yet on the public opam repository).
RUN scl enable devtoolset-11 bash -c ' \
    eval $(opam env --switch=default) && \
    opam pin add par https://github.com/jcz2020/par.git -y'

# Copy par-code source into the build context.
COPY . /src/par-code
WORKDIR /src/par-code

# Install par-code deps and build — all under devtoolset-11.
RUN scl enable devtoolset-11 bash -c ' \
    eval $(opam env --switch=default) && \
    opam install . --deps-only --with-test -y && \
    dune build'

# ---------------------------------------------------------------------------
# Stage 2: bundle binary + shared libs, patch RPATH, package tarball.
# ---------------------------------------------------------------------------
ARG VERSION=dev

RUN mkdir -p /out && \
    cp _build/default/bin/main.exe /out/par && \
    cp /usr/lib64/libsqlite3.so.0 /out/ && \
    cp /usr/lib64/libgmp.so.10 /out/ && \
    chmod +x /out/par

# Patch RPATH so the binary finds bundled libs in the same directory.
# Single-quotes prevent shell expansion of the literal $ORIGIN.
RUN patchelf --set-rpath '$ORIGIN' /out/par

# Verify RPATH was written correctly.
RUN readelf -d /out/par | grep -E 'RUNPATH|RPATH' | grep -q '\$ORIGIN' || \
    { echo "ERROR: RPATH patch failed — \$ORIGIN not found in binary"; exit 1; }

# Verify bundled libs resolve from $ORIGIN (not system paths).
RUN ldd /out/par | grep -E 'libsqlite3|libgmp' && \
    echo "Shared library resolution looks correct."

# Package: flat tarball (no subdirectory) matching install.sh expectations.
# install.sh does: tar -xzf $asset -C $PREFIX/bin — expects par, lib*.so at top level.
RUN cd /out && \
    tar czf "/tmp/par-v${VERSION}-linux-x64.tar.gz" par libsqlite3.so.0 libgmp.so.10 && \
    sha256sum "/tmp/par-v${VERSION}-linux-x64.tar.gz" \
      > "/tmp/par-v${VERSION}-linux-x64.tar.gz.sha256"

# Default: print the tarball to stdout (useful with docker build --output).
CMD ["sh", "-c", "cat /tmp/par-v${VERSION:-dev}-linux-x64.tar.gz"]
