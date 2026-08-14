open Par_code_doom_loop

let make_evt ?(args = `Null) ?(output = None) ?(failed = false) tool_name =
  { tool_name; args_json = args; output; failed }

let make_bash_evt ?(output = Some "error") cmd =
  { tool_name = "bash"; args_json = `String cmd; output; failed = true }

let test_first_call_is_continue () =
  let d = create () in
  let r = record d (make_evt "read") in
  Alcotest.(check bool) "first call continues" true (r = Continue)

let test_different_tools_continue () =
  let d = create () in
  let _ = record d (make_evt "read") in
  let r = record d (make_evt "grep") in
  Alcotest.(check bool) "different tool continues" true (r = Continue)

let test_bash_retry_nudge () =
  let d = create ~bash_retries:3 ~edit_matches:100 ~action_streak:100 () in
  let _ = record d (make_bash_evt "pytest") in
  let _ = record d (make_bash_evt "pytest") in
  let r = record d (make_bash_evt "pytest") in
  Alcotest.(check bool) "3rd bash failure nudges" true
    (match r with Nudge _ -> true | _ -> false)

let test_bash_retry_abort () =
  let d = create ~bash_retries:3 ~edit_matches:100 ~action_streak:100 () in
  for _ = 1 to 8 do
    ignore (record d (make_bash_evt "pytest"))
  done;
  let r = record d (make_bash_evt "pytest") in
  Alcotest.(check bool) "9th bash failure aborts (3×threshold)" true
    (match r with Abort _ -> true | _ -> false)

let test_normalization_ignores_tmp_path_diffs () =
  let d = create ~bash_retries:3 ~edit_matches:100 ~action_streak:100 () in
  let _ = record d (make_bash_evt "pytest /tmp/abc123/result.log") in
  let _ = record d (make_bash_evt "pytest /tmp/xyz789/result.log") in
  let r = record d (make_bash_evt "pytest /tmp/aaa000/result.log") in
  Alcotest.(check bool) "different tmp paths but same normalized → nudge" true
    (match r with Nudge _ -> true | _ -> false)

let test_normalization_ignores_seed_diffs () =
  let d = create ~bash_retries:3 ~edit_matches:100 ~action_streak:100 () in
  let _ = record d (make_bash_evt "pytest --seed=42") in
  let _ = record d (make_bash_evt "pytest --seed=99") in
  let r = record d (make_bash_evt "pytest --seed=7") in
  Alcotest.(check bool) "different seeds but same normalized → nudge" true
    (match r with Nudge _ -> true | _ -> false)

let test_edit_repeat_nudge () =
  let d = create ~bash_retries:100 ~edit_matches:5 ~action_streak:100 () in
  let text = "line1\nline2\nline3\nline4\nline5" in
  for _ = 1 to 3 do
    ignore (record d (make_evt "edit" ~output:(Some text)))
  done;
  let r = record d (make_evt "edit" ~output:(Some text)) in
  Alcotest.(check bool) "4th similar edit nudges (cumulative ≥5)" true
    (match r with Nudge _ -> true | _ -> false)

let test_edit_repeat_force_judge () =
  let d = create ~bash_retries:100 ~edit_matches:5 ~action_streak:100 () in
  let text = "line1\nline2\nline3\nline4\nline5" in
  for _ = 1 to 4 do
    ignore (record d (make_evt "edit" ~output:(Some text)))
  done;
  let r = record d (make_evt "edit" ~output:(Some text)) in
  Alcotest.(check bool) "5th similar edit forces judge (cumulative ≥10)" true
    (match r with Force_judge _ -> true | _ -> false)

let test_ab_ba_pattern_detected () =
  let d = create ~bash_retries:100 ~edit_matches:5 ~action_streak:100 () in
  let text_a = "alpha\nbeta\ngamma\ndelta\nepsilon" in
  let text_b = "alpha\nbeta\ngamma\ndelta\nzeta" in
  let _ = record d (make_evt "edit" ~output:(Some text_a)) in
  let _ = record d (make_evt "edit" ~output:(Some text_b)) in
  let _ = record d (make_evt "edit" ~output:(Some text_a)) in
  let _ = record d (make_evt "edit" ~output:(Some text_b)) in
  let _ = record d (make_evt "edit" ~output:(Some text_a)) in
  let r = record d (make_evt "edit" ~output:(Some text_b)) in
  Alcotest.(check bool) "A-B-A-B alternating pattern detected" true
    (match r with Nudge _ | Force_judge _ | Abort _ -> true | Continue -> false)

