(* par_code_repl.ml — Interactive REPL loop.
 *
 * Drives Runtime.invoke with token streaming, slash-command dispatch, and
 * session resume (most-recent / by-id). *)

open Par

let stream_print_chunk (chunk : Types.llm_response_chunk) =
  match chunk with
  | Types.Text_delta { text } -> Printf.printf "%s%!" text; flush stdout
  | _ -> ()

let make_tool_event_callback () =
  let start_times : (string, float) Hashtbl.t = Hashtbl.create 8 in
  fun (evt : Types.event) ->
    match evt with
    | Types.Tool_invoked { task_id; _ } ->
      Hashtbl.replace start_times (Types.Task_id.to_string task_id) (Unix.gettimeofday ())
    | Types.Tool_completed { task_id; tool_name; duration_ms; _ } ->
      Hashtbl.remove start_times (Types.Task_id.to_string task_id);
      Printf.eprintf "→ %s ✓ (%.1fms)\n%!" tool_name duration_ms
    | Types.Tool_failed { task_id; tool_name; _ } ->
      let elapsed = match Hashtbl.find_opt start_times (Types.Task_id.to_string task_id) with
        | Some t -> (Unix.gettimeofday () -. t) *. 1000.0
        | None -> 0.0
      in
      Hashtbl.remove start_times (Types.Task_id.to_string task_id);
      Printf.eprintf "→ %s ✗ (%.1fms)\n%!" tool_name elapsed
    | _ -> ()

let print_help () =
  Printf.printf "Commands:\n";
  Printf.printf "  /help     Show this help\n";
  Printf.printf "  /session  Show session info\n";
  Printf.printf "  /health   Show runtime health\n";
  Printf.printf "  /reset       Reset conversation (clear history)\n";
  Printf.printf "  /checkpoint  Force a session checkpoint\n";
  Printf.printf "  /checkpoints List session checkpoints\n";
  Printf.printf "  /quit        Exit\n%!"

let format_health (h : Types.health_status) =
  let runtime_label = if h.Types.runtime_alive then "alive" else "DEAD" in
  let persistence_label = if h.Types.persistence_ok then "ok" else "FAILING" in
  Printf.printf "  Runtime:    %s\n" runtime_label;
  Printf.printf "  Persistence: %s\n" persistence_label

type resume_target =
  | No_prior
  | Resume_most_recent
  | Resume_of of string

let load_initial_conv (rt : Runtime.runtime) (target : resume_target) : Types.conversation option =
  match target with
  | No_prior -> None
  | Resume_most_recent ->
    (match Runtime.load_most_recent_conversation rt with
     | Ok (Some (sid, conv)) ->
       Printf.printf "Resumed most recent session: %s\n%!" sid;
       Some conv
     | Ok None -> Printf.eprintf "No prior session found.\n%!"; None
     | Error e -> Printf.eprintf "Failed to load session: %s\n%!" (Par_code_setup.error_to_string e); None)
  | Resume_of sid ->
    (match Runtime.load_conversation rt sid with
     | Ok (Some conv) -> Printf.printf "Resumed session: %s\n%!" sid; Some conv
     | Ok None -> Printf.eprintf "Session not found: %s\n%!" sid; None
     | Error e -> Printf.eprintf "Failed to load session %s: %s\n%!" sid (Par_code_setup.error_to_string e); None)

let maybe_extract (rt : Runtime.runtime) (conv : Types.conversation option) =
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
              Printf.eprintf "[extraction skipped: %s]\n%!" msg
            | Ok mem_db ->
              Par_code_extractor.run_extraction rt mem_db ~project_id c;
              Par_code_memory.close mem_db)
         with ex ->
           Printf.eprintf "[extraction failed: %s]\n%!" (Printexc.to_string ex))
      end
  end

let build_memory_appendix (mem_db : Par_code_memory.t option) =
  match mem_db with
  | Some t ->
    let project_id = Par_code_memory.resolve_project_id () in
    let index = Par_code_memory.render_index t ~project_id in
    if index = "" then None else Some ("\n\n## Project Memory\n\n" ^ index)
  | None -> None

