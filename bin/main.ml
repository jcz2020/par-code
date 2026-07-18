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
  Par_code_setup.setup_runtime cfg ~f:(fun rt mem_db ->
    Par_code_repl.run rt ~mem_db ~resume:resume_target)

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
  Par_code_setup.setup_runtime cfg ~f:(fun rt mem_db ->
    Par_code_repl.run_single_shot rt ~mem_db ~message:question)

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

let parse_kind = function
  | "preference" -> Ok Par_code_memory.Preference
  | "convention" -> Ok Par_code_memory.Convention
  | "insight"    -> Ok Par_code_memory.Insight
  | "gotcha"     -> Ok Par_code_memory.Gotcha
  | "task_map"   -> Ok Par_code_memory.Task_map
  | s -> Error (Printf.sprintf
    "Unknown kind: %s (expected: preference|convention|insight|gotcha|task_map)" s)

let with_memory_db f =
  match Par_code_memory.open_db () with
  | Error (`Db_error msg) ->
    Printf.eprintf "Error opening memory database: %s\n%!" msg;
    exit 1
  | Ok mem_db ->
    Fun.protect ~finally:(fun () -> Par_code_memory.close mem_db) (fun () -> f mem_db)

let format_kind = function
  | Par_code_memory.Preference -> "preference"
  | Par_code_memory.Convention -> "convention"
  | Par_code_memory.Insight    -> "insight"
  | Par_code_memory.Gotcha     -> "gotcha"
  | Par_code_memory.Task_map   -> "task_map"

let format_timestamp ts =
  let tm = Unix.localtime ts in
  Printf.sprintf "%04d-%02d-%02d"
    (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1) tm.Unix.tm_mday

let print_memory_header () =
  Printf.printf "%-12s %-12s %-40s %s\n" "ID" "KIND" "SUMMARY" "UPDATED";
  Printf.printf "%s\n" (String.make 75 '-')

let print_memory_row (m : Par_code_memory.memory) =
  let short_id = String.sub m.id 0 (min 8 (String.length m.id)) in
  let summary = if String.length m.summary > 40
    then String.sub m.summary 0 37 ^ "..."
    else m.summary in
  Printf.printf "%-12s %-12s %-40s %s\n"
    short_id (format_kind m.kind) summary (format_timestamp m.updated_at)

let cmd_memory_list limit =
  with_memory_db (fun mem_db ->
    let project_id = Par_code_memory.resolve_project_id () in
    match Par_code_memory.list mem_db ~project_id ~limit () with
    | Error (`Db_error msg) ->
      Printf.eprintf "Error listing memories: %s\n%!" msg;
      exit 1
    | Ok [] ->
      Printf.printf "No memories found for this project.\n%!";
    | Ok memories ->
      print_memory_header ();
      List.iter print_memory_row memories)

let cmd_memory_list_term =
  let open Term in
  const cmd_memory_list $ Cli_args.memory_limit_arg

let info_memory_list = Cmd.info "list" ~doc:"List all memories for this project"

let cmd_memory_add kind_str_opt summary_opt content_opt =
  match kind_str_opt, summary_opt, content_opt with
  | None, _, _ | _, None, _ | _, _, None ->
    Printf.eprintf "Error: --kind, --summary, and --content are all required\n%!";
    exit 1
  | Some kind_str, Some summary, Some content ->
    match parse_kind kind_str with
    | Error msg ->
      Printf.eprintf "Error: %s\n%!" msg;
      exit 1
    | Ok kind ->
      with_memory_db (fun mem_db ->
        let project_id = Par_code_memory.resolve_project_id () in
        match Par_code_memory.add mem_db ~project_id ~kind ~content ~summary
                ~citations:[] ~source:`Manual with
        | Error (`Db_error msg) ->
          Printf.eprintf "Error adding memory: %s\n%!" msg;
          exit 1
        | Ok id ->
          Printf.printf "Added memory #%s\n%!" id)

let cmd_memory_add_term =
  let open Term in
  const cmd_memory_add
  $ Cli_args.memory_kind_arg $ Cli_args.memory_summary_arg
  $ Cli_args.memory_content_arg

let info_memory_add = Cmd.info "add" ~doc:"Add a new memory manually"

