open Par
open Par_code_chain

let active_goal : Par_code_goal.goal_state =
  { objective = "fix tests"; step_count = 0; max_steps = 50;
    status = Par_code_goal.Active }

let make_state ?(goal = Some active_goal) ?(mode = Par_code_mode.Build)
    ?(auto_chain = true) ?(doom_aborted = false) ?(cancelled = false)
    ?(consecutive_invoke_errors = 0) () : chain_state =
  { goal; mode; auto_chain; doom_aborted; cancelled; consecutive_invoke_errors }

let test_sc_active_build_auto () =
  let s = make_state () in
  Alcotest.(check bool) "active+build+auto" true (should_continue s)

let test_sc_goal_none () =
  let s = make_state ~goal:None () in
  Alcotest.(check bool) "goal None" false (should_continue s)

let test_sc_status_met () =
  let g = { active_goal with status = Met } in
  let s = make_state ~goal:(Some g) () in
  Alcotest.(check bool) "status Met" false (should_continue s)

let test_sc_status_aborted () =
  let g = { active_goal with status = Aborted } in
  let s = make_state ~goal:(Some g) () in
  Alcotest.(check bool) "status Aborted" false (should_continue s)

let test_sc_status_paused () =
  let g = { active_goal with status = Paused } in
  let s = make_state ~goal:(Some g) () in
  Alcotest.(check bool) "status Paused" false (should_continue s)

let test_sc_status_blocked () =
  let g = { active_goal with status = Blocked "x" } in
  let s = make_state ~goal:(Some g) () in
  Alcotest.(check bool) "status Blocked" false (should_continue s)

let test_sc_mode_plan () =
  let s = make_state ~mode:Par_code_mode.Plan () in
  Alcotest.(check bool) "mode Plan" false (should_continue s)

let test_sc_auto_chain_false () =
  let s = make_state ~auto_chain:false () in
  Alcotest.(check bool) "auto_chain false" false (should_continue s)

let test_sc_doom_aborted () =
  let s = make_state ~doom_aborted:true () in
  Alcotest.(check bool) "doom_aborted" false (should_continue s)

let test_sc_cancelled () =
  let s = make_state ~cancelled:true () in
  Alcotest.(check bool) "cancelled" false (should_continue s)

let test_sc_errors_1 () =
  let s = make_state ~consecutive_invoke_errors:1 () in
  Alcotest.(check bool) "errors 1 ok" true (should_continue s)

let test_sc_errors_2 () =
  let s = make_state ~consecutive_invoke_errors:2 () in
  Alcotest.(check bool) "errors 2 blocked" false (should_continue s)

let test_cont_msg_nonempty () =
  let msg = continuation_message () in
  Alcotest.(check bool) "non-empty" true (String.length msg > 0)

let test_cont_msg_contains_goal () =
  let msg = continuation_message () in
  let lower = String.lowercase_ascii msg in
  let contains sub =
    let len_sub = String.length sub in
    let len_s = String.length lower in
    if len_sub > len_s then false
    else
      let rec go i =
        if i > len_s - len_sub then false
        else if String.sub lower i len_sub = sub then true
        else go (i + 1)
      in
      go 0
  in
  Alcotest.(check bool) "contains 'goal'" true (contains "goal")

let test_cancel_user () =
  match cancel_outcome Types.User_cancelled with
  | Pause_goal -> ()
  | Abort_goal _ -> Alcotest.fail "expected Pause_goal"

let test_cancel_guard () =
  match cancel_outcome (Types.Guard_cancelled "loop") with
  | Abort_goal r -> Alcotest.(check string) "reason" "loop" r
  | Pause_goal -> Alcotest.fail "expected Abort_goal"

let test_sigint_request_cancel () =
  match sigint_action ~in_invoke:true ~cancel_pending:false with
  | Request_cancel -> ()
  | _ -> Alcotest.fail "expected Request_cancel"

let test_sigint_force_exit () =
  match sigint_action ~in_invoke:true ~cancel_pending:true with
  | Force_exit -> ()
  | _ -> Alcotest.fail "expected Force_exit"

