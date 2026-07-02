(lang dune 3.16)

(name par_code)

(version "0.2.0-dev")

(generate_opam_files true)

(source (github jcz2020/par-code))

(license Apache-2.0)

(authors "PAR-Code Contributors")
(maintainers "PAR-Code Contributors")

;; par-code is a code agent built on the PAR (Programmable Agent Runtime) SDK.
;; It inherits PAR's CLI conventions (cmdliner, bin/ layout) and exercises the
;; full PAR surface as a real-world validation case for PAR.
(package
 (name par_code)
 (synopsis "Interactive coding agent built on the PAR SDK")
 (description
    "par-code is an interactive coding agent (Claude-Code-style terminal assistant) \
    built on top of PAR (Programmable Agent Runtime). It drives the full PAR SDK \
    surface - ReAct loop, tool dispatch, type-safe bash, MCP client, skills, \
    workflows, streaming - and doubles as a validation case for the PAR project.")
 (tags (agents llm coding par sdk cli))
 (depends
   ocaml
   (dune (>= 3.16))
   ;; PAR is the upstream SDK. As of writing it is not yet on the public opam
   ;; repository; install it from source:
   ;;   opam pin add par https://github.com/jcz2020/par.git
    (par (>= 0.6.5))
   cmdliner
   eio
   eio_main
   yojson
   logs
   alcotest
   odoc))
