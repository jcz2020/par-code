open Par

type turn_outcome =
  | Chain_continue of string
  | Chain_stop

type chain_state = {
  goal : Par_code_goal.goal_state option;
  mode : Par_code_mode.mode;
  auto_chain : bool;
  doom_aborted : bool;
  cancelled : bool;
  consecutive_invoke_errors : int;
}

let should_continue (s : chain_state) : bool =
  match s.goal with
  | None -> false
  | Some g ->
    g.status = Active
    && s.mode = Par_code_mode.Build
    && s.auto_chain
    && (not s.doom_aborted)
    && (not s.cancelled)
    && s.consecutive_invoke_errors < 2

let continuation_message () : string =
  "Continue working toward the goal."

type cancel_outcome = Pause_goal | Abort_goal of string

let cancel_outcome (r : Types.cancel_reason) : cancel_outcome =
  match r with
  | Types.User_cancelled -> Pause_goal
  | Types.Guard_cancelled reason -> Abort_goal reason

type sigint_action = Request_cancel | Force_exit | Exit_now

let sigint_action ~in_invoke ~cancel_pending : sigint_action =
  if in_invoke then
    if cancel_pending then Force_exit
    else Request_cancel
  else Exit_now

let contains_ci ~haystack ~needle =
  let haystack = String.lowercase_ascii haystack in
  let needle = String.lowercase_ascii needle in
  let len_h = String.length haystack in
  let len_n = String.length needle in
  if len_n > len_h then false
  else
    let rec go i =
      if i > len_h - len_n then false
      else if String.sub haystack i len_n = needle then true
      else go (i + 1)
    in
    go 0

let is_hit_cap (s : string) : bool =
  contains_ci ~haystack:s ~needle:"max iterations exceeded"

let counts_invoke_error (e : Types.error_category) : bool =
  match e with
  | Types.Cancelled _ -> false
  | Types.External_failure s -> not (is_hit_cap s)
  | Types.Internal s -> not (is_hit_cap s)
  | Types.Timeout
  | Types.Invalid_input _
  | Types.Rate_limited
  | Types.Permission_denied _
  | Types.Embedding_unsupported -> true

(* ── Goal evaluation ladder ───────────────────────────────────────────
   [v0.7.3 W4] Moved verbatim from par_code_repl.ml (was lines 582-782):
   doom-flag consumption + the goal progress ladder (advance_step,
   no-progress streak, max-steps, completion-claim verify command, judge
   cadence). IO companion to the pure decision functions above — renders
   via Par_code_ui, mutates Par_code_goal state and the passed refs
   exactly as the inline code did. Runs on BOTH Ok and Error turn
   results (v0.7.2 semantics; the Error-turn skip is a W6 change per
   Oracle R1, not this refactor). *)

