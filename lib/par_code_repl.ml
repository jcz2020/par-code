(* par_code_repl.ml — Interactive REPL loop.
 *
 * Drives Runtime.invoke with token streaming, slash-command dispatch, and
 * session resume (most-recent / by-id). *)

open Par

open Par_code_repl_io

(* Constructor re-export so existing callers keep using
   [Par_code_repl.Resume_most_recent] etc. *)
type resume_target = Par_code_repl_io.resume_target =
  | No_prior
  | Resume_most_recent
  | Resume_of of string

(* v0.10.0 W4: the SDK rehydrates interrupted durable invokes at [Runtime.create]
   time; this is the user-facing half of crash recovery. *)
let resume_hint (orphans : (string * string) list) : string option =
  match orphans with
  | [] -> None
  | (id, agent) :: _ ->
    Some
      (Printf.sprintf
         "[resume] %d interrupted run(s); latest %s (agent %s). /resume continues \
          it, /resume <id> picks another, /resume discard drops them."
         (List.length orphans) id agent)

(* [Runtime] has no delete for a checkpoint, so drop it through the persistence
   service we build in setup. *)
let forget_orphan (id : string) : (unit, string) result =
  match Par_code_setup.persistence () with
  | None -> Error "no persistence service"
  | Some p ->
    (match p.Par.Types.delete_invoke_checkpoint_fn id with
     | Ok () -> Ok ()
     | Error e -> Error (Par_code_setup.error_to_string e))

