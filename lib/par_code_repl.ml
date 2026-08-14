(* par_code_repl.ml — Interactive REPL loop.
 *
 * Drives Runtime.invoke with token streaming, slash-command dispatch, and
 * session resume (most-recent / by-id). *)

open Par

let string_contains_i ~haystack ~needle =
  let h = String.lowercase_ascii haystack in
  let n = String.lowercase_ascii needle in
  let lh = String.length h and ln = String.length n in
  let rec go i =
    if i + ln > lh then false
    else if String.sub h i ln = n then true
    else go (i + 1)
  in
  ln = 0 || go 0

let stream_print_chunk (ui : Par_code_ui.backend) (chunk : Types.llm_response_chunk) =
  Par_code_ui.render_llm_chunk ui chunk

let make_stream_cb ui =
  let streamed_text = ref false in
  let cb chunk =
    (match chunk with Types.Text_delta _ -> streamed_text := true | _ -> ());
    stream_print_chunk ui chunk
  in
  cb, streamed_text

let make_tool_event_callback (ui : Par_code_ui.backend) ?(doom = None)
    ?(on_doom_action : Par_code_doom_loop.action -> unit = fun _ -> ()) () =
  let start_times : (string, float) Hashtbl.t = Hashtbl.create 8 in
  let tool_args_buf : (string, string) Hashtbl.t = Hashtbl.create 8 in
  fun (evt : Types.event) ->
    (match evt, doom with
     | Types.Bash_invoked { task_id; argv; _ }, Some _ ->
       Hashtbl.replace tool_args_buf (Types.Task_id.to_string task_id)
         (String.concat " " argv)
     | Types.Tool_invoked { task_id; _ }, Some _ ->
       Hashtbl.replace tool_args_buf (Types.Task_id.to_string task_id) ""
     | Types.Tool_completed { task_id; tool_name; result_preview; _ }, Some d ->
       let tid = Types.Task_id.to_string task_id in
       let args_str = Hashtbl.find_opt tool_args_buf tid |> Option.value ~default:"" in
       Hashtbl.remove tool_args_buf tid;
       let action = Par_code_doom_loop.record d {
         tool_name; args_json = `String args_str;
         output = result_preview; failed = false
       } in
       (match action with
        | Par_code_doom_loop.Nudge msg -> Par_code_ui.render_warning ui msg
        | Force_judge msg -> on_doom_action (Force_judge msg); Par_code_ui.render_warning ui msg
        | Abort msg ->
          on_doom_action (Abort msg);
           Par_code_ui.render_error ui
             (Printf.sprintf "\xe2\x9c\x97 goal aborted (doom loop) \xe2\x80\x94 cancelling this turn: %s" msg)
        | Continue -> ())
     | Types.Tool_failed { task_id; tool_name; _ }, Some d ->
       let tid = Types.Task_id.to_string task_id in
       let args_str = Hashtbl.find_opt tool_args_buf tid |> Option.value ~default:"" in
       Hashtbl.remove tool_args_buf tid;
       let action = Par_code_doom_loop.record d {
         tool_name; args_json = `String args_str;
         output = None; failed = true
       } in
       (match action with
        | Par_code_doom_loop.Nudge msg -> Par_code_ui.render_warning ui msg
        | Force_judge msg -> on_doom_action (Force_judge msg); Par_code_ui.render_warning ui msg
        | Abort msg ->
          on_doom_action (Abort msg);
           Par_code_ui.render_error ui
             (Printf.sprintf "\xe2\x9c\x97 goal aborted (doom loop) \xe2\x80\x94 cancelling this turn: %s" msg)
        | Continue -> ())
     | _ -> ());
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
    (match Par_code_session.load_most_recent_scoped () with
     | Ok (Some (sid, conv)) ->
       Par_code_ui.render_notice ui (Printf.sprintf "Resumed most recent session: %s" sid);
       Some conv
     | Ok None -> Par_code_ui.render_warning ui "No prior session found."; None
     | Error e -> Par_code_ui.render_error ui (Printf.sprintf "Failed to load session: %s" e); None)
  | Resume_of id_or_prefix ->
    (match Par_code_session.resolve_id id_or_prefix with
     | Error msg -> Par_code_ui.render_error ui msg; None
     | Ok sid ->
       (match Runtime.load_conversation rt sid with
        | Ok (Some conv) ->
          Par_code_ui.render_notice ui (Printf.sprintf "Resumed session: %s" sid);
          Some conv
        | Ok None -> Par_code_ui.render_error ui (Printf.sprintf "Session not found: %s" sid); None
        | Error e -> Par_code_ui.render_error ui (Printf.sprintf "Failed to load session %s: %s" sid (Par_code_setup.error_to_string e)); None))

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

