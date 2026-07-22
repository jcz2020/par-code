open Cmdliner

let ui = Par_code_ui.create_backend ()

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
    Par_code_ui.render_error ui "Usage: par ask <question>";
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

let cmd_config_show () =
  match Par_code_config.load () with
  | Some cfg -> Par_code_config.show cfg
  | None ->
    Par_code_ui.render_notice ui "No config found. Run `par config` to create one."

let term_config_show =
  let open Term in
  const (fun () -> cmd_config_show ()) $ const ()

let info_config_show = Cmd.info "show" ~doc:"Print current configuration"

let cmd_config_set () = Par_code_config.run_wizard ()

let term_config_set =
  let open Term in
  const (fun () -> cmd_config_set ()) $ const ()

let info_config_set = Cmd.info "set" ~doc:"Run configuration wizard"

let cmd_config_group =
  Cmd.group ~default:term_config_set
    (Cmd.info "config" ~doc:"Configure provider and model settings")
    [ Cmd.v info_config_show term_config_show;
      Cmd.v info_config_set term_config_set; ]

let cmd_upgrade check_opt to_opt uninstall_opt purge_opt =
  if purge_opt && not uninstall_opt then begin
    Par_code_ui.render_error ui "--purge requires --uninstall";
    exit 2
  end;
  if uninstall_opt then begin
    let dir = Par_code_config.config_dir () in
    if purge_opt then begin
      if Unix.isatty Unix.stdin then begin
        let prompt =
          Par_code_ui.textf
            "This will delete ALL of %s including config and sessions. Continue? [y/N] "
            dir
        in
        let answer =
          match Par_code_ui.read_line ui ~prompt with
          | Some s -> String.lowercase_ascii (String.trim s)
          | None -> ""
        in
        match answer with
        | "y" | "yes" -> ()
        | _ ->
          Par_code_ui.render_notice ui "Aborted.";
          exit 1
      end else begin
        Par_code_ui.render_error ui
          "--purge requires interactive terminal (stdin must be a tty)";
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
    Par_code_ui.render_success ui "Uninstalled.";
    exit 0
  end;
  if check_opt then begin
    let cur = Par_code_upgrade.current_version () in
    (match Par_code_upgrade.fetch_latest_tag ~timeout:2.0 () with
     | Error `Offline ->
       Par_code_ui.render_notice ui (Printf.sprintf "current: %s" cur);
       Par_code_ui.render_notice ui "offline — could not check latest";
       exit 1
     | Error (`Http msg) ->
       Par_code_ui.render_error ui (Printf.sprintf "Error checking latest: %s" msg);
       exit 1
     | Ok latest ->
       Par_code_ui.render_notice ui (Printf.sprintf "current: %s" cur);
       Par_code_ui.render_notice ui (Printf.sprintf "latest:  %s" latest);
       exit (if cur = latest then 0 else 1))
  end;
  match Par_code_upgrade.perform_upgrade ?target:to_opt () with
  | Ok new_ver ->
    Par_code_ui.render_success ui (Printf.sprintf "Upgraded to %s" new_ver)
  | Error (`Download_failed msg) ->
    Par_code_ui.render_error ui (Printf.sprintf "Upgrade failed (download): %s" msg);
    exit 1
  | Error `Checksum_mismatch ->
    Par_code_ui.render_error ui "Upgrade failed: checksum mismatch";
    exit 1
  | Error (`Smoke_test_failed msg) ->
    Par_code_ui.render_error ui (Printf.sprintf "Upgrade failed (smoke test): %s" msg);
    exit 1

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
    Par_code_ui.render_error ui (Printf.sprintf "Error opening memory database: %s" msg);
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

let truncate_summary s =
  if String.length s > 40
  then String.sub s 0 37 ^ "..."
  else s

let render_memory_table (memories : Par_code_memory.memory list) =
  let rows =
    List.map (fun (m : Par_code_memory.memory) ->
      [ String.sub m.id 0 (min 8 (String.length m.id));
        format_kind m.kind;
        truncate_summary m.summary;
        format_timestamp m.updated_at ]
    ) memories
  in
  Par_code_ui.render_table ui
    ~headers:["ID"; "KIND"; "SUMMARY"; "UPDATED"]
    ~rows

let cmd_memory_list limit =
  with_memory_db (fun mem_db ->
    let project_id = Par_code_memory.resolve_project_id () in
    match Par_code_memory.list mem_db ~project_id ~limit () with
    | Error (`Db_error msg) ->
      Par_code_ui.render_error ui (Printf.sprintf "Error listing memories: %s" msg);
      exit 1
    | Ok [] ->
      Par_code_ui.render_notice ui "No memories found for this project."
    | Ok memories ->
      render_memory_table memories)

let cmd_memory_list_term =
  let open Term in
  const cmd_memory_list $ Cli_args.memory_limit_arg

let info_memory_list = Cmd.info "list" ~doc:"List all memories for this project"

let cmd_memory_add kind_str_opt summary_opt content_opt =
  match kind_str_opt, summary_opt, content_opt with
  | None, _, _ | _, None, _ | _, _, None ->
    Par_code_ui.render_error ui
      "--kind, --summary, and --content are all required";
    exit 1
  | Some kind_str, Some summary, Some content ->
    (match parse_kind kind_str with
     | Error msg ->
       Par_code_ui.render_error ui msg;
       exit 1
     | Ok kind ->
       with_memory_db (fun mem_db ->
         let project_id = Par_code_memory.resolve_project_id () in
         match Par_code_memory.add mem_db ~project_id ~kind ~content ~summary
                 ~citations:[] ~source:`Manual with
         | Error (`Db_error msg) ->
           Par_code_ui.render_error ui
             (Printf.sprintf "Error adding memory: %s" msg);
           exit 1
         | Ok id ->
           Par_code_ui.render_success ui (Printf.sprintf "Added memory #%s" id)))

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
      Par_code_ui.render_error ui (Printf.sprintf "Error forgetting memory: %s" msg);
      exit 1
    | Ok () ->
      Par_code_ui.render_success ui (Printf.sprintf "Forgot memory #%s" id))

