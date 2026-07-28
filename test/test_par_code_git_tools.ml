let json_eq = Alcotest.testable
  (fun fmt j -> Format.pp_print_string fmt (Yojson.Safe.pretty_to_string j))
  (fun a b -> Yojson.Safe.to_string a = Yojson.Safe.to_string b)

let test_parse_status_clean () =
  let output = "## main\n" in
  let result = Par_code_git_tools.parse_git_status output in
  let expected = `Assoc [("branch", `String "main"); ("files", `List [])] in
  Alcotest.check json_eq "clean status" expected result

let test_parse_status_with_files () =
  let output = String.concat "\n"
    [ "## main"
    ; " M lib/foo.ml"
    ; "A  new_file.ml"
    ; "D  deleted.ml"
    ; "?? untracked.txt"
    ; ""
    ] in
  let result = Par_code_git_tools.parse_git_status output in
  let expected = `Assoc
    [ ("branch", `String "main")
    ; ("files", `List
        [ `Assoc [("path", `String "lib/foo.ml");     ("status", `String " M")]
        ; `Assoc [("path", `String "new_file.ml");    ("status", `String "A ")]
        ; `Assoc [("path", `String "deleted.ml");     ("status", `String "D ")]
        ; `Assoc [("path", `String "untracked.txt");  ("status", `String "??")]
        ])
    ] in
  Alcotest.check json_eq "status with files" expected result

let test_parse_status_with_tracking () =
  let output = "## main...origin/main [ahead 3]\n" in
  let result = Par_code_git_tools.parse_git_status output in
  let branch = Yojson.Safe.Util.(member "branch" result |> to_string) in
  Alcotest.(check string) "branch with tracking" "main" branch

let test_parse_status_empty () =
  let result = Par_code_git_tools.parse_git_status "" in
  let expected = `Assoc [("branch", `String ""); ("files", `List [])] in
  Alcotest.check json_eq "empty status" expected result

let test_parse_status_dotted_branch () =
  let output = "## feature/v0.5.1\n" in
  let result = Par_code_git_tools.parse_git_status output in
  let branch = Yojson.Safe.Util.(member "branch" result |> to_string) in
  Alcotest.(check string) "dotted branch" "feature/v0.5.1" branch

let test_parse_status_dotted_with_tracking () =
  let output = "## release/1.2.3...origin/release/1.2.3 [ahead 1]\n" in
  let result = Par_code_git_tools.parse_git_status output in
  let branch = Yojson.Safe.Util.(member "branch" result |> to_string) in
  Alcotest.(check string) "dotted tracking" "release/1.2.3" branch

let test_parse_log_multiple () =
  let output = String.concat "\n"
    [ "abc1234|feat: add feature|2026-07-28"
    ; "def5678|fix: bug fix|2026-07-27"
    ; ""
    ] in
  let result = Par_code_git_tools.parse_git_log output in
  let commits = Yojson.Safe.Util.(member "commits" result |> to_list) in
  Alcotest.(check int) "commit count" 2 (List.length commits);
  let first = List.nth commits 0 in
  Alcotest.(check string) "hash 0" "abc1234"
    Yojson.Safe.Util.(member "hash" first |> to_string);
  Alcotest.(check string) "msg 0" "feat: add feature"
    Yojson.Safe.Util.(member "message" first |> to_string);
  Alcotest.(check string) "date 0" "2026-07-28"
    Yojson.Safe.Util.(member "date" first |> to_string);
  let second = List.nth commits 1 in
  Alcotest.(check string) "hash 1" "def5678"
    Yojson.Safe.Util.(member "hash" second |> to_string);
  Alcotest.(check string) "msg 1" "fix: bug fix"
    Yojson.Safe.Util.(member "message" second |> to_string);
  Alcotest.(check string) "date 1" "2026-07-27"
    Yojson.Safe.Util.(member "date" second |> to_string)

let test_parse_log_empty () =
  let result = Par_code_git_tools.parse_git_log "" in
  let expected = `Assoc [("commits", `List [])] in
  Alcotest.check json_eq "empty log" expected result

let test_parse_log_single () =
  let output = "abc1234|feat: add feature|2026-07-28\n" in
  let result = Par_code_git_tools.parse_git_log output in
  let commits = Yojson.Safe.Util.(member "commits" result |> to_list) in
  Alcotest.(check int) "single commit" 1 (List.length commits);
  let first = List.nth commits 0 in
  Alcotest.(check string) "hash" "abc1234"
    Yojson.Safe.Util.(member "hash" first |> to_string);
  Alcotest.(check string) "message" "feat: add feature"
    Yojson.Safe.Util.(member "message" first |> to_string);
  Alcotest.(check string) "date" "2026-07-28"
    Yojson.Safe.Util.(member "date" first |> to_string)

let test_parse_log_pipe_in_message () =
  let output = "abc|msg with | pipe|2026-07-28\n" in
  let result = Par_code_git_tools.parse_git_log output in
  let commits = Yojson.Safe.Util.(member "commits" result |> to_list) in
  Alcotest.(check int) "one commit" 1 (List.length commits);
  let first = List.nth commits 0 in
  Alcotest.(check string) "hash" "abc"
    Yojson.Safe.Util.(member "hash" first |> to_string);
  Alcotest.(check string) "message with pipe" "msg with | pipe"
    Yojson.Safe.Util.(member "message" first |> to_string);
  Alcotest.(check string) "date" "2026-07-28"
    Yojson.Safe.Util.(member "date" first |> to_string)

let () =
  Alcotest.run "par_git_tools"
    [ "parse_status", [
        Alcotest.test_case "clean"                `Quick test_parse_status_clean;
        Alcotest.test_case "with_files"           `Quick test_parse_status_with_files;
        Alcotest.test_case "with_tracking"        `Quick test_parse_status_with_tracking;
        Alcotest.test_case "empty"                `Quick test_parse_status_empty;
        Alcotest.test_case "dotted_branch"        `Quick test_parse_status_dotted_branch;
        Alcotest.test_case "dotted_with_tracking" `Quick test_parse_status_dotted_with_tracking;
      ];
      "parse_log", [
        Alcotest.test_case "multiple"        `Quick test_parse_log_multiple;
        Alcotest.test_case "empty"           `Quick test_parse_log_empty;
        Alcotest.test_case "single"          `Quick test_parse_log_single;
        Alcotest.test_case "pipe_in_message" `Quick test_parse_log_pipe_in_message;
      ];
    ]