let run_goal_evaluation
    ~(rt : Runtime.runtime)
    ~(ui : Par_code_ui.backend)
    ~(conv : Types.conversation option ref)
    ~(goal_feedback : string option ref)
    ~(no_progress_streak : int ref)
    ~(goal_verify_cmd : string option)
    ~(doom_abort : bool ref)
    ~(doom_abort_msg : string option ref)
    ~(doom_force_judge : bool ref)
    ~(tool_count_before : int)
    () : unit =
               let run_judge g =
                 let verify_result =
                   match goal_verify_cmd with
                   | Some cmd ->
                     let ic = Unix.open_process_in cmd in
                     let buf = Buffer.create 256 in
                     (try while true do
                        Buffer.add_channel buf ic 256
                      done with End_of_file -> ());
                     let _ = Unix.close_process_in ic in
                     Buffer.contents buf
                   | None -> ""
                 in
                 (match Par_code_judge.evaluate_goal ~rt
                    ~goal:g.Par_code_goal.objective ?conv:!conv ~verify_result () with
                  | Ok v when v.goal_met ->
                    Par_code_goal.mark_status Met;
                    Par_code_goal.clear_goal ();
                    Par_code_ui.render_success ui
                      (Printf.sprintf "Goal verified as complete: %s" v.reasoning)
                  | Ok v ->
                    goal_feedback := Some v.reasoning;
                    Par_code_ui.render_warning ui
                      (Printf.sprintf "[judge: goal not yet met — %s]" v.reasoning)
                  | Error msg ->
                    Par_code_ui.render_warning ui
                      (Printf.sprintf "[judge evaluation failed: %s]" msg))
               in
               if !doom_abort then begin
                 Par_code_goal.mark_status Aborted;
                 let reason = match !doom_abort_msg with
                   | Some m -> m | None -> "doom loop abort triggered" in
                 ignore (Par_code_doom_loop.write_incident
                   ~signal:"doom_loop" ~reason
                   ~normalized:"" ~original:"");
                 doom_abort := false;
                 doom_force_judge := false
               end else if !doom_force_judge then begin
                 (match !Par_code_goal.current with
                  | Some g when g.Par_code_goal.status = Par_code_goal.Active -> run_judge g
                  | _ -> ());
                 doom_force_judge := false
               end else
               (match !Par_code_goal.current with
                | Some g when g.Par_code_goal.status = Active
                             && !Par_code_mode.current = Par_code_mode.Build ->
                  let step = Par_code_goal.advance_step () in
                  let triggered_by_done = !Par_code_goal.done_signal <> None in
                  Par_code_goal.clear_done_signal ();
                  let tool_calls_this_turn =
                    match !conv with
                    | Some c ->
                      let new_msgs =
                        let rec drop l n =
                          if n <= 0 then l
                          else match l with [] -> [] | _ :: t -> drop t (n - 1)
                        in
                        drop c.Types.messages tool_count_before
                      in
                      List.fold_left (fun acc (m : Types.message) ->
                        if m.Types.role = Types.Tool then acc + 1 else acc) 0 new_msgs
                    | None -> 0
                  in
                  let last_assistant_text =
                    match !conv with
                    | Some c ->
                      let rec walk = function
                        | [] -> ""
                        | (m : Types.message) :: rest ->
                          if m.Types.role = Types.Assistant then begin
                            let buf = Buffer.create 256 in
                            List.iter (function
                              | Types.Text_block { text; _ } ->
                                if Buffer.length buf > 0 then Buffer.add_char buf '\n';
                                Buffer.add_string buf text
                              | _ -> ()) m.Types.content_blocks;
                            let t = Buffer.contents buf in
                            if t <> "" then t else walk rest
                          end else walk rest
                      in
                      walk (List.rev c.Types.messages)
                    | None -> ""
                  in
                  let assistant_text_len = String.length last_assistant_text in
                  let is_no_progress = Par_code_progress.no_progress
                    ~tool_calls:tool_calls_this_turn
                    ~goal_done:triggered_by_done
                    ~text_len:assistant_text_len
                  in
                  if step >= g.Par_code_goal.max_steps then begin
                    Par_code_goal.mark_status Aborted;
                    Par_code_ui.render_warning ui "[goal aborted: max steps reached]"
                  end else if is_no_progress then begin
                    no_progress_streak := !no_progress_streak + 1;
                    let reason =
                      if !no_progress_streak >= 2 then "no_progress_x2"
                      else "no_progress"
                    in
                    Par_code_goal.block_goal reason;
                    let streak_note =
                      if !no_progress_streak >= 2 then " (x2)" else ""
                    in
                    Par_code_ui.render_warning ui
                      (Printf.sprintf "[goal: no progress this round%s \xe2\x80\x94 blocked; /goal resume to retry, /goal clear to abort]" streak_note)
                  end else begin
                    no_progress_streak := 0;
                    let claims_done =
                      Par_code_progress.claims_completion last_assistant_text
                    in
                    let ran_verify = ref false in
                    let verify_exit_ok = ref false in
                    let verify_output = ref "" in
                    (match goal_verify_cmd with
                     | Some cmd when (claims_done || triggered_by_done) && cmd <> "" ->
                       ran_verify := true;
                       let full_cmd =
                         "sh -c " ^ Filename.quote cmd ^ " 2>&1"
                       in
                       let ic = Unix.open_process_in full_cmd in
                       let buf = Buffer.create 256 in
                       (try while true do
                          Buffer.add_channel buf ic 256
                        done with End_of_file -> ());
                       let status = Unix.close_process_in ic in
                       let output = Buffer.contents buf in
                       verify_output := output;
                       (match status with
                        | Unix.WEXITED 0 ->
                          verify_exit_ok := true;
                          if triggered_by_done then begin
                            Par_code_goal.mark_status Met;
                            Par_code_goal.clear_goal ();
                            Par_code_ui.render_success ui
                              "\xe2\x9c\x93 goal verified by command"
                          end
                        | _ ->
                          let excerpt =
                            if String.length output > 120
                            then String.sub output 0 120 ^ "..."
                            else output
                          in
                          Par_code_goal.block_goal ("verify_failed: " ^ excerpt);
                          goal_feedback := Some
                            (Printf.sprintf
                               "verify command failed: %s. Continue working toward the goal; address the failure."
                               excerpt);
                          Par_code_ui.render_warning ui
                            (Printf.sprintf
                               "[goal: verify command failed \xe2\x80\x94 blocked]\n%s"
                               excerpt))
                     | _ -> ());
                    let goal_blocked_now =
                      match !Par_code_goal.current with
                      | Some g' ->
                        g'.Par_code_goal.status <> Par_code_goal.Active
                      | None -> true
                    in
                    if goal_blocked_now then ()
                    else if !ran_verify && !verify_exit_ok && triggered_by_done
                    then ()
                    else if triggered_by_done || claims_done || step mod 3 = 0
                    then begin
                      let verify_result =
                        if !ran_verify then !verify_output
                        else match goal_verify_cmd with
                        | Some cmd when cmd <> "" ->
                          let full_cmd =
                            "sh -c " ^ Filename.quote cmd ^ " 2>&1"
                          in
                          let ic = Unix.open_process_in full_cmd in
                          let buf = Buffer.create 256 in
                          (try while true do
                             Buffer.add_channel buf ic 256
                           done with End_of_file -> ());
                          let _ = Unix.close_process_in ic in
                          Buffer.contents buf
                        | _ -> ""
                      in
                      (match Par_code_judge.evaluate_goal ~rt
                         ~goal:g.Par_code_goal.objective
                         ?conv:!conv ~verify_result ()
                       with
                       | Ok v when v.goal_met ->
                         Par_code_goal.mark_status Met;
                         Par_code_goal.clear_goal ();
                         Par_code_ui.render_success ui
                           (Printf.sprintf "Goal verified as complete: %s"
                              v.reasoning)
                       | Ok v ->
                         goal_feedback := Some v.reasoning;
                         Par_code_ui.render_warning ui
                           (Printf.sprintf
                              "[judge: goal not yet met \xe2\x80\x94 %s]"
                              v.reasoning)
                       | Error msg ->
                         Par_code_ui.render_warning ui
                           (Printf.sprintf "[judge evaluation failed: %s]"
                              msg))
                    end
                  end
                | _ -> ())
