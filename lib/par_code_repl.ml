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
  Printf.printf "  /reset    Reset conversation (clear history)\n";
  Printf.printf "  /quit     Exit\n%!"

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
  let on_tool_event = make_tool_event_callback () in
  Sys.set_signal Sys.sigint (Sys.Signal_handle (fun _ ->
    let _ = Runtime.save_conversation rt in
    maybe_extract rt !conv;
    Printf.eprintf "\n[Interrupted — session saved]\n%!";
    exit 130));
  let rec loop () =
    Printf.printf "par> %!";
    match input_line stdin with
    | exception End_of_file ->
      let _ = Runtime.save_conversation rt in
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
         | "/quit" | "/exit" ->
           let _ = Runtime.save_conversation rt in
           maybe_extract rt !conv;
           Printf.printf "Bye!\n%!"; exit 0
         | _ -> Printf.eprintf "Unknown command: %s (try /help)\n%!" cmd);
        loop ()
       end else begin
         (try
            let memory_appendix = build_memory_appendix mem_db in
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
              let _ = Runtime.save_conversation rt in ()
            | Ok { Types.response = _; conversation = returned_conv } ->
              conv := Some returned_conv;
              Printf.printf "\n%!";
              let _ = Runtime.save_conversation rt in ())
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
  | Ok { Types.response = _; conversation = _ } ->
    Printf.printf "\n%!";
    let _ = Runtime.save_conversation rt in ())