let cmd_memory_forget id =
  with_memory_db (fun mem_db ->
    match Par_code_memory.forget mem_db ~id with
    | Error (`Db_error msg) ->
      Printf.eprintf "Error forgetting memory: %s\n%!" msg;
      exit 1
    | Ok () ->
      Printf.printf "Forgot memory #%s\n%!" id)

let cmd_memory_forget_term =
  let open Term in
  const cmd_memory_forget $ Cli_args.memory_id_arg

let info_memory_forget = Cmd.info "forget" ~doc:"Delete a memory by ID"

let cmd_memory_show id =
  with_memory_db (fun mem_db ->
    let project_id = Par_code_memory.resolve_project_id () in
    match Par_code_memory.list mem_db ~project_id ~limit:10000 () with
    | Error (`Db_error msg) ->
      Printf.eprintf "Error listing memories: %s\n%!" msg;
      exit 1
    | Ok memories ->
      match List.find_opt (fun (m : Par_code_memory.memory) -> m.id = id) memories with
      | None ->
        Printf.eprintf "Error: memory #%s not found\n%!" id;
        exit 1
      | Some m ->
        Printf.printf "ID:         %s\n" m.id;
        Printf.printf "Kind:       %s\n" (format_kind m.kind);
        Printf.printf "Summary:    %s\n" m.summary;
        Printf.printf "Content:    %s\n" m.content;
        (match m.citations with
         | [] -> ()
         | cits -> Printf.printf "Citations:  %s\n" (String.concat ", " cits));
        Printf.printf "Created:    %s\n" (format_timestamp m.created_at);
        Printf.printf "Updated:    %s\n" (format_timestamp m.updated_at);
        (match m.last_used_at with
         | None -> ()
         | Some ts -> Printf.printf "Last used:  %s\n" (format_timestamp ts));
        Printf.printf "Used:       %d times\n" m.usage_count;
        Printf.printf "Source:     %s\n%!"
          (match m.source with `Manual -> "manual" | `Agent -> "agent" | `Import -> "import"))

let cmd_memory_show_term =
  let open Term in
  const cmd_memory_show $ Cli_args.memory_id_arg

let info_memory_show = Cmd.info "show" ~doc:"Show full details of a memory by ID"

let cmd_memory_export output =
  with_memory_db (fun mem_db ->
    let project_id = Par_code_memory.resolve_project_id () in
    let md = Par_code_memory.export_markdown mem_db ~project_id in
    if md = "" then
      Printf.printf "No memories to export.\n%!"
    else if output = "stdout" then
      Printf.printf "%s%!" md
    else begin
      let oc = open_out output in
      output_string oc md;
      close_out oc;
      Printf.printf "Exported to %s\n%!" output
    end)

let cmd_memory_export_term =
  let open Term in
  const cmd_memory_export $ Cli_args.memory_output_arg

let info_memory_export = Cmd.info "export" ~doc:"Export memories as MEMORY.md"

let cmd_memory_prune older_than_days =
  with_memory_db (fun mem_db ->
    let project_id = Par_code_memory.resolve_project_id () in
    match Par_code_memory.prune_stale mem_db ~project_id ~older_than_days with
    | Error (`Db_error msg) ->
      Printf.eprintf "Error pruning memories: %s\n%!" msg;
      exit 1
    | Ok count ->
      Printf.printf "Pruned %d stale memories\n%!" count)

let cmd_memory_prune_term =
  let open Term in
  const cmd_memory_prune $ Cli_args.memory_older_than_arg

let info_memory_prune = Cmd.info "prune" ~doc:"Remove stale unused memories"

let cmd_memory_search query =
  with_memory_db (fun mem_db ->
    let project_id = Par_code_memory.resolve_project_id () in
    match Par_code_memory.recall mem_db ~project_id ~query ~limit:10 () with
    | Error (`Db_error msg) ->
      Printf.eprintf "Error searching memories: %s\n%!" msg;
      exit 1
    | Ok [] ->
      Printf.printf "No memories matched your query.\n%!";
    | Ok memories ->
      print_memory_header ();
      List.iter print_memory_row memories)

let cmd_memory_search_term =
  let open Term in
  const cmd_memory_search $ Cli_args.memory_query_arg

let info_memory_search = Cmd.info "search" ~doc:"Full-text search memories"

let cmd_memory_search_history query =
  with_memory_db (fun mem_db ->
    match Par_code_memory.search_history mem_db ~query ~limit:10 () with
    | Error (`Db_error msg) ->
      Printf.eprintf "Error searching history: %s\n%!" msg;
      exit 1
    | Ok [] ->
      Printf.printf "No history matched your query.\n%!";
    | Ok hits ->
      Printf.printf "%-24s %-40s %-10s %s\n" "SESSION_ID" "SNIPPET" "UPDATED" "TURNS";
      Printf.printf "%s\n" (String.make 90 '-');
      List.iter (fun (h : Par_code_memory.history_hit) ->
        let snippet = if String.length h.snippet > 40
          then String.sub h.snippet 0 37 ^ "..."
          else h.snippet in
        Printf.printf "%-24s %-40s %-10s %d\n"
          h.session_id snippet (format_timestamp h.updated_at) h.turn_count
      ) hits)

let cmd_memory_search_history_term =
  let open Term in
  const cmd_memory_search_history $ Cli_args.memory_query_arg

let info_memory_search_history =
  Cmd.info "search-history" ~doc:"Full-text search past session transcripts"

let cmd_memory =
  Cmd.group (Cmd.info "memory" ~doc:"Manage project memories")
    [ Cmd.v info_memory_list cmd_memory_list_term;
      Cmd.v info_memory_add cmd_memory_add_term;
      Cmd.v info_memory_forget cmd_memory_forget_term;
      Cmd.v info_memory_show cmd_memory_show_term;
      Cmd.v info_memory_export cmd_memory_export_term;
      Cmd.v info_memory_prune cmd_memory_prune_term;
      Cmd.v info_memory_search cmd_memory_search_term;
      Cmd.v info_memory_search_history cmd_memory_search_history_term; ]

let cmd =
  Cmd.group ~default:term_chat
    (Cmd.info "par" ~version:Par_code_version.version_info
       ~doc:"Interactive coding agent built on the PAR SDK — run 'par' to start the REPL, 'par config' to configure, 'par ask \"question\"' for one-shot")
    [ Cmd.v info_config term_config;
      Cmd.v info_ask term_ask;
      Cmd.v info_upgrade term_upgrade;
      cmd_memory; ]

let is_chat_mode () =
  let args = Array.to_list Sys.argv in
  let rec scan = function
    | [] -> true
    | "--help" :: _ | "-h" :: _ -> false
    | "--version" :: _ | "-v" :: _ -> false
    | "config" :: _ | "ask" :: _ | "upgrade" :: _ | "memory" :: _ -> false
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
