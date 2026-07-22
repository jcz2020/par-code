(* par_code_repl.ml — Interactive REPL loop.
 *
 * Drives Runtime.invoke with token streaming, slash-command dispatch, and
 * session resume (most-recent / by-id). *)

open Par

let stream_print_chunk (ui : Par_code_ui.backend) (chunk : Types.llm_response_chunk) =
  Par_code_ui.render_llm_chunk ui chunk

let make_tool_event_callback (ui : Par_code_ui.backend) () =
  let start_times : (string, float) Hashtbl.t = Hashtbl.create 8 in
  fun (evt : Types.event) ->
    match evt with
    | Types.Tool_invoked { task_id; _ } ->
      Hashtbl.replace start_times (Types.Task_id.to_string task_id) (Unix.gettimeofday ());
      Par_code_ui.render_tool_event ui evt
    | Types.Tool_completed { task_id; _ } ->
      Hashtbl.remove start_times (Types.Task_id.to_string task_id);
      Par_code_ui.render_tool_event ui evt
    | Types.Tool_failed { task_id; tool_name; _ } ->
      let tid = Types.Task_id.to_string task_id in
      let elapsed = match Hashtbl.find_opt start_times tid with
        | Some t -> (Unix.gettimeofday () -. t) *. 1000.0
        | None -> 0.0
      in
      Hashtbl.remove start_times tid;
      Par_code_ui.render_line ui
        (Par_code_ui.textf ~style:(Par_code_ui.style ~fg:Red ~bold:true ())
           "  \xe2\x86\x92 %s \xe2\x9c\x97 (%.1fms)" tool_name elapsed)
    | _ -> Par_code_ui.render_tool_event ui evt

let print_help (ui : Par_code_ui.backend) () =
  Par_code_ui.render_help ui

let format_health (ui : Par_code_ui.backend) (h : Types.health_status) =
  let runtime_label = if h.Types.runtime_alive then "alive" else "DEAD" in
  let persistence_label = if h.Types.persistence_ok then "ok" else "FAILING" in
  Par_code_ui.render_notice ui (Printf.sprintf "  Runtime:    %s" runtime_label);
  Par_code_ui.render_notice ui (Printf.sprintf "  Persistence: %s" persistence_label)

type resume_target =
  | No_prior
  | Resume_most_recent
  | Resume_of of string

let load_initial_conv (ui : Par_code_ui.backend) (rt : Runtime.runtime) (target : resume_target) : Types.conversation option =
  match target with
  | No_prior -> None
  | Resume_most_recent ->
    (match Runtime.load_most_recent_conversation rt with
     | Ok (Some (sid, conv)) ->
       Par_code_ui.render_notice ui (Printf.sprintf "Resumed most recent session: %s" sid);
       Some conv
     | Ok None -> Par_code_ui.render_warning ui "No prior session found."; None
     | Error e -> Par_code_ui.render_error ui (Printf.sprintf "Failed to load session: %s" (Par_code_setup.error_to_string e)); None)
  | Resume_of sid ->
    (match Runtime.load_conversation rt sid with
     | Ok (Some conv) -> Par_code_ui.render_notice ui (Printf.sprintf "Resumed session: %s" sid); Some conv
     | Ok None -> Par_code_ui.render_error ui (Printf.sprintf "Session not found: %s" sid); None
     | Error e -> Par_code_ui.render_error ui (Printf.sprintf "Failed to load session %s: %s" sid (Par_code_setup.error_to_string e)); None)

