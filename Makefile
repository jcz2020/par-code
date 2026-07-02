.PHONY: build test clean install dev-deps

# par-code requires the PAR SDK, which is not yet on the public opam repo.
# Install it first:  opam pin add par https://github.com/jcz2020/par.git

build:
	dune build

test:
	dune runtest

clean:
	dune clean

install: build
	dune install

dev-deps:
	opam install par --deps-only --with-test || opam pin add par https://github.com/jcz2020/par.git -y
