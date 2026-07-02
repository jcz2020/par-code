open Cmdliner

let cmd_chat
    provider_opt api_key_opt api_base_opt model_opt
    persistence_opt db_uri_opt temp_opt prompt_opt max_iter_opt
    max_tokens_opt top_p_opt no_parallel_tools retention_days_opt
    continue_id_opt resume_opt =
  let cfg = Par_code_config.require_config () in
  let cfg =
    Par_code_config.merge cfg
      ~provider:provider_opt ~api_key:api_key_opt ~api_base:api_base_opt
      ~model:model_opt ~persistence:persistence_opt ~db_uri:db_uri_opt
      ~temperature:temp_opt ~system_prompt:prompt_opt ~max_iterations:max_iter_opt
      ~max_tokens:max_tokens_opt ~top_p:top_p_opt
      ~parallel_tool_execution:(if no_parallel_tools then Some false else None)
      ~event_retention_days:retention_days_opt
      ()
  in
  let resume_target : Par_code_repl.resume_target =
    match resume_opt, continue_id_opt with
    | true, _ -> Par_code_repl.Resume_most_recent
    | false, Some id -> Par_code_repl.Resume_of id
    | false, None -> Par_code_repl.No_prior
  in
  Par_code_setup.setup_runtime cfg ~f:(fun rt ->
    Par_code_repl.run rt ~resume:resume_target)

let term_chat =
  let open Term in
  const cmd_chat
  $ Cli_args.provider_arg $ Cli_args.api_key_arg $ Cli_args.api_base $ Cli_args.model_name
  $ Cli_args.persistence_arg $ Cli_args.db_uri $ Cli_args.temperature_arg
  $ Cli_args.system_prompt_arg $ Cli_args.max_iterations
  $ Cli_args.max_tokens_arg $ Cli_args.top_p_arg $ Cli_args.no_parallel_tools
  $ Cli_args.retention_days $ Cli_args.continue_id_opt $ Cli_args.resume_opt

let cmd_ask
    question_tokens
    provider_opt api_key_opt api_base_opt model_opt
    persistence_opt db_uri_opt temp_opt prompt_opt max_iter_opt
    max_tokens_opt top_p_opt no_parallel_tools retention_days_opt =
  let question = String.concat " " question_tokens in
  let cfg = Par_code_config.require_config () in
  let cfg =
    Par_code_config.merge cfg
      ~provider:provider_opt ~api_key:api_key_opt ~api_base:api_base_opt
      ~model:model_opt ~persistence:persistence_opt ~db_uri:db_uri_opt
      ~temperature:temp_opt ~system_prompt:prompt_opt ~max_iterations:max_iter_opt
      ~max_tokens:max_tokens_opt ~top_p:top_p_opt
      ~parallel_tool_execution:(if no_parallel_tools then Some false else None)
      ~event_retention_days:retention_days_opt
      ()
  in
  if question = "" then begin
    Printf.eprintf "Usage: par-code ask <question>\n%!";
    exit 1
  end;
  Par_code_setup.setup_runtime cfg ~f:(fun rt ->
    Par_code_repl.run_single_shot rt ~message:question)

let term_ask =
  let open Term in
  const cmd_ask
  $ Cli_args.question_arg
  $ Cli_args.provider_arg $ Cli_args.api_key_arg $ Cli_args.api_base $ Cli_args.model_name
  $ Cli_args.persistence_arg $ Cli_args.db_uri $ Cli_args.temperature_arg
  $ Cli_args.system_prompt_arg $ Cli_args.max_iterations
  $ Cli_args.max_tokens_arg $ Cli_args.top_p_arg $ Cli_args.no_parallel_tools
  $ Cli_args.retention_days

let info_ask = Cmd.info "ask" ~doc:"Ask a single question and print the answer"

let cmd_config () = Par_code_config.run_wizard ()

let term_config =
  let open Term in
  const (fun () -> cmd_config ()) $ const ()

let info_config = Cmd.info "config" ~doc:"Configure provider and model settings"

let cmd =
  Cmd.group ~default:term_chat
    (Cmd.info "par-code" ~version:Par_code.version_info
       ~doc:"Interactive coding agent built on the PAR SDK — run 'par-code' to start the REPL, 'par-code config' to configure, 'par-code ask \"question\"' for one-shot")
    [ Cmd.v info_config term_config;
      Cmd.v info_ask term_ask; ]

let () =
  if not (Unix.isatty Unix.stdout) then Unix.putenv "TERM" "dumb";
  exit (Cmd.eval cmd)