let test_sigint_exit_now () =
  match sigint_action ~in_invoke:false ~cancel_pending:false with
  | Exit_now -> ()
  | _ -> Alcotest.fail "expected Exit_now"

let test_cie_timeout () =
  Alcotest.(check bool) "Timeout" true (counts_invoke_error Types.Timeout)

let test_cie_cancelled_user () =
  Alcotest.(check bool) "Cancelled User"
    false
    (counts_invoke_error (Types.Cancelled Types.User_cancelled))

let test_cie_cancelled_guard () =
  Alcotest.(check bool) "Cancelled Guard"
    false
    (counts_invoke_error (Types.Cancelled (Types.Guard_cancelled "x")))

let test_cie_external_failure () =
  Alcotest.(check bool) "External_failure"
    true
    (counts_invoke_error (Types.External_failure "something"))

let test_cie_max_iterations () =
  Alcotest.(check bool) "max iterations hit_cap"
    false
    (counts_invoke_error (Types.External_failure "Max iterations exceeded"))

let test_chain_state_construct () =
  let s = make_state ~consecutive_invoke_errors:3 ~doom_aborted:true () in
  Alcotest.(check bool) "doom_aborted field" true s.doom_aborted;
  Alcotest.(check int) "errors field" 3 s.consecutive_invoke_errors;
  Alcotest.(check bool) "auto_chain field" true s.auto_chain;
  Alcotest.(check bool) "cancelled field" false s.cancelled

let () =
  Alcotest.run "par_code_chain"
    [ "should_continue",
      [ Alcotest.test_case "active+build+auto=true" `Quick test_sc_active_build_auto;
        Alcotest.test_case "goal=None -> false" `Quick test_sc_goal_none;
        Alcotest.test_case "status=Met -> false" `Quick test_sc_status_met;
        Alcotest.test_case "status=Aborted -> false" `Quick test_sc_status_aborted;
        Alcotest.test_case "status=Paused -> false" `Quick test_sc_status_paused;
        Alcotest.test_case "status=Blocked -> false" `Quick test_sc_status_blocked;
        Alcotest.test_case "mode=Plan -> false" `Quick test_sc_mode_plan;
        Alcotest.test_case "auto_chain=false -> false" `Quick test_sc_auto_chain_false;
        Alcotest.test_case "doom_aborted -> false" `Quick test_sc_doom_aborted;
        Alcotest.test_case "cancelled -> false" `Quick test_sc_cancelled;
        Alcotest.test_case "errors=1 -> true" `Quick test_sc_errors_1;
        Alcotest.test_case "errors=2 -> false" `Quick test_sc_errors_2 ];
      "continuation_message",
      [ Alcotest.test_case "non-empty" `Quick test_cont_msg_nonempty;
        Alcotest.test_case "contains goal" `Quick test_cont_msg_contains_goal ];
      "cancel_outcome",
      [ Alcotest.test_case "User_cancelled -> Pause_goal" `Quick test_cancel_user;
        Alcotest.test_case "Guard_cancelled -> Abort_goal" `Quick test_cancel_guard ];
      "sigint_action",
      [ Alcotest.test_case "in_invoke,no_pending -> Request_cancel" `Quick test_sigint_request_cancel;
        Alcotest.test_case "in_invoke,pending -> Force_exit" `Quick test_sigint_force_exit;
        Alcotest.test_case "not_in_invoke -> Exit_now" `Quick test_sigint_exit_now ];
      "counts_invoke_error",
      [ Alcotest.test_case "Timeout -> true" `Quick test_cie_timeout;
        Alcotest.test_case "Cancelled User -> false" `Quick test_cie_cancelled_user;
        Alcotest.test_case "Cancelled Guard -> false" `Quick test_cie_cancelled_guard;
        Alcotest.test_case "External_failure -> true" `Quick test_cie_external_failure;
        Alcotest.test_case "max iterations -> false" `Quick test_cie_max_iterations ];
      "chain_state",
      [ Alcotest.test_case "construct record" `Quick test_chain_state_construct ] ]