let cmd_memory_forget_term =
  let open Term in
  const cmd_memory_forget $ Cli_args.memory_id_arg

let info_memory_forget = Cmd.info "forget" ~doc:"Delete a memory by ID"

let cmd_memory_show id =
  with_memory_db (fun mem_db ->
    let project_id = Par_code_memory.resolve_project_id () in
    match Par_code_memory.list mem_db ~project_id ~limit:10000 () with
    | Error (`Db_error msg) ->
      Par_code_ui.render_error ui (Printf.sprintf "Error listing memories: %s" msg);
      exit 1
    | Ok memories ->
      (match List.find_opt (fun (m : Par_code_memory.memory) -> m.id = id) memories with
       | None ->
         Par_code_ui.render_error ui (Printf.sprintf "memory #%s not found" id);
         exit 1
       | Some m ->
         let citations_line =
           match m.citations with
           | [] -> []
           | cits -> [ Par_code_ui.textf "Citations:  %s" (String.concat ", " cits) ]
         in
         let last_used_line =
           match m.last_used_at with
           | None -> []
           | Some ts -> [ Par_code_ui.textf "Last used:  %s" (format_timestamp ts) ]
         in
         let source_str =
           match m.source with
           | `Manual -> "manual"
           | `Agent -> "agent"
           | `Import -> "import"
         in
         let image =
           Par_code_ui.vcat (
             [ Par_code_ui.textf "ID:         %s" m.id;
               Par_code_ui.textf "Kind:       %s" (format_kind m.kind);
               Par_code_ui.textf "Summary:    %s" m.summary;
               Par_code_ui.textf "Content:    %s" m.content ]
             @ citations_line
             @ [ Par_code_ui.textf "Created:    %s" (format_timestamp m.created_at);
                 Par_code_ui.textf "Updated:    %s" (format_timestamp m.updated_at) ]
             @ last_used_line
             @ [ Par_code_ui.textf "Used:       %d times" m.usage_count;
                 Par_code_ui.textf "Source:     %s" source_str ]
           )
         in
         Par_code_ui.render_line ui image))

let cmd_memory_show_term =
  let open Term in
  const cmd_memory_show $ Cli_args.memory_id_arg

let info_memory_show = Cmd.info "show" ~doc:"Show full details of a memory by ID"

let cmd_memory_export output =
  with_memory_db (fun mem_db ->
    let project_id = Par_code_memory.resolve_project_id () in
    let md = Par_code_memory.export_markdown mem_db ~project_id in
    if md = "" then
      Par_code_ui.render_notice ui "No memories to export."
    else if output = "stdout" then
      Par_code_ui.render ui (Par_code_ui.text md)
    else begin
      let oc = open_out output in
      output_string oc md;
      close_out oc;
      Par_code_ui.render_success ui (Printf.sprintf "Exported to %s" output)
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
      Par_code_ui.render_error ui (Printf.sprintf "Error pruning memories: %s" msg);
      exit 1
    | Ok count ->
      Par_code_ui.render_notice ui (Printf.sprintf "Pruned %d stale memories" count))

let cmd_memory_prune_term =
  let open Term in
  const cmd_memory_prune $ Cli_args.memory_older_than_arg

let info_memory_prune = Cmd.info "prune" ~doc:"Remove stale unused memories"

let cmd_memory_search query =
  with_memory_db (fun mem_db ->
    let project_id = Par_code_memory.resolve_project_id () in
    match Par_code_memory.recall mem_db ~project_id ~query ~limit:10 () with
    | Error (`Db_error msg) ->
      Par_code_ui.render_error ui (Printf.sprintf "Error searching memories: %s" msg);
      exit 1
    | Ok [] ->
      Par_code_ui.render_notice ui "No memories matched your query."
    | Ok memories ->
      render_memory_table memories)

let cmd_memory_search_term =
  let open Term in
  const cmd_memory_search $ Cli_args.memory_query_arg

let info_memory_search = Cmd.info "search" ~doc:"Full-text search memories"

let cmd_memory_search_history query =
  with_memory_db (fun mem_db ->
    match Par_code_memory.search_history mem_db ~query ~limit:10 () with
    | Error (`Db_error msg) ->
      Par_code_ui.render_error ui (Printf.sprintf "Error searching history: %s" msg);
      exit 1
    | Ok [] ->
      Par_code_ui.render_notice ui "No history matched your query."
    | Ok hits ->
      let rows =
        List.map (fun (h : Par_code_memory.history_hit) ->
          [ h.session_id;
            truncate_summary h.snippet;
            format_timestamp h.updated_at;
            string_of_int h.turn_count ]
        ) hits
      in
      Par_code_ui.render_table ui
        ~headers:["SESSION_ID"; "SNIPPET"; "UPDATED"; "TURNS"]
        ~rows)

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
    [ cmd_config_group;
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
            Par_code_ui.render_notice ui
              (Printf.sprintf
                 "info: par %s is available (current: %s). Run 'par upgrade'."
                 latest cur)
          | Ok _ | Error _ -> ())
       with _ -> ())
    end

let () =
  if not (Unix.isatty Unix.stdout) then Unix.putenv "TERM" "dumb";
  maybe_check_version ();
  exit (Cmd.eval cmd)
