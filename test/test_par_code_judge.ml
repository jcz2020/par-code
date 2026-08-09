open Par_code_judge

let test_parse_well_formed_met () =
  let v = parse_verdict {|{"goal_met": true, "reasoning": "All tests pass."}|} in
  Alcotest.(check bool) "goal_met" true v.goal_met;
  Alcotest.(check string) "reasoning" "All tests pass." v.reasoning

let test_parse_well_formed_not_met () =
  let v = parse_verdict {|{"goal_met": false, "reasoning": "Build still fails."}|} in
  Alcotest.(check bool) "goal_met" false v.goal_met;
  Alcotest.(check string) "reasoning" "Build still fails." v.reasoning

let test_parse_with_surrounding_text () =
  let v = parse_verdict "Here is my evaluation:\n{\"goal_met\": true, \"reasoning\": \"Done.\"}\nThat's all." in
  Alcotest.(check bool) "goal_met" true v.goal_met

let test_parse_malformed_json () =
  let v = parse_verdict "This is not JSON at all" in
  Alcotest.(check bool) "malformed defaults to not met" false v.goal_met

let test_parse_empty_string () =
  let v = parse_verdict "" in
  Alcotest.(check bool) "empty defaults to not met" false v.goal_met

let test_parse_missing_reasoning () =
  let v = parse_verdict {|{"goal_met": true}|} in
  Alcotest.(check bool) "goal_met" true v.goal_met;
  Alcotest.(check string) "reasoning empty" "" v.reasoning

let test_parse_bool_as_string () =
  let v = parse_verdict {|{"goal_met": "true", "reasoning": "ok"}|} in
  Alcotest.(check bool) "string true defaults to false" false v.goal_met

let test_build_message_includes_goal () =
  let msg = build_judge_message ~goal:"fix the bug" ~verify_result:"" ~conv_summary:"did stuff" in
  Alcotest.(check bool) "includes goal" true (String.contains msg 'f')

let test_build_message_with_verify_result () =
  let msg = build_judge_message ~goal:"test" ~verify_result:"BUILD FAILED" ~conv_summary:"worked" in
  let has_failed = try ignore (Str.search_forward (Str.regexp "BUILD FAILED") msg 0); true with _ -> false in
  Alcotest.(check bool) "includes verify result" true has_failed

let test_build_message_without_verify_result () =
  let msg = build_judge_message ~goal:"test" ~verify_result:"" ~conv_summary:"worked" in
  let has_no_verif = try ignore (Str.search_forward (Str.regexp "No verification command") msg 0); true with _ -> false in
  Alcotest.(check bool) "mentions no verification" true has_no_verif

let () =
  Alcotest.run "par_code_judge"
    [ "parse_verdict",
      [ Alcotest.test_case "well-formed met" `Quick test_parse_well_formed_met;
        Alcotest.test_case "well-formed not met" `Quick test_parse_well_formed_not_met;
        Alcotest.test_case "surrounding text" `Quick test_parse_with_surrounding_text;
        Alcotest.test_case "malformed json" `Quick test_parse_malformed_json;
        Alcotest.test_case "empty string" `Quick test_parse_empty_string;
        Alcotest.test_case "missing reasoning" `Quick test_parse_missing_reasoning;
        Alcotest.test_case "bool as string" `Quick test_parse_bool_as_string ];
      "build_message",
      [ Alcotest.test_case "includes goal" `Quick test_build_message_includes_goal;
        Alcotest.test_case "with verify result" `Quick test_build_message_with_verify_result;
        Alcotest.test_case "without verify result" `Quick test_build_message_without_verify_result ] ]
