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
    Printf.eprintf "Usage: par ask <question>\n%!";
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

let cmd_upgrade check_opt to_opt uninstall_opt purge_opt =
  if purge_opt && not uninstall_opt then begin
    Printf.eprintf "Error: --purge requires --uninstall\n%!";
    exit 2
  end;
  if uninstall_opt then begin
    let dir = Par_code_config.config_dir () in
    if purge_opt then begin
      if Unix.isatty Unix.stdin then begin
        Printf.eprintf "This will delete ALL of %s including config and sessions. Continue? [y/N] " dir;
        match String.lowercase_ascii (String.trim (input_line stdin)) with
        | "y" | "yes" -> ()
        | _ -> Printf.eprintf "Aborted.\n%!"; exit 1
      end else begin
        Printf.eprintf "Error: --purge requires interactive terminal (stdin must be a tty)\n%!";
        exit 2
      end
    end;
    let bin = Filename.concat (Filename.concat dir "bin") "par" in
    let cache = Filename.concat dir ".latest-cache.json" in
    (try Sys.remove bin with _ -> ());
    (try Sys.remove cache with _ -> ());
    if purge_opt then begin
      let rec rm_rf p =
        if Sys.file_exists p then
          if Sys.is_directory p then begin
            Array.iter (fun e -> rm_rf (Filename.concat p e)) (Sys.readdir p);
            Unix.rmdir p
          end else Sys.remove p
      in rm_rf dir
    end;
    Printf.printf "Uninstalled.\n%!"; exit 0
  end;
  if check_opt then begin
    let cur = Par_code_upgrade.current_version () in
    (match Par_code_upgrade.fetch_latest_tag ~timeout:2.0 () with
     | Error `Offline ->
       Printf.printf "current: %s\noffline — could not check latest\n%!" cur;
       exit 1
     | Error (`Http msg) ->
       Printf.eprintf "Error checking latest: %s\n%!" msg;
       exit 1
     | Ok latest ->
       Printf.printf "current: %s\nlatest:  %s\n%!" cur latest;
       exit (if cur = latest then 0 else 1))
  end;
  match Par_code_upgrade.perform_upgrade ?target:to_opt () with
  | Ok new_ver -> Printf.printf "Upgraded to %s\n%!" new_ver
  | Error (`Download_failed msg) -> Printf.eprintf "Upgrade failed (download): %s\n%!" msg; exit 1
  | Error `Checksum_mismatch -> Printf.eprintf "Upgrade failed: checksum mismatch\n%!"; exit 1
  | Error (`Smoke_test_failed msg) -> Printf.eprintf "Upgrade failed (smoke test): %s\n%!" msg; exit 1

let term_upgrade =
  let open Term in
  const cmd_upgrade
  $ Cli_args.upgrade_check_arg $ Cli_args.upgrade_to_arg
  $ Cli_args.upgrade_uninstall_arg $ Cli_args.upgrade_purge_arg

let info_upgrade = Cmd.info "upgrade" ~doc:"Check for and install the latest par version"

let cmd =
  Cmd.group ~default:term_chat
    (Cmd.info "par" ~version:Par_code_version.version_info
       ~doc:"Interactive coding agent built on the PAR SDK — run 'par' to start the REPL, 'par config' to configure, 'par ask \"question\"' for one-shot")
    [ Cmd.v info_config term_config;
      Cmd.v info_ask term_ask;
      Cmd.v info_upgrade term_upgrade; ]

let is_chat_mode () =
  let args = Array.to_list Sys.argv in
  let rec scan = function
    | [] -> true
    | "--help" :: _ | "-h" :: _ -> false
    | "--version" :: _ | "-v" :: _ -> false
    | "config" :: _ | "ask" :: _ | "upgrade" :: _ -> false
    | _ :: rest -> scan rest
  in
  match args with _ :: rest -> scan rest | [] -> true

let maybe_check_version () =
  match Sys.getenv_opt "PAR_NO_UPDATE_CHECK" with
  | Some "1" | Some "true" -> ()
  | _ ->
    if is_chat_mode () then begin
      (try
         let cur = Par_code_upgrade.current_version () in
         (match Par_code_upgrade.fetch_latest_tag ~timeout:2.0 () with
          | Ok latest when latest <> cur ->
            Printf.eprintf "info: par %s is available (current: %s). Run 'par upgrade'.\n%!" latest cur
          | Ok _ | Error _ -> ())
       with _ -> ())
    end

let () =
  if not (Unix.isatty Unix.stdout) then Unix.putenv "TERM" "dumb";
  maybe_check_version ();
  exit (Cmd.eval cmd)