let run (rt : Runtime.runtime) ~(mem_db : Par_code_memory.t option) ~resume ?goal
    ?max () =
  let ui = Par_code_ui.create_backend () in
  (* v0.5.5 P0 #2: tag every save with the current project scope so that
     `par session list` / `par -r` / `par --continue <prefix>` filter
     correctly. PAR SDK 0.8.3 surfaced ?scope through Runtime.save_conversation. *)
  let scope = Par_code_memory.resolve_project_id () in
  Par_code_ui.render_banner ui ~version:Par_code_version.version;
  let conv : Types.conversation option ref = ref (load_initial_conv ui rt resume) in
  let orphans = ref (Runtime.list_orphaned_invokes rt) in
  (match resume_hint !orphans with
   | Some line -> Par_code_ui.render_warning ui line
   | None -> ());
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
  (* v0.7.3 W6: invoke-error streak (Oracle R1/B16) — reset on Ok,
     untouched on Cancelled, blocks the goal at 2. *)
  let consecutive_invoke_errors = ref 0 in
  let loaded_cfg = Par_code_config.load () in
  let ckpt_enabled = match loaded_cfg with Some c -> c.Par_code_config.checkpoint_enabled | None -> true in
  let ckpt_interval = match loaded_cfg with Some c -> c.Par_code_config.checkpoint_interval | None -> 10 in
  let ctx_budget = match loaded_cfg with Some c -> c.Par_code_config.context_budget_tokens | None -> 100000 in
  let goal_max_steps = match loaded_cfg with Some c -> c.Par_code_config.goal_max_steps | None -> 50 in
  let goal_auto_chain = match loaded_cfg with Some c -> c.Par_code_config.goal_auto_chain | None -> true in
  let goal_verify_cmd = match loaded_cfg with Some c -> c.Par_code_config.goal_verify_command | None -> None in
  let env_no_ckpt = match Sys.getenv_opt "PAR_NO_CHECKPOINT" with Some "1" | Some "true" -> true | _ -> false in
  let max_mode_on =
    ref (match loaded_cfg with Some c -> c.Par_code_config.max_mode | None -> false)
  in
  let max_n =
    ref (match loaded_cfg with Some c -> c.Par_code_config.max_candidates | None -> 3)
  in
  let max_chain_notice = ref false in
  let cost_precounted = ref false in
  (match max with
   | Some n ->
     let n = Par_code_max_mode.clamp_candidates n in
     max_mode_on := true;
     max_n := n;
     Par_code_ui.render_notice ui
       (Printf.sprintf "[max mode] on \xe2\x80\x94 %d candidates per turn" n)
   | None -> ());
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
  let make_tool_event ?rt () =
    make_tool_event_callback ui ?rt ~doom:(Some doom_detector)
      ~goal_active:(fun () ->
        match !Par_code_goal.current with
        | Some g when g.Par_code_goal.status = Par_code_goal.Active -> true
        | _ -> false)
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
        | _ -> ()) ()
  in
  let on_tool_event = make_tool_event ~rt () in
  (* Replaying the winning candidate's events must render them (and feed the
     doom detector) without recording their tool invocations a second time. *)
  let replay_tool_event = make_tool_event () in
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
      [v0.7.3 W6] Returns the chaining outcome (continue only while goal
      Active + Build + auto_chain + no cancel/doom/exn + errors < 2;
      Oracle R1 skips the ladder on errored turns). history_add/
      history_save stay in loop()'s input branch — chained messages are
      not user input. *)
    let execute_turn ?(skills : string list option)
        ?(skill_appendix : string option)
        ~(chained : bool) (message : string) : Par_code_chain.turn_outcome =
      (if
         !max_mode_on && not !max_chain_notice
         && (chained
             || match !Par_code_goal.current with
                | Some g -> g.Par_code_goal.status = Par_code_goal.Active
                | None -> false)
       then begin
         max_chain_notice := true;
         Par_code_ui.render_notice ui
           "[max mode] skipped during the goal chain \xe2\x80\x94 cost would scale with N"
       end);
      conv := Option.map Par_code_payload.sanitize !conv;
      let max_turn_active () =
        !max_mode_on
        && (not chained)
        && skills = None
        && !Par_code_mode.current = Par_code_mode.Build
        && (match !Par_code_goal.current with
            | Some g when g.Par_code_goal.status = Par_code_goal.Active -> false
            | _ -> true)
      in
             cancel_pending := false;
             in_invoke := true;
             let turn_cancelled = ref false and turn_errored = ref false and turn_exn = ref false in
             let stream_cancelled = ref false in
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
               let turn_appendix =
                 match combined_appendix, skill_appendix with
                 | None, None -> None
                 | Some a, None -> Some a
                 | None, Some s -> Some ("## Skill Instructions\n\n" ^ s)
                 | Some a, Some s ->
                   Some (a ^ "\n\n## Skill Instructions\n\n" ^ s)
               in
               let mode_before_invoke = !Par_code_mode.current in
               invoke_start_time := Unix.gettimeofday ();
               hit_cap := false;
               cost_precounted := false;
               let tool_count_before = match !conv with
                 | Some c -> List.length c.Types.messages
                 | None -> 0
               in
                let stream_cb, streamed_text =
                  make_stream_cb
                    ~cancelled:(fun () ->
                      if !cancel_pending then (stream_cancelled := true; true) else false)
                    ui in
               let max_turn = max_turn_active () in
               let invoke_result =
                 let turn_token =
                   Par.Cancellation.create_token (Par.Runtime.cancellation_root rt) in
                 turn_token_ref := Some turn_token;
                 Fun.protect
                   ~finally:(fun () -> turn_token_ref := None; in_invoke := false)
                   (fun () ->
                      let single msg =
                        Runtime.invoke rt
                          ~agent_id:(Par_code_mode.agent_id_for !Par_code_mode.current)
                          ~message:msg
                          ?conversation:!conv
                          ~on_tool_event
                          ~on_chunk:(Some stream_cb)
                          ~enable_handoff:true
                          ?system_prompt_appendix:turn_appendix
                          ?skills
                          ~cancellation_token:turn_token
                          ~durable:true
                          ()
                      in
                      if not max_turn then single message
                      else begin
                        let n = !max_n in
                        Par_code_ui.render_notice ui
                          (Printf.sprintf "[max mode] %d candidates running..." n);
                        let outcome =
                          Par_code_max_mode.run_candidates ~rt
                            ~agent_id:Par_code_max_mode.candidate_agent_id
                            ~message ?conversation:!conv
                            ?system_prompt_appendix:combined_appendix ~n
                            ~cancellation_token:turn_token
                            ~on_candidate_done:(fun i ok ->
                              Par_code_ui.render_notice ui
                                (Printf.sprintf "  candidate %d/%d \xc2\xb7 %s"
                                   (i + 1) n (if ok then "done" else "failed")))
                            ()
                        in
                        match outcome.Par_code_max_mode.candidates with
                        | [] ->
                          if Par.Cancellation.is_cancelled turn_token then
                            Error
                              ( Types.Cancelled Types.User_cancelled
                              , (match !conv with
                                 | Some c -> c
                                 | None -> { Types.messages = []; metadata = [] }) )
                          else begin
                            Par_code_ui.render_warning ui
                              "[max mode] all candidates failed \xe2\x80\x94 running a single pass";
                            single message
                          end
                        | cands ->
                          let texts =
                            List.map
                              (fun (c : Par_code_max_mode.candidate) ->
                                 c.Par_code_max_mode.text)
                              cands
                          in
                          let choice =
                            match
                              Par_code_selector.choose ~rt ~user_message:message
                                texts
                            with
                            | Ok ch -> ch
                            | Error msg ->
                              Par_code_ui.render_warning ui
                                (Printf.sprintf
                                   "[max mode] selector failed (%s) \xe2\x80\x94 using candidate 1"
                                   msg);
                              Par_code_selector.default_choice
                          in
                          let idx =
                            if
                              choice.Par_code_selector.index
                              < List.length cands
                              && choice.Par_code_selector.index >= 0
                            then choice.Par_code_selector.index
                            else 0
                          in
                          let winner = List.nth cands idx in
                          List.iter replay_tool_event winner.Par_code_max_mode.events;
                          let failed =
                            List.length outcome.Par_code_max_mode.failures
                          in
                          List.iter
                            (fun (i, msg) ->
                               Par_code_ui.render_warning ui
                                 (Printf.sprintf
                                    "[max mode] candidate %d failed \xe2\x80\x94 %s"
                                    (i + 1) msg))
                            outcome.Par_code_max_mode.failures;
                          Par_code_ui.render_notice ui
                            (Printf.sprintf
                               "[max mode] selected candidate %d/%d%s \xe2\x80\x94 %s"
                               (winner.Par_code_max_mode.index + 1)
                               (List.length cands)
                               (if failed = 0 then ""
                                else Printf.sprintf " (%d failed)" failed)
                               (if choice.Par_code_selector.reasoning = "" then
                                  "no reasoning given"
                                else choice.Par_code_selector.reasoning));
                          cost :=
                            List.fold_left add_usage !cost
                              (Par_code_max_mode.candidate_usages outcome);
                          cost := add_generate_usage !cost choice.Par_code_selector.total_tokens;
                          (match choice.Par_code_selector.kind with
                           | Par_code_selector.Answer ->
                             cost_precounted := true;
                             Ok
                               { Types.response =
                                   { Types.text =
                                       Some winner.Par_code_max_mode.text
                                   ; reasoning = []
                                   ; tool_calls = None
                                   ; finish_reason = Types.Stop
                                   ; usage = Par_code_max_mode.empty_usage
                                   ; model = ""
                                   }
                               ; conversation =
                                   Par_code_payload.sanitize
                                     (Par_code_max_mode.restore_user_message
                                        ~original:message
                                        winner.Par_code_max_mode.conversation)
                               ; approval_pending = None
                               ; invoke_id = None
                               }
                           | Par_code_selector.Execute ->
                             conv :=
                               Some
                                 (Par_code_payload.sanitize
                                    (Par_code_max_mode.restore_user_message
                                       ~original:message
                                       winner.Par_code_max_mode.conversation));
                             let plan = choice.Par_code_selector.plan in
                             Par_code_ui.render_notice ui
                               "[max mode] executing the selected approach";
                             single
                               (if String.trim plan = "" then message else plan))
                      end)
               in
               last_plan_path := None;
                (match invoke_result with
                | Error (Types.Cancelled reason, recovered_conv) ->
                   turn_cancelled := true;
                   conv := Some (Par_code_payload.sanitize recovered_conv);
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
                     (match !Par_code_goal.current with
                      | Some g when g.Par_code_goal.status = Par_code_goal.Active ->
                        Par_code_goal.mark_status Par_code_goal.Aborted;
                        ignore (Par_code_doom_loop.write_incident
                                  ~signal:"doom_loop" ~reason:r ~normalized:"" ~original:"");
                        Par_code_ui.render_error ui
                          ("\xe2\x9c\x97 goal aborted (doom loop) \xe2\x80\x94 " ^ r)
                      | _ ->
                        Par_code_ui.render_error ui
                          ("\xe2\x9c\x97 turn aborted (doom loop) \xe2\x80\x94 " ^ r)));
                  doom_abort := false; doom_force_judge := false;
                  cancel_pending := false
                | Error (e, recovered_conv) ->
                   conv := Some (Par_code_payload.sanitize recovered_conv);
                  (match e with
                   | Types.Invalid_input s
                     when String.length s > 0 && s.[0] = '{' ->
                     dump_payload_debug ui recovered_conv
                   | _ -> ());
                  Par_code_ui.flush_markdown ui;
                  if string_contains_i
                       ~haystack:(Par_code_setup.error_to_string e)
                       ~needle:"max iterations exceeded"
                  then hit_cap := true;
                  if Par_code_chain.counts_invoke_error e then
                    incr consecutive_invoke_errors;
                  turn_errored := true;
                  if !stream_cancelled then begin
                    turn_cancelled := true;
                    Par_code_ui.render_notice ui "[cancelled by user]"
                  end else
                    Par_code_ui.render_error ui (Par_code_setup.error_to_string e);
                 let _ = Runtime.save_conversation rt ?conversation:!conv ~scope () in ()
              | Ok { Types.response = resp; conversation = returned_conv; _ } ->
                 conv := Some (Par_code_payload.sanitize returned_conv);
                 if !stream_cancelled then begin
                   turn_cancelled := true;
                   Par_code_ui.flush_markdown ui;
                   Par_code_ui.render_notice ui "[cancelled by user]"
                 end else begin
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
                 end;
                 if not !cost_precounted then cost := add_usage !cost resp.Types.usage;
                 consecutive_invoke_errors := 0;
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
                && !Par_code_mode.current = Par_code_mode.Build
                && not (Par_code_plan_tools.submitted_plan_pending ()) then begin
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
                  ~tool_count_before ~skip_ladder:!turn_errored ()
             with ex ->
              turn_exn := true;
              (match ex with
               | Par_code_repl_io.Stream_cancel_requested ->
                 turn_cancelled := true;
                 cancel_pending := false;
                 doom_abort := false;
                 doom_force_judge := false;
                 Par_code_ui.flush_markdown ui;
                 (match !conv with
                  | Some c -> ignore (Runtime.save_conversation rt ~conversation:c ~scope ())
                  | None -> ());
                 Par_code_ui.render_notice ui "\n[cancelled by user]"
               | _ ->
                 Par_code_ui.render_error ui
                   (Printf.sprintf "\n[error] %s" (Printexc.to_string ex))));
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
                (* v0.7.3 W6: chaining decision — AFTER goal evaluation +
                   plan fallback so verdicts/blocks/switches are applied.
                   should_continue covers goal/mode/auto_chain/doom/cancel/
                   errors<2 (doom_abort reads false — live doom was already
                   consumed into an Aborted status above). *)
                let chain_st : Par_code_chain.chain_state = {
                  Par_code_chain.goal = !Par_code_goal.current;
                  mode = !Par_code_mode.current;
                  auto_chain = goal_auto_chain;
                  doom_aborted = !doom_abort;
                  cancelled = !turn_cancelled;
                  consecutive_invoke_errors = !consecutive_invoke_errors;
                } in
                if !turn_cancelled || !turn_exn then Par_code_chain.Chain_stop
                else if Par_code_chain.should_continue chain_st then
                  Par_code_chain.Chain_continue
                    (Par_code_chain.continuation_message ())
                else if !consecutive_invoke_errors >= 2 then begin
                  (* B16: should_continue said no on the streak — block here. *)
                  (match !Par_code_goal.current with
                   | Some g when g.Par_code_goal.status = Par_code_goal.Active ->
                     Par_code_goal.block_goal "llm_error_x2";
                     Par_code_ui.render_warning ui
                       "[goal blocked \xe2\x80\x94 LLM errors x2; check provider config, /goal resume to retry]"
                   | _ -> ());
                  Par_code_chain.Chain_stop
                end
                else Par_code_chain.Chain_stop
   in
   (* v0.7.3 W6: the chaining driver — feeds execute_turn's continuation
      back in as the next user message; no user input, no history entries.
      Tail-recursive, bounded by execute_turn's stop conditions. *)
   let rec run_chain (message : string) : unit =
     (match execute_turn ~chained:true message with
      | Par_code_chain.Chain_stop -> ()
      | Par_code_chain.Chain_continue next -> run_chain next)
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
                     ~extract:false
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
            let metrics =
              let agents =
                Runtime.list_agents rt
                |> List.map (fun (a : Types.agent_config) ->
                     (a.id,
                      List.map (fun (t : Types.tool_descriptor) -> t.name)
                        a.tools))
              in
              let visible =
                Par_code_repl_io.tools_visible_of_agents
                  ~agent_id:Par_code_setup.agent_id agents
              in
              Par_code_repl_io.operational_metrics
                ~sdk:(Runtime.metrics_snapshot rt) ~tools_visible:visible
            in
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
          | "/max" ->
            let rest =
              if String.length trimmed > 4 then
                String.trim (String.sub trimmed 4 (String.length trimmed - 4))
              else ""
            in
            (match String.lowercase_ascii rest with
             | "" ->
               Par_code_ui.render_notice ui
                 (Printf.sprintf
                    "[max mode: %s, %d candidates] usage: /max on | off | <2-5>"
                    (if !max_mode_on then "on" else "off") !max_n)
             | "on" ->
               max_mode_on := true;
               Par_code_ui.render_success ui
                 (Printf.sprintf
                    "Max mode on: %d candidates per turn (cost scales with N)."
                    !max_n)
             | "off" ->
               max_mode_on := false;
               Par_code_ui.render_notice ui "[max mode off]"
             | other ->
               (match int_of_string_opt other with
                | Some n when n >= 2 && n <= 5 ->
                  max_mode_on := true;
                  max_n := n;
                  Par_code_ui.render_success ui
                    (Printf.sprintf "Max mode on: %d candidates per turn." n)
                | _ ->
                  Par_code_ui.render_warning ui
                    "[max mode] candidates must be between 2 and 5"));
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
          | "/skills" ->
            let rest =
              if String.length trimmed > 7 then
                String.trim (String.sub trimmed 7 (String.length trimmed - 7))
              else ""
            in
            if rest = "reload" then begin
              let registered, rejected = Par_code_skills.reload ~rt () in
              Par_code_ui.render_notice ui
                (Printf.sprintf "[skills] reloaded: %d custom command(s)"
                   (List.length registered));
              List.iter
                (fun (id, reason) ->
                   Par_code_ui.render_warning ui
                     (Printf.sprintf "[skills] %s: %s" id reason))
                rejected
            end else if rest = "" then begin
              let entries = Par_code_skills.list_custom () in
              if entries = [] then
                Par_code_ui.render_notice ui
                  "No custom skills. Add .par/skills/<id>/skill.md (or ~/.par/skills/) and run /skills reload."
              else begin
                Par_code_ui.render_notice ui "Custom commands:";
                List.iter
                  (fun (e : Par_code_skills.entry) ->
                     Par_code_ui.render_notice ui
                       (Printf.sprintf "  /%s  %s  [%s]"
                          e.Par_code_skills.descriptor.id
                          e.Par_code_skills.descriptor.description
                          (Par_code_skills.source_string e.Par_code_skills.source)))
                  entries
              end
            end else
              Par_code_ui.render_warning ui "usage: /skills | /skills reload";
            loop ()
          | "/resume" ->
            let rest =
              if String.length trimmed > 7 then
                String.trim (String.sub trimmed 7 (String.length trimmed - 7))
              else ""
            in
            (match !orphans with
             | [] ->
               Par_code_ui.render_notice ui "[resume] nothing to resume"
             | _ when rest = "discard" ->
               List.iter
                 (fun (id, _) ->
                    match forget_orphan id with
                    | Ok () -> ()
                    | Error msg ->
                      Par_code_ui.render_error ui
                        (Printf.sprintf "[resume] could not drop %s: %s" id msg))
                 !orphans;
               orphans := [];
               Par_code_ui.render_notice ui "[resume] dropped"
             | (latest_id, _) :: _ ->
               let target =
                 if rest = "" then Some latest_id
                 else if List.mem_assoc rest !orphans then Some rest
                 else None
               in
               (match target with
                | None ->
                  Par_code_ui.render_warning ui
                    (Printf.sprintf "[resume] unknown run %s" rest)
                | Some id ->
                  Par_code_ui.render_notice ui
                    (Printf.sprintf
                       "[resume] continuing %s; finished tool batches will not run \
                        again" id);
                  let stream_cb, streamed = Par_code_repl_io.make_stream_cb ui in
                  (match
                     Runtime.recover_invoke rt ~invoke_id:id ~save:true
                       ~on_chunk:(Some stream_cb) ()
                   with
                   | Error (err, _) ->
                     Par_code_ui.render_error ui
                       (Printf.sprintf "[resume] %s failed: %s" id
                          (Par_code_setup.error_to_string err))
                   | Ok result ->
                     conv := Some result.Types.conversation;
                     Par_code_ui.flush_markdown ui;
                     Par_code_ui.render_success ui
                       (Printf.sprintf "[resume] %s continued" id);
                     if not !streamed then
                       (match result.Types.response.Types.text with
                        | Some t when String.trim t <> "" ->
                          Par_code_ui.render_notice ui t
                        | _ -> Par_code_ui.render_notice ui "(no text)");
                     orphans := List.filter (fun (o, _) -> o <> id) !orphans)));
            loop ()
          | "/distill" ->
            let rest =
              if String.length trimmed > 8 then
                String.trim (String.sub trimmed 8 (String.length trimmed - 8))
              else ""
            in
            if !Par_code_mode.current = Par_code_mode.Plan then
              Par_code_ui.render_warning ui
                "/distill writes a skill file; switch to build mode first (/build)"
            else begin
              (* v0.9.0 W2: the distiller is a real LLM call. Scope the turn
                 token to it so the first Ctrl+C cancels that call instead of
                 killing the REPL; the second press still force-exits. The
                 confirmation prompt runs outside the scope, so it keeps the
                 normal prompt-time signal behaviour. *)
              let tok =
                Par.Cancellation.create_token (Par.Runtime.cancellation_root rt)
              in
              Par_code_distill.run ~rt ~ui ~mem_db ~conv:!conv ~args:rest
                ~cancellation_token:tok
                ~on_invoke:(fun active ->
                  if active then begin
                    cancel_pending := false;
                    in_invoke := true;
                    turn_token_ref := Some tok
                  end else begin
                    turn_token_ref := None;
                    in_invoke := false
                  end)
                ()
            end;
            loop ()
          | cmd when String.length cmd > 1 ->
            let id = String.sub cmd 1 (String.length cmd - 1) in
            (match Par_code_skills.find_manual id with
             | None ->
               Par_code_ui.render_error ui
                 (Printf.sprintf "Unknown command: %s (try /help or /skills)" cmd)
             | Some entry ->
               let args =
                 if String.length trimmed > String.length cmd then
                   String.trim
                     (String.sub trimmed (String.length cmd)
                        (String.length trimmed - String.length cmd))
                 else ""
               in
               if args = "" then
                 Par_code_ui.render_notice ui
                   (Printf.sprintf "usage: /%s <args> \xe2\x80\x94 %s"
                      entry.Par_code_skills.descriptor.id
                      entry.Par_code_skills.descriptor.description)
               else
                 (match Par_code_skills.read_body entry with
                  | Error e ->
                    Par_code_ui.render_error ui
                      (Printf.sprintf "[skill %s] %s"
                         entry.Par_code_skills.descriptor.id e)
                  | Ok body ->
                    ignore
                      (execute_turn ~chained:false
                         ~skills:[entry.Par_code_skills.descriptor.id]
                         ~skill_appendix:body args)))
          | _ ->
            Par_code_ui.render_error ui
              (Printf.sprintf "Unknown command: %s (try /help)" cmd)
         );
         loop ()
       end else begin
           (match LNoise.history_add trimmed with Ok () -> () | Error _ -> ());
            (try LNoise.history_save
              ~filename:(Filename.concat (Par_code_config.config_dir ()) "history")
              |> ignore
            with _ -> ());
            (* Oracle R3(a): user turn may chain; prompt resumes after. *)
            (match execute_turn ~chained:false trimmed with
             | Par_code_chain.Chain_stop -> ()
             | Par_code_chain.Chain_continue next -> run_chain next);
            loop ()
      end
  in
  (match goal with
   | Some g when g <> "" ->
     Par_code_goal.set_goal ~objective:g ~max_steps:goal_max_steps ();
     Par_code_ui.render_success ui
       (Printf.sprintf "Goal set: %s\nStarting autonomous chain \xe2\x80\x94 Ctrl+C pauses, second Ctrl+C exits." g);
     run_chain g
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
     ~on_tool_event:(make_tool_event_callback ui ~rt ())
     ~on_chunk:(Some stream_cb)
     ~enable_handoff:true
     ?system_prompt_appendix:memory_appendix
     ~durable:true
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