let maybe_extract (ui : Par_code_ui.backend) (rt : Runtime.runtime) (conv : Types.conversation option) =
  let enabled =
    match Sys.getenv_opt "PAR_NO_AUTO_EXTRACT" with
    | Some "1" | Some "true" -> false
    | _ ->
      (match Par_code_config.load () with
       | Some cfg -> cfg.Par_code_config.auto_extract
       | None -> true)
  in
  if enabled then begin
    match conv with
    | None -> ()
    | Some c ->
      if List.length c.Types.messages <= 1 then ()
      else begin
        (try
           let project_id = Par_code_memory.resolve_project_id () in
           (match Par_code_memory.open_db () with
            | Error (`Db_error msg) ->
              Par_code_ui.render_warning ui (Printf.sprintf "[extraction skipped: %s]" msg)
            | Ok mem_db ->
              Par_code_extractor.run_extraction rt mem_db ~project_id c;
              Par_code_memory.close mem_db)
         with ex ->
           Par_code_ui.render_error ui (Printf.sprintf "[extraction failed: %s]" (Printexc.to_string ex)))
      end
  end

let build_memory_appendix (mem_db : Par_code_memory.t option) =
  match mem_db with
  | Some t ->
    let project_id = Par_code_memory.resolve_project_id () in
    let index = Par_code_memory.render_index t ~project_id in
    if index = "" then None else Some ("\n\n## Project Memory\n\n" ^ index)
  | None -> None

(* ── Session cost tracking ──────────────────────────────────────────────── *)

type cost_state = {
  llm_calls : int;
  prompt_tokens : int;
  completion_tokens : int;
  total_tokens : int;
}

let empty_cost = {
  llm_calls = 0;
  prompt_tokens = 0;
  completion_tokens = 0;
  total_tokens = 0;
}

let add_usage (state : cost_state) (usage : Types.usage_stats) : cost_state = {
  llm_calls = state.llm_calls + 1;
  prompt_tokens = state.prompt_tokens + usage.Types.prompt_tokens;
  completion_tokens = state.completion_tokens + usage.Types.completion_tokens;
  total_tokens = state.total_tokens + usage.Types.total_tokens;
}

let format_cost_output ~cost ~context_tokens ~turn_count ~metrics =
  let b = Buffer.create 256 in
  Buffer.add_string b "Session usage:\n";
  Buffer.add_string b (Printf.sprintf "  LLM calls:        %d\n" cost.llm_calls);
  Buffer.add_string b (Printf.sprintf "  Prompt tokens:    %d\n" cost.prompt_tokens);
  Buffer.add_string b (Printf.sprintf "  Output tokens:    %d\n" cost.completion_tokens);
  Buffer.add_string b (Printf.sprintf "  Total tokens:     %d\n" cost.total_tokens);
  Buffer.add_string b (Printf.sprintf "  Context size:     %d tokens (current)\n" context_tokens);
  Buffer.add_string b (Printf.sprintf "  Turns completed:  %d\n" turn_count);
  Buffer.add_string b "\nOperational metrics:\n";
  List.iter (fun (k, v) ->
    Buffer.add_string b (Printf.sprintf "  %s: %d\n" k v)) metrics;
  Buffer.add_string b "\nNote: excludes async checkpoint/extraction calls.\n";
  Buffer.contents b

let run (rt : Runtime.runtime) ~(mem_db : Par_code_memory.t option) ~resume =
  let ui = Par_code_ui.create_backend () in
  Par_code_ui.render_banner ui ~version:Par_code_version.version;
  let conv : Types.conversation option ref = ref (load_initial_conv ui rt resume) in
  let turn_count = ref 0 in
  let session_id = ref None in
  let is_first_turn = ref true in
  let first_turn_appendix = ref None in
  (* v0.4.1 Pillar A: throttle flag — set true while a checkpoint fiber is in
     flight, false otherwise. Prevents stacking background LLM calls if user
     hammers turns faster than the checkpoint LLM responds. Reset by the fiber
     on every exit path (Ok/Error/exn) via Fun.protect. *)
  let in_flight_checkpoint = ref false in
  let cost = ref empty_cost in
  let loaded_cfg = Par_code_config.load () in
  let ckpt_enabled = match loaded_cfg with Some c -> c.Par_code_config.checkpoint_enabled | None -> true in
  let ckpt_interval = match loaded_cfg with Some c -> c.Par_code_config.checkpoint_interval | None -> 10 in
  let ctx_budget = match loaded_cfg with Some c -> c.Par_code_config.context_budget_tokens | None -> 100000 in
  let env_no_ckpt = match Sys.getenv_opt "PAR_NO_CHECKPOINT" with Some "1" | Some "true" -> true | _ -> false in
  (* Session brief on resume *)
  (match !conv with
   | Some _ ->
     (try
        let sid = Runtime.get_session_id rt in
        session_id := Some sid;
        (match mem_db with
         | Some t ->
           let brief = Par_code_checkpoint.render_session_brief t ~session_id:sid in
           if brief <> "" then first_turn_appendix := Some brief
         | None -> ())
      with _ -> ())
   | None -> ());
  let on_tool_event = make_tool_event_callback ui () in
  Sys.set_signal Sys.sigint (Sys.Signal_handle (fun _ ->
    let _ = Runtime.save_conversation rt ?conversation:!conv () in
    maybe_extract ui rt !conv;
    Par_code_ui.render_notice ui "\n[Interrupted \xe2\x80\x94 session saved]";
    exit 130));
  let rec loop () =
    Par_code_ui.render_prompt ui;
    match input_line stdin with
    | exception End_of_file ->
      let _ = Runtime.save_conversation rt ?conversation:!conv () in
      maybe_extract ui rt !conv;
      Par_code_ui.render_notice ui "\nBye!"
    | line ->
      let trimmed = String.trim line in
      if trimmed = "" then loop ()
      else if trimmed.[0] = '/' then begin
        let parts = String.split_on_char ' ' trimmed in
        let cmd = match parts with c :: _ -> c | [] -> "" in
        (match cmd with
         | "/help" -> print_help ui ()
         | "/session" ->
           Par_code_ui.render_session_info ui
             ~agent_id:Par_code_setup.agent_id
             ~session_id:(match !session_id with Some s -> s | None -> "none")
             ~turn_count:!turn_count;
           Par_code_ui.render_notice ui (Printf.sprintf "Messages: %s"
             (match !conv with None -> "0" | Some c -> string_of_int (List.length c.Types.messages)))
         | "/health" -> format_health ui (Runtime.health rt)
         | "/reset" -> conv := None; Par_code_ui.render_notice ui "[conversation reset]"
           | "/checkpoint" ->
             (match mem_db, !conv, !session_id with
              | Some t, Some c, Some sid ->
                let pid = Par_code_memory.resolve_project_id () in
                (* Manual /checkpoint is SYNCHRONOUS (v0.4.1 design): user
                   explicitly asked, willing to wait for verification. Only
                   the periodic path is async. *)
                (try
                   Par_code_checkpoint.run_checkpoint ~rt t
                     ~session_id:sid ~project_id:pid c ~turn_number:!turn_count
                 with exn ->
                   Par_code_ui.render_error ui (Printf.sprintf "[checkpoint failed: %s]" (Printexc.to_string exn)))
              | _ ->
                Par_code_ui.render_warning ui "[checkpoint unavailable \xe2\x80\x94 need active session]");
            loop ()
          | "/checkpoints" ->
            (match mem_db, !session_id with
             | Some t, Some sid ->
               (match Par_code_checkpoint.load_checkpoints t ~session_id:sid with
                | Ok [] -> Par_code_ui.render_notice ui "No checkpoints for this session."
                | Ok entries ->
                  let rendered = Par_code_checkpoint.format_checkpoints entries in
                  Par_code_ui.render_notice ui rendered
                | Error (`Db_error msg) -> Par_code_ui.render_error ui (Printf.sprintf "Error: %s" msg))
             | _ -> Par_code_ui.render_warning ui "[checkpoints unavailable]");
            loop ()
         | "/quit" | "/exit" ->
             let _ = Runtime.save_conversation rt ?conversation:!conv () in
             maybe_extract ui rt !conv;
              Par_code_ui.render_notice ui "Bye!"; exit 0
          | "/cost" ->
            let metrics = Runtime.metrics_snapshot rt in
            let context_tokens = match !conv with
              | Some c -> Par_code_context.token_estimate c
              | None -> 0
            in
            let summary : Par_code_ui.cost_summary = {
              llm_calls = !cost.llm_calls;
              prompt_tokens = !cost.prompt_tokens;
              completion_tokens = !cost.completion_tokens;
              total_tokens = !cost.total_tokens;
              context_tokens;
              turn_count = !turn_count;
              metrics;
            } in
            Par_code_ui.render_cost ui summary
          | _ -> Par_code_ui.render_error ui (Printf.sprintf "Unknown command: %s (try /help)" cmd));
         loop ()
       end else begin
          (try
             (match !conv with
              | Some c ->
                let estimated = Par_code_context.token_estimate c in
                if estimated > ctx_budget then begin
                  let summary = match !session_id, mem_db with
                    | Some sid, Some t ->
                      (match Par_code_checkpoint.most_recent_checkpoint t ~session_id:sid with
                       | Ok (Some entry) -> entry.Par_code_checkpoint.task
                       | _ -> "Session in progress")
                    | _ -> "Session in progress"
                  in
                  let compacted = Par_code_context.compact c ~budget_tokens:ctx_budget ~summary () in
                  let after = Par_code_context.token_estimate compacted in
                  if after < estimated then begin
                    Par_code_context.compaction_notice ~turn:!turn_count
                      ~before_tokens:estimated ~after_tokens:after;
                    conv := Some compacted
                  end
                end
              | None -> ());
             let memory_appendix =
               let mem_app = build_memory_appendix mem_db in
               match !is_first_turn, !first_turn_appendix with
               | true, Some brief ->
                 is_first_turn := false;
                 (match mem_app with Some ma -> Some (brief ^ ma) | None -> Some brief)
               | _ -> mem_app
             in
             (match Runtime.invoke rt
               ~agent_id:Par_code_setup.agent_id
               ~message:trimmed
               ?conversation:!conv
               ~on_tool_event
               ~on_chunk:(Some (stream_print_chunk ui))
               ~enable_handoff:true
               ?system_prompt_appendix:memory_appendix
               () with
            | Error (e, recovered_conv) ->
               conv := Some recovered_conv;
               Par_code_ui.flush_markdown ui;
               Par_code_ui.render_error ui (Par_code_setup.error_to_string e);
               let _ = Runtime.save_conversation rt ?conversation:!conv () in ()
             | Ok { Types.response = resp; conversation = returned_conv } ->
               conv := Some returned_conv;
               Par_code_ui.render_line ui Par_code_ui.empty;
               cost := add_usage !cost resp.Types.usage;
               let _ = Runtime.save_conversation rt ?conversation:!conv () in ();
               incr turn_count;
               if !session_id = None then begin
                 (try session_id := Some (Runtime.get_session_id rt) with _ -> ())
               end;
                if not env_no_ckpt && ckpt_enabled then begin
                  (match mem_db, !conv, !session_id with
                   | Some t, Some c, Some sid ->
                     let pid = Par_code_memory.resolve_project_id () in
                     Par_code_checkpoint.maybe_checkpoint ~rt t
                       ~in_flight:in_flight_checkpoint
                       ~session_id:sid ~project_id:pid c
                       ~turn_number:!turn_count ~enabled:ckpt_enabled ~interval:ckpt_interval
                   | _ -> ())
                end)
         with ex ->
           Par_code_ui.render_error ui (Printf.sprintf "\n[error] %s" (Printexc.to_string ex)));
        loop ()
      end
  in
  loop ()

let run_single_shot (rt : Runtime.runtime) ~(mem_db : Par_code_memory.t option) ~message =
  let ui = Par_code_ui.create_backend () in
  let memory_appendix = build_memory_appendix mem_db in
  (match Runtime.invoke rt
     ~agent_id:Par_code_setup.agent_id
     ~message
     ~on_tool_event:(make_tool_event_callback ui ())
     ~on_chunk:(Some (stream_print_chunk ui))
     ~enable_handoff:true
     ?system_prompt_appendix:memory_appendix
     () with
   | Error (e, _) ->
     Par_code_ui.flush_markdown ui;
     Par_code_ui.render_error ui (Par_code_setup.error_to_string e);
     exit 1
   | Ok { Types.response = _; conversation = conv } ->
     Par_code_ui.render_line ui Par_code_ui.empty;
     let _ = Runtime.save_conversation rt ~conversation:conv () in ())
