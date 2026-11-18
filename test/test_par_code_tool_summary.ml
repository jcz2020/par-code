(* par_code_tool_summary — the one-line description of a tool call. *)

let json s = Yojson.Safe.from_string s

let read_summary () =
  let args = json {|{"path":"lib/dune"}|} in
  Alcotest.(check string) "path" "lib/dune"
    (Par_code_tool_summary.of_arguments ~name:"read" args)

let grep_summary_includes_scope () =
  let args = json {|{"pattern":"TODO","path":"lib"}|} in
  Alcotest.(check string) "pattern in path" "TODO in lib"
    (Par_code_tool_summary.of_arguments ~name:"grep" args)

let bash_summary_uses_command () =
  let args = json {|{"command":"dune build"}|} in
  Alcotest.(check string) "command" "dune build"
    (Par_code_tool_summary.of_arguments ~name:"bash" args)

let bash_summary_falls_back_to_argv () =
  let args = json {|{"argv":["git","status"]}|} in
  Alcotest.(check string) "argv joined" "git status"
    (Par_code_tool_summary.of_arguments ~name:"bash" args)

let result_counts_lines () =
  Alcotest.(check string) "three lines" "3 lines"
    (Par_code_tool_summary.of_result ~name:"read" (Some "a\nb\nc\n"))

let result_counts_matches () =
  Alcotest.(check string) "two matches" "2 matches"
    (Par_code_tool_summary.of_result ~name:"grep" (Some "a:1\nb:2"))

let line_shows_what_and_how_long () =
  let args = json {|{"path":"lib/dune"}|} in
  Alcotest.(check string) "composition" "read · lib/dune · 12 lines · 3.0ms"
    (Par_code_tool_summary.line ~name:"read" ~args:(Some args)
       ~preview:(Some "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n")
       ~duration_ms:(Some 3.0) ~failed:false)

let line_marks_seconds () =
  Alcotest.(check string) "seconds" "bash · make · ok · 2.5s"
    (Par_code_tool_summary.line ~name:"bash"
       ~args:(Some (json {|{"command":"make"}|})) ~preview:(Some "ok")
       ~duration_ms:(Some 2500.0) ~failed:false)

let () =
  Alcotest.run "par_tool_summary"
    [ ( "arguments",
        [ Alcotest.test_case "read" `Quick read_summary
        ; Alcotest.test_case "grep" `Quick grep_summary_includes_scope
        ; Alcotest.test_case "bash_command" `Quick bash_summary_uses_command
        ; Alcotest.test_case "bash_argv" `Quick bash_summary_falls_back_to_argv
        ] )
    ; ( "result",
        [ Alcotest.test_case "lines" `Quick result_counts_lines
        ; Alcotest.test_case "matches" `Quick result_counts_matches
        ] )
    ; ( "line",
        [ Alcotest.test_case "composition" `Quick line_shows_what_and_how_long
        ; Alcotest.test_case "seconds" `Quick line_marks_seconds
        ] )
    ]