let run (rt : Runtime.runtime) ~(mem_db : Par_code_memory.t option) ~resume ?goal () =
  let ui = Par_code_ui.create_backend () in
  (* v0.5.5 P0 #2: tag every save with the current project scope so that
     `par session list` / `par -r` / `par --continue <prefix>` filter
     correctly. PAR SDK 0.8.3 surfaced ?scope through Runtime.save_conversation. *)
  let scope = Par_code_memory.resolve_project_id () in
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
  let last_plan_path : string option ref = ref None in
  let goal_feedback : string option ref = ref None in
  let invoke_start_time = ref 0.0 in
  let hit_cap = ref false in
  let no_progress_streak = ref 0 in
  let loaded_cfg = Par_code_config.load () in
  let ckpt_enabled = match loaded_cfg with Some c -> c.Par_code_config.checkpoint_enabled | None -> true in
  let ckpt_interval = match loaded_cfg with Some c -> c.Par_code_config.checkpoint_interval | None -> 10 in
  let ctx_budget = match loaded_cfg with Some c -> c.Par_code_config.context_budget_tokens | None -> 100000 in
  let goal_max_steps = match loaded_cfg with Some c -> c.Par_code_config.goal_max_steps | None -> 50 in
  let goal_verify_cmd = match loaded_cfg with Some c -> c.Par_code_config.goal_verify_command | None -> None in
  let env_no_ckpt = match Sys.getenv_opt "PAR_NO_CHECKPOINT" with Some "1" | Some "true" -> true | _ -> false in
  (match resume with
   | No_prior ->
     (match loaded_cfg with
      | Some c -> Par_code_mode.current := c.Par_code_config.default_mode
      | None -> ())
   | Resume_most_recent | Resume_of _ ->
     (match Par_code_mode.load_mode_from_disk () with
      | Some m -> Par_code_mode.current := m
      | None ->
        (match loaded_cfg with
         | Some c -> Par_code_mode.current := c.Par_code_config.default_mode
         | None -> ())));
  at_exit Par_code_mode.save_current_mode_to_disk;
  (* W4: restore goal from disk on startup — memory-only, no auto-continue *)
  (match resume with
   | No_prior -> ()
   | Resume_most_recent | Resume_of _ ->
     (match Par_code_goal.load_goal_from_disk () with
      | Some g ->
        Par_code_goal.restore_goal g;
        let obj_display =
          if String.length g.Par_code_goal.objective > 60 then
            String.sub g.Par_code_goal.objective 0 57 ^ "..."
          else g.Par_code_goal.objective
        in
        Par_code_ui.render_notice ui
          (Printf.sprintf "[goal restored: %s (step %d/%d, %s) — /goal resume to continue]"
             obj_display g.Par_code_goal.step_count g.Par_code_goal.max_steps
             (Par_code_goal.status_label g.Par_code_goal.status))
      | None -> ()));
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
  let doom_detector = Par_code_doom_loop.create
    ?bash_retries:(Option.map (fun c -> c.Par_code_config.doom_bash_retries) loaded_cfg)
    ?edit_matches:(Option.map (fun c -> c.Par_code_config.doom_edit_matches) loaded_cfg)
    ?action_streak:(Option.map (fun c -> c.Par_code_config.doom_action_streak) loaded_cfg)
    () in
  let doom_force_judge = ref false in
  let doom_abort_msg = ref None in
  let doom_abort = ref false in
  (* v0.7.3 W5: per-invoke cancellation state. turn_token_ref holds the
     current turn's token while Runtime.invoke is in flight (cleared in a
     Fun.protect finally, Oracle R3(b)); in_invoke/cancel_pending drive the
     SIGINT ladder (reset at every execute_turn entry). *)
  let turn_token_ref : Types.cancellation_token option ref = ref None in
  let in_invoke = ref false in
  let cancel_pending = ref false in
  let on_tool_event = make_tool_event_callback ui ~doom:(Some doom_detector)
      ~on_doom_action:(fun act ->
        match act with
        | Par_code_doom_loop.Abort msg ->
          doom_abort := true; doom_abort_msg := Some msg;
          (* W5: doom abort is REAL now — cancel the in-flight invoke
             (Guard_cancelled, PAR SDK 0.10.0). The between-turns flag
             consumption in run_goal_evaluation stays as the idempotent
             fallback when no token is in flight. *)
          (match !turn_token_ref with
           | Some tok ->
             Par.Cancellation.request_cancel tok
               (Types.Guard_cancelled ("doom-loop: " ^ msg))
           | None -> ())
        | Par_code_doom_loop.Force_judge _ -> doom_force_judge := true
        | _ -> ()) () in
  (* W5: SIGINT ladder — 1st Ctrl+C during an invoke cancels the turn
     (goal pauses on return), 2nd force-exits (Signal_ignore closes the
     reentrant save window first, Oracle R4). At the prompt / outside a
     model turn it still saves + exits (v0.5.4 behavior). The judge
     window has no token — Ctrl+C there exits (documented design). *)
  Sys.set_signal Sys.sigint (Sys.Signal_handle (fun _ ->
    match Par_code_chain.sigint_action
            ~in_invoke:!in_invoke ~cancel_pending:!cancel_pending with
    | Par_code_chain.Request_cancel ->
      (match !turn_token_ref with
       | Some tok ->
         cancel_pending := true;
         Par.Cancellation.request_cancel tok Types.User_cancelled;
         Par_code_ui.render_notice ui
           "\n[cancelling \xe2\x80\x94 Ctrl+C again to force exit]"
       | None ->
         (* tiny race: invoke just returned; treat as prompt-time *)
         let _ = Runtime.save_conversation rt ?conversation:!conv ~scope () in
         Par_code_ui.render_notice ui "\nBye!";
         exit 0)
    | Par_code_chain.Force_exit ->
      Sys.set_signal Sys.sigint Sys.Signal_ignore;
      let _ = Runtime.save_conversation rt ?conversation:!conv ~scope () in
      Par_code_ui.render_notice ui "\nBye!";
      exit 0
    | Par_code_chain.Exit_now ->
      let _ = Runtime.save_conversation rt ?conversation:!conv ~scope () in
      Par_code_ui.render_notice ui "\nBye!";
      exit 0));
   let exit_normally () =
     let _ = Runtime.save_conversation rt ?conversation:!conv ~scope () in
     maybe_extract ui rt !conv;
     Par_code_ui.render_notice ui "\nBye!";
     exit 0
   in
   (* linenoise handles prompt display + UTF-8/wide-char-aware input editing.
      None = EOF (Ctrl+D) or Ctrl+C (linenoise default catch_break=false).
      History persists across sessions at ~/.par/history. *)
  (try
     LNoise.history_load ~filename:(Filename.concat (Par_code_config.config_dir ()) "history")
     |> ignore
   with _ -> ());
  (* v0.7.3 W4: the turn body, extracted verbatim from loop()'s
     normal-input branch so the chaining driver (W6) can invoke it
     without user input. Closes over the run-scoped refs (conv,
     turn_count, session_id, ...) on purpose — no parameterization.
     Behavior-identical pure motion; returns Chain_stop for now,
     chaining lands in W6. history_add/history_save stay in loop()'s
     input branch — chained messages are not user input. *)
   let execute_turn (message : string) : Par_code_chain.turn_outcome =
            cancel_pending := false;
            in_invoke := true;
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
              let plan_appendix = match !last_plan_path with
                | Some path ->
                  (try
                    let ic = open_in path in
                    let len = in_channel_length ic in
                    let buf = Bytes.create len in
                    really_input ic buf 0 len;
                    close_in ic;
                    let plan_text = Bytes.to_string buf in
            Some (Printf.sprintf
                       "\n\n## Mode Switch: Plan -> Build\n\nYour operational mode has changed from plan to build. The plan below was produced in plan mode and approved by the user. Execute it now.\n\n%s" plan_text)
                  with Sys_error _ ->
                    Some (Printf.sprintf
                      "\n\n## Plan Reference\n\nYour plan was saved to `%s`." path))
                | None -> None
              in
              let goal_appendix =
                match !goal_feedback, !Par_code_goal.current with
                | Some feedback, _ ->
                  goal_feedback := None;
                  Some (Printf.sprintf
                    "\n\n## Goal Status\n\nYou are working toward a goal. The judge evaluated your last turn and found the goal NOT YET MET.\n\nJudge feedback: %s\n\nContinue working toward the goal. Address the judge's feedback." feedback)
                | None, Some g when g.Par_code_goal.status = Par_code_goal.Active ->
                  Some (Printf.sprintf
                    "\n\n## Active Goal\n\nYou are working toward this goal: %s\n\nWork toward this goal. When you believe it is complete, call the goal_done tool with a summary of what you accomplished." g.Par_code_goal.objective)
                | _ -> None
              in
              let combined_appendix = match memory_appendix, plan_appendix, goal_appendix with
                | None, None, None -> None
                | Some m, None, None -> Some m
                | None, Some p, None -> Some p
                | None, None, Some g -> Some g
                | Some m, Some p, None -> Some (m ^ p)
                | Some m, None, Some g -> Some (m ^ g)
                | None, Some p, Some g -> Some (p ^ g)
                | Some m, Some p, Some g -> Some (m ^ p ^ g)
              in
               let mode_before_invoke = !Par_code_mode.current in
               invoke_start_time := Unix.gettimeofday ();
               hit_cap := false;
               let tool_count_before = match !conv with
                 | Some c -> List.length c.Types.messages
                 | None -> 0
               in
                let stream_cb, streamed_text = make_stream_cb ui in
               let invoke_result =
                 let turn_token =
                   Par.Cancellation.create_token (Par.Runtime.cancellation_root rt) in
                 turn_token_ref := Some turn_token;
                 Fun.protect
                   ~finally:(fun () -> turn_token_ref := None; in_invoke := false)
                   (fun () ->
                      Runtime.invoke rt
                        ~agent_id:(Par_code_mode.agent_id_for !Par_code_mode.current)
                        ~message
                        ?conversation:!conv
                        ~on_tool_event
                        ~on_chunk:(Some stream_cb)
                        ~enable_handoff:true
                        ?system_prompt_appendix:combined_appendix
                        ~cancellation_token:turn_token
                        ())
               in
               last_plan_path := None;
               (match invoke_result with
               | Error (Types.Cancelled reason, recovered_conv) ->
                  conv := Some recovered_conv;
                  Par_code_ui.flush_markdown ui;
                  let _ = Runtime.save_conversation rt ?conversation:!conv ~scope () in ();
                  incr turn_count;
                  (match Par_code_chain.cancel_outcome reason with
                   | Par_code_chain.Pause_goal ->
                     (match !Par_code_goal.current with
                      | Some g when g.Par_code_goal.status = Par_code_goal.Active ->
                        Par_code_goal.pause_goal ();
                        Par_code_ui.render_notice ui
                          "[goal paused \xe2\x80\x94 /goal resume to continue]"
                      | _ -> Par_code_ui.render_notice ui "[cancelled by user]")
                   | Par_code_chain.Abort_goal r ->
                     Par_code_goal.mark_status Par_code_goal.Aborted;
                     ignore (Par_code_doom_loop.write_incident
                               ~signal:"doom_loop" ~reason:r ~normalized:"" ~original:"");
                     Par_code_ui.render_error ui
                       ("\xe2\x9c\x97 goal aborted (doom loop) \xe2\x80\x94 " ^ r));
                  doom_abort := false; doom_force_judge := false;
                  cancel_pending := false
               | Error (e, recovered_conv) ->
                  conv := Some recovered_conv;
                 Par_code_ui.flush_markdown ui;
                 if string_contains_i
                      ~haystack:(Par_code_setup.error_to_string e)
                      ~needle:"max iterations exceeded"
                 then hit_cap := true;
                 Par_code_ui.render_error ui (Par_code_setup.error_to_string e);
                 let _ = Runtime.save_conversation rt ?conversation:!conv ~scope () in ()
              | Ok { Types.response = resp; conversation = returned_conv; _ } ->
                 conv := Some returned_conv;
                 Par_code_ui.flush_markdown ui;
                  if not !streamed_text then begin
                    (match resp.Types.text with
                     | Some text when text <> "" ->
                       Par_code_ui.render ui (Par_code_ui.text text)
                     | Some _ | None ->
                       let reason = match resp.Types.finish_reason with
                         | Types.Content_filter -> " (content filter)"
                         | Types.Max_tokens -> " (max tokens)"
                         | _ -> ""
                       in
                       Par_code_ui.render_warning ui
                         (Printf.sprintf "[model returned no text%s]" reason))
                  end;
                 Par_code_ui.render_line ui Par_code_ui.empty;
                cost := add_usage !cost resp.Types.usage;
                let _ = Runtime.save_conversation rt ?conversation:!conv ~scope () in ();
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
                 end);
              (if mode_before_invoke = Par_code_mode.Plan
                && !Par_code_mode.current = Par_code_mode.Build then begin
                 (match !conv with
                  | Some c ->
                    (match Par_code_plan_tools.persist_plan_file c with
                     | Some path ->
                       last_plan_path := Some path;
                       Par_code_ui.render_notice ui (Printf.sprintf "Plan saved to %s" path)
                     | None -> ())
                  | None -> ())
                end);
               Par_code_chain.run_goal_evaluation
                 ~rt ~ui ~conv ~goal_feedback ~no_progress_streak
                 ~goal_verify_cmd ~doom_abort ~doom_abort_msg ~doom_force_judge
                 ~tool_count_before ()
            with ex ->
             Par_code_ui.render_error ui (Printf.sprintf "\n[error] %s" (Printexc.to_string ex)));
                (match Par_code_plan_tools.consume_submitted_plan () with
                  | Some path ->
                    last_plan_path := Some path;
                    Par_code_ui.render_success ui
                      (Printf.sprintf "Plan saved to %s. Switched to BUILD mode." path)
                  | None ->
                    if !Par_code_mode.current = Par_code_mode.Plan
                       && not (Par_code_plan_tools.plan_file_written_since !invoke_start_time)
                    then begin
                      (match !conv with
                       | Some c ->
                         (match Par_code_plan_tools.try_synthesize_plan rt c with
                          | Ok text when Par_code_plan_tools.has_six_sections text ->
                            (match Par_code_plan_tools.persist_text text with
                             | Some path ->
                               last_plan_path := Some path;
                               let prefix = if !hit_cap
                                 then "planner hit iteration cap"
                                 else "planner stopped early"
                               in
                               Par_code_ui.render_notice ui
                                 (Printf.sprintf "%s \xe2\x80\x94 synthesized plan saved to %s" prefix path)
                             | None -> ())
                          | _ ->
                            (match Par_code_plan_tools.persist_plan_file c with
                             | Some path ->
                               last_plan_path := Some path;
                               Par_code_ui.render_warning ui
                                 (Printf.sprintf "[plan synthesis failed \xe2\x80\x94 saved raw planner output to %s]" path)
                             | None -> ()))
                       | None -> ())
                    end);
           Par_code_chain.Chain_stop
  in
  let rec loop () =
    (* linenoise writes the prompt directly to fd 1, bypassing OCaml's stdout
       buffer — flush first so rendered output (slash commands via render,
       which doesn't flush) appears before the next prompt overwrites the view. *)
    flush stdout;
    match LNoise.linenoise (Par_code_ui.prompt_string !Par_code_mode.current) with
    | exception Sys.Break ->
      exit_normally ()
    | None ->
      exit_normally ()
    | Some line ->
      let trimmed = String.trim line in
      if trimmed = "" then loop ()
      else if trimmed.[0] = '/' then begin
        let parts = String.split_on_char ' ' trimmed in
        let cmd = match parts with c :: _ -> c | [] -> "" in
        (match cmd with
         | "/help" -> print_help ui ()
         | "/session" ->
           let msg_count = match !conv with
             | None -> 0
             | Some c -> List.length c.Types.messages
           in
           Par_code_ui.render_session_info ui
             ~agent_id:Par_code_setup.agent_id
             ~session_id:(match !session_id with Some s -> s | None -> "none")
             ~turn_count:!turn_count
             ~message_count:msg_count
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
             exit_normally ()
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
          | "/plan" ->
            let prev = Par_code_mode.switch Plan in
            if prev = Plan then
              Par_code_ui.render_notice ui "Already in plan mode."
            else
              Par_code_ui.render_success ui "Switched to PLAN mode. Agent will investigate and produce a plan. Use /build to start implementing.";
            loop ()

          | "/build" ->
            let prev = Par_code_mode.switch Build in
            if prev = Build then
              Par_code_ui.render_notice ui "Already in build mode."
            else begin
               (match !conv with
                | Some c ->
                  (match Par_code_plan_tools.persist_plan_file c with
                   | Some path ->
                     last_plan_path := Some path;
                     Par_code_ui.render_notice ui (Printf.sprintf "Plan saved to %s" path)
                   | None ->
                     Par_code_ui.render_warning ui "Could not save plan file (no assistant message or write error).")
                | None -> ());
              Par_code_ui.render_success ui "Switched to BUILD mode."
            end;
            loop ()
          | "/goal" ->
            let rest = if String.length trimmed > 5 then String.trim (String.sub trimmed 5 (String.length trimmed - 5)) else "" in
            if rest = "clear" then begin
              Par_code_goal.clear_goal ();
              Par_code_goal.clear_done_signal ();
              Par_code_ui.render_notice ui "[goal cleared]"
            end else if rest = "pause" then begin
              Par_code_goal.pause_goal ();
              Par_code_ui.render_notice ui "[goal paused]"
            end else if rest = "resume" then begin
              if Par_code_goal.resume_goal () then
                Par_code_ui.render_notice ui "[goal resumed — agent will continue next turn]"
              else
                Par_code_ui.render_warning ui "[cannot resume: goal not paused/blocked]"
            end else if rest = "" then
              (match !Par_code_goal.current with
               | Some g -> Par_code_ui.render_notice ui
                   (Printf.sprintf "[active goal: %s] (step %d/%d, %s)"
                      g.Par_code_goal.objective g.Par_code_goal.step_count
                      g.Par_code_goal.max_steps (Par_code_goal.status_label g.Par_code_goal.status))
               | None -> Par_code_ui.render_notice ui "[no active goal]")
            else begin
              if !Par_code_mode.current = Plan then
                ignore (Par_code_mode.switch Build);
              Par_code_goal.set_goal ~objective:rest ~max_steps:goal_max_steps ();
              Par_code_ui.render_success ui
                (Printf.sprintf "Goal set: %s\nAgent will be evaluated by the judge after each turn. Use goal_done tool when you believe the goal is met." rest)
            end;
            loop ()
          | _ -> Par_code_ui.render_error ui (Printf.sprintf "Unknown command: %s (try /help)" cmd));
         loop ()
       end else begin
           (match LNoise.history_add trimmed with Ok () -> () | Error _ -> ());
           (try LNoise.history_save
             ~filename:(Filename.concat (Par_code_config.config_dir ()) "history")
             |> ignore
           with _ -> ());
           ignore (execute_turn trimmed);
           loop ()
      end
  in
  (match goal with
   | Some g when g <> "" ->
     Par_code_goal.set_goal ~objective:g ~max_steps:goal_max_steps ();
     Par_code_ui.render_success ui
       (Printf.sprintf "Goal set: %s\nAgent will be evaluated by the judge after each turn." g)
   | _ -> ());
  loop ()

let run_single_shot (rt : Runtime.runtime) ~(mem_db : Par_code_memory.t option) ~message =
  let ui = Par_code_ui.create_backend () in
  let scope = Par_code_memory.resolve_project_id () in
  let memory_appendix = build_memory_appendix mem_db in
  let stream_cb, streamed_text = make_stream_cb ui in
  (match Runtime.invoke rt
     ~agent_id:Par_code_setup.agent_id
     ~message
     ~on_tool_event:(make_tool_event_callback ui ())
     ~on_chunk:(Some stream_cb)
     ~enable_handoff:true
     ?system_prompt_appendix:memory_appendix
     () with
   | Error (e, _) ->
     Par_code_ui.flush_markdown ui;
     Par_code_ui.render_error ui (Par_code_setup.error_to_string e);
     exit 1
    | Ok { Types.response = resp; conversation = conv; _ } ->
      Par_code_ui.flush_markdown ui;
       if not !streamed_text then begin
         (match resp.Types.text with
          | Some text when text <> "" ->
            Par_code_ui.render ui (Par_code_ui.text text)
          | Some _ | None ->
            let reason = match resp.Types.finish_reason with
              | Types.Content_filter -> " (content filter)"
              | Types.Max_tokens -> " (max tokens)"
              | _ -> ""
            in
            Par_code_ui.render_warning ui
              (Printf.sprintf "[model returned no text%s]" reason))
       end;
      Par_code_ui.render_line ui Par_code_ui.empty;
      let _ = Runtime.save_conversation rt ~conversation:conv ~scope () in ())
