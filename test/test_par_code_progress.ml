open Par_code_progress

let test_no_progress_basic () =
  Alcotest.(check bool) "0 tools + no done + short text" true
    (no_progress ~tool_calls:0 ~goal_done:false ~text_len:100)

let test_no_progress_with_tools () =
  Alcotest.(check bool) "tools called" false
    (no_progress ~tool_calls:3 ~goal_done:false ~text_len:100)

let test_no_progress_with_goal_done () =
  Alcotest.(check bool) "goal_done called" false
    (no_progress ~tool_calls:0 ~goal_done:true ~text_len:100)

let test_no_progress_long_text_200 () =
  Alcotest.(check bool) "200 chars" false
    (no_progress ~tool_calls:0 ~goal_done:false ~text_len:200)

let test_no_progress_long_text_201 () =
  Alcotest.(check bool) "201 chars" false
    (no_progress ~tool_calls:0 ~goal_done:false ~text_len:201)

let test_no_progress_text_199 () =
  Alcotest.(check bool) "199 chars (still no progress)" true
    (no_progress ~tool_calls:0 ~goal_done:false ~text_len:199)

let test_no_progress_zero () =
  Alcotest.(check bool) "all zero" true
    (no_progress ~tool_calls:0 ~goal_done:false ~text_len:0)

let test_no_progress_combined () =
  Alcotest.(check bool) "tools + short text" false
    (no_progress ~tool_calls:1 ~goal_done:false ~text_len:50);
  Alcotest.(check bool) "no tools + done + short" false
    (no_progress ~tool_calls:0 ~goal_done:true ~text_len:50);
  Alcotest.(check bool) "tools + done + short" false
    (no_progress ~tool_calls:2 ~goal_done:true ~text_len:50)

let test_claims_chinese_basic () =
  Alcotest.(check bool) "已完成" true
    (claims_completion "已完成所有任务");
  Alcotest.(check bool) "完成" true
    (claims_completion "任务完成");
  Alcotest.(check bool) "完成了" true
    (claims_completion "完成了")

let test_claims_english_basic () =
  Alcotest.(check bool) "done" true
    (claims_completion "Task is done");
  Alcotest.(check bool) "complete" true
    (claims_completion "All tests complete");
  Alcotest.(check bool) "completed" true
    (claims_completion "Work completed");
  Alcotest.(check bool) "finished" true
    (claims_completion "Finished the work")

let test_claims_chinese_negation () =
  Alcotest.(check bool) "还没有完成" false
    (claims_completion "还没有完成");
  Alcotest.(check bool) "没有完成" false
    (claims_completion "没有完成");
  Alcotest.(check bool) "未完成" false
    (claims_completion "未完成");
  Alcotest.(check bool) "还没完成" false
    (claims_completion "还没完成")

let test_claims_english_negation () =
  Alcotest.(check bool) "not done" false
    (claims_completion "Not done yet");
  Alcotest.(check bool) "not complete" false
    (claims_completion "Not complete");
  Alcotest.(check bool) "incomplete" false
    (claims_completion "The task is incomplete");
  Alcotest.(check bool) "unfinished" false
    (claims_completion "Work is unfinished")

let test_claims_no_keyword () =
  Alcotest.(check bool) "progress note" false
    (claims_completion "I'm analyzing the codebase structure");
  Alcotest.(check bool) "question" false
    (claims_completion "What files should I modify?");
  Alcotest.(check bool) "empty" false
    (claims_completion "")

let () =
  Alcotest.run "par_progress"
    [ "no_progress", [
        Alcotest.test_case "basic no progress"     `Quick test_no_progress_basic;
        Alcotest.test_case "tools called"           `Quick test_no_progress_with_tools;
        Alcotest.test_case "goal_done called"       `Quick test_no_progress_with_goal_done;
        Alcotest.test_case "text 200 chars"         `Quick test_no_progress_long_text_200;
        Alcotest.test_case "text 201 chars"         `Quick test_no_progress_long_text_201;
        Alcotest.test_case "text 199 chars"         `Quick test_no_progress_text_199;
        Alcotest.test_case "all zero"               `Quick test_no_progress_zero;
        Alcotest.test_case "combined signals"       `Quick test_no_progress_combined;
      ];
      "claims_completion", [
        Alcotest.test_case "chinese basic"          `Quick test_claims_chinese_basic;
        Alcotest.test_case "english basic"          `Quick test_claims_english_basic;
        Alcotest.test_case "chinese negation"       `Quick test_claims_chinese_negation;
        Alcotest.test_case "english negation"       `Quick test_claims_english_negation;
        Alcotest.test_case "no keyword"             `Quick test_claims_no_keyword;
      ];
    ]
