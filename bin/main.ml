let run () =
  print_endline Cli_args.version_info;
  print_endline "Skeleton build — interactive coding agent (REPL) lands in v0.2.0.";
  print_endline ("Built against PAR SDK " ^ Par.Version.version)

let term =
  let open Cmdliner.Term in
  const run $ const ()

let cmd =
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "par-code" ~version:Cli_args.version_info
       ~doc:"Interactive coding agent built on the PAR SDK (skeleton)")
    term

let () = exit (Cmdliner.Cmd.eval cmd)
