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

(* The engine hands the preview over as [Yojson.Safe.to_string output], so
   newlines are escaped and a raw line count says "1 lines" for every read.
   These cases use the shape production actually receives. *)
let read_preview_is_json_text () =
  let p = Yojson.Safe.to_string (`String "one\ntwo\nthree\n") in
  Alcotest.(check string) "three lines" "3 lines"
    (Par_code_tool_summary.of_result ~name:"read" (Some p))

let read_preview_singular () =
  let p = Yojson.Safe.to_string (`String "only\n") in
  Alcotest.(check string) "one line" "1 line"
    (Par_code_tool_summary.of_result ~name:"read" (Some p))

let grep_preview_is_json_list () =
  let p =
    Yojson.Safe.to_string
      (`List [ `String "a.ml:1:x"; `String "b.ml:2:y"; `String "c.ml:3:z" ])
  in
  Alcotest.(check string) "three matches" "3 matches"
    (Par_code_tool_summary.of_result ~name:"grep" (Some p))

let bash_preview_shows_first_output_line () =
  let p =
    Yojson.Safe.to_string
      (`Assoc
         [ ("stdout", `String "total 4\nfile\n")
         ; ("stderr", `String "")
         ; ("exit_code", `Int 0)
         ; ("duration", `Float 0.1)
         ; ("truncated", `Bool false) ])
  in
  Alcotest.(check string) "stdout head" "total 4"
    (Par_code_tool_summary.of_result ~name:"bash" (Some p))

let bash_preview_shows_failure () =
  let p =
    Yojson.Safe.to_string
      (`Assoc
         [ ("stdout", `String "")
         ; ("stderr", `String "boom\n")
         ; ("exit_code", `Int 2) ])
  in
  Alcotest.(check string) "exit and stderr" "exit 2 · boom"
    (Par_code_tool_summary.of_result ~name:"bash" (Some p))

let apply_patch_preview_summarises_counts () =
  let p =
    Yojson.Safe.to_string
      (`Assoc
         [ ("files_changed", `Int 1)
         ; ("hunks_applied", `Int 2)
         ; ("insertions", `Int 3)
         ; ("deletions", `Int 1)
         ; ("skipped_binary", `List [])
         ; ("dry_run", `Bool false) ])
  in
  Alcotest.(check string) "file and diff" "1 file · +3/-1"
    (Par_code_tool_summary.of_result ~name:"apply_patch" (Some p))

let truncated_preview_still_counts () =
  (* Longer than 500 bytes, the engine cuts the JSON mid-string and appends
     "... (N bytes total)". The line count can only cover what survived, and
     the summary says so. *)
  let p = "{\"content\":\"a\\nb\\nc\\nd... (900 bytes total)" in
  Alcotest.(check string) "four and more" "4+ lines"
    (Par_code_tool_summary.of_result ~name:"read" (Some p))

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
        ; Alcotest.test_case "read_json" `Quick read_preview_is_json_text
        ; Alcotest.test_case "read_singular" `Quick read_preview_singular
        ; Alcotest.test_case "grep_json" `Quick grep_preview_is_json_list
        ; Alcotest.test_case "bash_stdout" `Quick
            bash_preview_shows_first_output_line
        ; Alcotest.test_case "bash_failure" `Quick
            bash_preview_shows_failure
        ; Alcotest.test_case "apply_patch" `Quick
            apply_patch_preview_summarises_counts
        ; Alcotest.test_case "truncated" `Quick truncated_preview_still_counts
        ] )
    ; ( "line",
        [ Alcotest.test_case "composition" `Quick line_shows_what_and_how_long
        ; Alcotest.test_case "seconds" `Quick line_marks_seconds
        ] )
    ]
