# Contributing to par-code

par-code is built on the [PAR SDK](https://github.com/jcz2020/par) and follows
its conventions where they overlap (dune layout, cmdliner CLI structure, typed
errors).

## Prerequisites

- OCaml 5.4+
- dune 3.16+
- The PAR SDK, pinned from source (it is not yet on the public opam repo):

  ```sh
  opam pin add par https://github.com/jcz2020/par.git
  ```

  This will also install par-code's transitive deps: `cohttp-eio`,
  `tls-eio`, `digestif` (used by the self-update module).

## Setup

```sh
make dev-deps   # install par + project dependencies
make build      # dune build
make test       # dune runtest
```

## Layout

- `bin/` — the `par` executable and CLI argument definitions.
- `lib/` — the `par_code` library facade (upgrade logic, config, REPL, setup).
- `scripts/` — installer (`install.sh`), build scripts (`build-macos.sh`,
  `docker/linux-bundle.Dockerfile`), CI helpers (`checksums.sh`).
- `test/` — Alcotest suite.

## Distribution

v0.2.1+ ships pre-built binaries via GitHub Releases. Users install with:

```sh
curl -fsSL https://github.com/jcz2020/par-code/releases/latest/download/install.sh | bash
```

Contributors building from source use the `opam pin` path above. The
`scripts/docker/` and `scripts/build-macos.sh` files are used by CI to
produce release artifacts — not needed for local development.

## Roadmap alignment

Each change should keep par-code exercising PAR SDK capabilities — this project
doubles as a validation case for PAR, so regressions that surface PAR issues are
welcome and should be reported upstream with a reproducer.
