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

## Setup

```sh
make dev-deps   # install par + project dependencies
make build      # dune build
make test       # dune runtest
```

## Layout

- `bin/` — the `par` executable and CLI argument definitions.
- `lib/` — the `par_code` library facade (agent-building helpers land here).
- `test/` — Alcotest suite.

## Roadmap alignment

Each change should keep par-code exercising PAR SDK capabilities — this project
doubles as a validation case for PAR, so regressions that surface PAR issues are
welcome and should be reported upstream with a reproducer.