let test_action_streak_nudge () =
  let d = create ~bash_retries:100 ~edit_matches:100 ~action_streak:4 () in
  for _ = 1 to 3 do
    ignore (record d (make_evt "delegate"))
  done;
  let r = record d (make_evt "delegate") in
  Alcotest.(check bool) "4 consecutive other nudges" true
    (match r with Nudge _ -> true | _ -> false)

let test_info_resets_action_streak () =
  let d = create ~bash_retries:100 ~edit_matches:100 ~action_streak:4 () in
  for _ = 1 to 3 do
    ignore (record d (make_evt "delegate"))
  done;
  ignore (record d (make_evt "read"));
  let r = record d (make_evt "delegate") in
  Alcotest.(check bool) "info resets streak" true (r = Continue)

let test_custom_thresholds () =
  let d = create ~bash_retries:2 ~edit_matches:1 ~action_streak:3 () in
  let _ = record d (make_bash_evt "pytest") in
  let r = record d (make_bash_evt "pytest") in
  Alcotest.(check bool) "bash_retries=2 nudges at 2" true
    (match r with Nudge _ -> true | _ -> false)

let test_action_count_tracks () =
  let d = create ~bash_retries:100 ~edit_matches:100 ~action_streak:100 () in
  Alcotest.(check int) "initial 0" 0 (action_count d);
  ignore (record d (make_evt "delegate"));
  Alcotest.(check int) "after 1" 1 (action_count d);
  ignore (record d (make_evt "delegate"));
  Alcotest.(check int) "after 2" 2 (action_count d)

let test_incident_write_parse () =
  let incident_path = write_incident
    ~signal:"bash_retry"
    ~reason:"3 consecutive failures"
    ~normalized:"pytest <TMP>"
    ~original:"pytest /tmp/abc" in
  Alcotest.(check bool) "file exists" true (Sys.file_exists incident_path);
  let ic = open_in incident_path in
  let n = in_channel_length ic in
  let buf = Bytes.create n in
  really_input ic buf 0 n;
  close_in ic;
  let json = Yojson.Safe.from_string (Bytes.to_string buf) in
  let open Yojson.Safe.Util in
  let signal = json |> member "signal" |> to_string in
  Alcotest.(check string) "signal" "bash_retry" signal;
  let norm = json |> member "normalized_input" |> to_string in
  Alcotest.(check string) "normalized" "pytest <TMP>" norm;
  let ts = json |> member "timestamp_iso" |> to_string in
  Alcotest.(check bool) "timestamp non-empty" true (String.length ts > 0);
  (try Sys.remove incident_path with Sys_error _ -> ())

let () =
  Alcotest.run "par_code_doom_loop"
    [ "basic",
      [ Alcotest.test_case "first call continues" `Quick test_first_call_is_continue;
        Alcotest.test_case "different tools continue" `Quick test_different_tools_continue ];
      "bash_retry",
      [ Alcotest.test_case "3 failures nudges" `Quick test_bash_retry_nudge;
        Alcotest.test_case "6 failures aborts" `Quick test_bash_retry_abort;
        Alcotest.test_case "tmp path normalization" `Quick test_normalization_ignores_tmp_path_diffs;
        Alcotest.test_case "seed normalization" `Quick test_normalization_ignores_seed_diffs ];
      "edit_repeat",
      [ Alcotest.test_case "similar edit nudges" `Quick test_edit_repeat_nudge;
        Alcotest.test_case "cumulative matches forces judge" `Quick test_edit_repeat_force_judge;
        Alcotest.test_case "A-B-A-B pattern detected" `Quick test_ab_ba_pattern_detected ];
      "action_streak",
      [ Alcotest.test_case "4 same-kind nudges" `Quick test_action_streak_nudge;
        Alcotest.test_case "info resets streak" `Quick test_info_resets_action_streak ];
      "config_and_state",
      [ Alcotest.test_case "custom thresholds" `Quick test_custom_thresholds;
        Alcotest.test_case "action count tracks" `Quick test_action_count_tracks ];
      "incident",
      [ Alcotest.test_case "write and parse incident" `Quick test_incident_write_parse ] ]
