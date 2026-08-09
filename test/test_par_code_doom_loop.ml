open Par_code_doom_loop

let dummy = `Assoc [("args", `String "dummy")]

let test_empty_is_continue () =
  let d = create () in
  let r = record_call d ~tool_name:"read" ~args:dummy in
  Alcotest.(check bool) "first call continues" true (r = Continue)

let test_different_calls_continue () =
  let d = create () in
  let _ = record_call d ~tool_name:"read" ~args:dummy in
  let r = record_call d ~tool_name:"grep" ~args:dummy in
  Alcotest.(check bool) "different tool continues" true (r = Continue)

let test_same_tool_different_args_continue () =
  let d = create () in
  let a1 = `Assoc [("path", `String "a")] in
  let a2 = `Assoc [("path", `String "b")] in
  let _ = record_call d ~tool_name:"read" ~args:a1 in
  let r = record_call d ~tool_name:"read" ~args:a2 in
  Alcotest.(check bool) "same tool diff args continues" true (r = Continue)

let test_three_identical_nudge () =
  let d = create () in
  let _ = record_call d ~tool_name:"read" ~args:dummy in
  let _ = record_call d ~tool_name:"read" ~args:dummy in
  let r = record_call d ~tool_name:"read" ~args:dummy in
  Alcotest.(check bool) "3rd identical nudges" true
    (match r with Nudge _ -> true | _ -> false)

let test_fourth_continues_after_nudge () =
  let d = create () in
  let _ = record_call d ~tool_name:"read" ~args:dummy in
  let _ = record_call d ~tool_name:"read" ~args:dummy in
  let _ = record_call d ~tool_name:"read" ~args:dummy in
  let r = record_call d ~tool_name:"read" ~args:dummy in
  Alcotest.(check bool) "4th continues (nudge already sent)" true (r = Continue)

let test_six_identical_force_judge () =
  let d = create () in
  for _ = 1 to 5 do
    ignore (record_call d ~tool_name:"read" ~args:dummy)
  done;
  let r = record_call d ~tool_name:"read" ~args:dummy in
  Alcotest.(check bool) "6th forces judge" true
    (match r with Force_judge _ -> true | _ -> false)

let test_nine_identical_abort () =
  let d = create () in
  for _ = 1 to 8 do
    ignore (record_call d ~tool_name:"read" ~args:dummy)
  done;
  let r = record_call d ~tool_name:"read" ~args:dummy in
  Alcotest.(check bool) "9th aborts" true
    (match r with Abort _ -> true | _ -> false)

let test_different_call_resets_streak () =
  let d = create () in
  let _ = record_call d ~tool_name:"read" ~args:dummy in
  let _ = record_call d ~tool_name:"read" ~args:dummy in
  let _ = record_call d ~tool_name:"grep" ~args:dummy in
  let r = record_call d ~tool_name:"read" ~args:dummy in
  Alcotest.(check bool) "streak resets after different call" true (r = Continue)

let test_custom_threshold_2 () =
  let d = create ~threshold:2 () in
  let _ = record_call d ~tool_name:"read" ~args:dummy in
  let r = record_call d ~tool_name:"read" ~args:dummy in
  Alcotest.(check bool) "threshold 2 nudges at 2" true
    (match r with Nudge _ -> true | _ -> false)

let test_streak_count_tracks () =
  let d = create () in
  Alcotest.(check int) "initial 0" 0 (streak_count d);
  ignore (record_call d ~tool_name:"read" ~args:dummy);
  Alcotest.(check int) "after 1" 1 (streak_count d);
  ignore (record_call d ~tool_name:"read" ~args:dummy);
  Alcotest.(check int) "after 2" 2 (streak_count d)

let test_nudge_fires_again_after_reset () =
  let d = create () in
  for _ = 1 to 3 do
    ignore (record_call d ~tool_name:"read" ~args:dummy)
  done;
  ignore (record_call d ~tool_name:"grep" ~args:dummy);
  let _ = record_call d ~tool_name:"read" ~args:dummy in
  let _ = record_call d ~tool_name:"read" ~args:dummy in
  let r = record_call d ~tool_name:"read" ~args:dummy in
  Alcotest.(check bool) "new streak nudges again" true
    (match r with Nudge _ -> true | _ -> false)

let () =
  Alcotest.run "par_code_doom_loop"
    [ "basic",
      [ Alcotest.test_case "first call continues" `Quick test_empty_is_continue;
        Alcotest.test_case "different calls continue" `Quick test_different_calls_continue;
        Alcotest.test_case "same tool diff args continue" `Quick test_same_tool_different_args_continue ];
      "escalation",
      [ Alcotest.test_case "3 identical nudges" `Quick test_three_identical_nudge;
        Alcotest.test_case "4th continues after nudge" `Quick test_fourth_continues_after_nudge;
        Alcotest.test_case "6 identical forces judge" `Quick test_six_identical_force_judge;
        Alcotest.test_case "9 identical aborts" `Quick test_nine_identical_abort ];
      "reset",
      [ Alcotest.test_case "different call resets" `Quick test_different_call_resets_streak;
        Alcotest.test_case "nudge fires again after reset" `Quick test_nudge_fires_again_after_reset ];
      "config",
      [ Alcotest.test_case "custom threshold 2" `Quick test_custom_threshold_2;
        Alcotest.test_case "streak count tracks" `Quick test_streak_count_tracks ] ]