let run (rt : Runtime.runtime) ~(mem_db : Par_code_memory.t option) ~resume =
  Printf.printf "par %s — type a message (or /help for commands, Ctrl-D to quit)\n%!" Par_code_version.version;
  let conv : Types.conversation option ref = ref (load_initial_conv rt resume) in
  let turn_count = ref 0 in
  let session_id = ref None in
  let is_first_turn = ref true in
  let first_turn_appendix = ref None in
  (* v0.4.1 Pillar A: throttle flag — set true while a checkpoint fiber is in
     flight, false otherwise. Prevents stacking background LLM calls if user
     hammers turns faster than the checkpoint LLM responds. Reset by the fiber
     on every exit path (Ok/Error/exn) via Fun.protect. *)
  let in_flight_checkpoint = ref false in
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
  let on_tool_event = make_tool_event_callback () in
  Sys.set_signal Sys.sigint (Sys.Signal_handle (fun _ ->
    let _ = Runtime.save_conversation rt ?conversation:!conv () in
    maybe_extract rt !conv;
    Printf.eprintf "\n[Interrupted — session saved]\n%!";
    exit 130));
  let rec loop () =
    Printf.printf "par> %!";
    match input_line stdin with
    | exception End_of_file ->
      let _ = Runtime.save_conversation rt ?conversation:!conv () in
      maybe_extract rt !conv;
      Printf.printf "\nBye!\n%!"
    | line ->
      let trimmed = String.trim line in
      if trimmed = "" then loop ()
      else if trimmed.[0] = '/' then begin
        let parts = String.split_on_char ' ' trimmed in
        let cmd = match parts with c :: _ -> c | [] -> "" in
        (match cmd with
         | "/help" -> print_help ()
         | "/session" ->
           Printf.printf "Agent: %s\n" Par_code_setup.agent_id;
           Printf.printf "Conversation: %s\n%!"
             (match !conv with None -> "none" | Some c -> Printf.sprintf "%d messages" (List.length c.Types.messages))
         | "/health" -> format_health (Runtime.health rt)
         | "/reset" -> conv := None; Printf.printf "[conversation reset]\n%!"
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
                   Printf.eprintf "[checkpoint failed: %s]\n%!" (Printexc.to_string exn))
              | _ ->
                Printf.eprintf "[checkpoint unavailable — need active session]\n%!");
            loop ()
          | "/checkpoints" ->
            (match mem_db, !session_id with
             | Some t, Some sid ->
               (match Par_code_checkpoint.load_checkpoints t ~session_id:sid with
                | Ok [] -> Printf.printf "No checkpoints for this session.\n%!"
                | Ok entries ->
                  let rendered = Par_code_checkpoint.format_checkpoints entries in
                  Printf.printf "%s%!" rendered
                | Error (`Db_error msg) -> Printf.eprintf "Error: %s\n%!" msg)
             | _ -> Printf.eprintf "[checkpoints unavailable]\n%!");
            loop ()
         | "/quit" | "/exit" ->
            let _ = Runtime.save_conversation rt ?conversation:!conv () in
            maybe_extract rt !conv;
             Printf.printf "Bye!\n%!"; exit 0
          | _ -> Printf.eprintf "Unknown command: %s (try /help)\n%!" cmd);
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
               ~on_chunk:(Some stream_print_chunk)
               ~enable_handoff:true
               ?system_prompt_appendix:memory_appendix
               () with
            | Error (e, recovered_conv) ->
              conv := Some recovered_conv;
              Printf.eprintf "Error: %s\n%!" (Par_code_setup.error_to_string e);
               let _ = Runtime.save_conversation rt ?conversation:!conv () in ()
             | Ok { Types.response = _; conversation = returned_conv } ->
               conv := Some returned_conv;
               Printf.printf "\n%!";
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
           Printf.eprintf "\n[error] %s\n%!" (Printexc.to_string ex));
        loop ()
      end
  in
  loop ()

let run_single_shot (rt : Runtime.runtime) ~(mem_db : Par_code_memory.t option) ~message =
  let memory_appendix = build_memory_appendix mem_db in
  (match Runtime.invoke rt
     ~agent_id:Par_code_setup.agent_id
     ~message
     ~on_tool_event:(make_tool_event_callback ())
     ~on_chunk:(Some stream_print_chunk)
     ~enable_handoff:true
     ?system_prompt_appendix:memory_appendix
     () with
  | Error (e, _) ->
    Printf.eprintf "Error: %s\n%!" (Par_code_setup.error_to_string e);
    exit 1
   | Ok { Types.response = _; conversation = conv } ->
     Printf.printf "\n%!";
     let _ = Runtime.save_conversation rt ~conversation:conv () in ())
