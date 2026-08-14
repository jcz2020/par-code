let test_matches_exact_prefix () =
  let patterns = ["pytest"] in
  Alcotest.(check bool) "exact prefix match" true
    (Par_code_approvals.matches patterns "pytest -q tests/");
  Alcotest.(check bool) "exact prefix no match" false
    (Par_code_approvals.matches patterns "python -m pytest")

let test_matches_star_suffix () =
  let patterns = ["pytest *"] in
  Alcotest.(check bool) "star matches anything after" true
    (Par_code_approvals.matches patterns "pytest -q tests/");
  Alcotest.(check bool) "star does not match bare prefix" false
    (Par_code_approvals.matches patterns "pytest");
  Alcotest.(check bool) "star no match different prefix" false
    (Par_code_approvals.matches patterns "python -m pytest")

let test_matches_no_match () =
  let patterns = ["npm test"; "cargo *"] in
  Alcotest.(check bool) "no match" false
    (Par_code_approvals.matches patterns "pytest -q");
  Alcotest.(check bool) "partial not prefix" false
    (Par_code_approvals.matches patterns "np")

let test_matches_empty_patterns () =
  Alcotest.(check bool) "empty patterns" false
    (Par_code_approvals.matches [] "anything")

let test_add_load_roundtrip () =
  let orig = Sys.getcwd () in
  let tmp_dir = Filename.temp_file "approvals_test" "" in
  Sys.remove tmp_dir;
  Unix.mkdir tmp_dir 0o755;
  Unix.chdir tmp_dir;
  Par_code_approvals.add "pytest *";
  Par_code_approvals.add "npm test";
  let loaded = Par_code_approvals.load () in
  Alcotest.(check int) "two patterns" 2 (List.length loaded);
  Alcotest.(check (list string)) "patterns match"
    ["pytest *"; "npm test"] loaded;
  Par_code_approvals.add "pytest *";
  let loaded2 = Par_code_approvals.load () in
  Alcotest.(check int) "no duplicate" 2 (List.length loaded2);
  Unix.chdir orig

let test_load_missing_file () =
  let orig = Sys.getcwd () in
  let tmp_dir = Filename.temp_file "approvals_test" "" in
  Sys.remove tmp_dir;
  (try Unix.mkdir tmp_dir 0o755 with _ -> ());
  Unix.chdir tmp_dir;
  let loaded = Par_code_approvals.load () in
  Alcotest.(check int) "missing file returns empty" 0 (List.length loaded);
  Unix.chdir orig

let test_classify_in_project_relative () =
  match Par.Workspace.of_cwd () with
  | Error _ -> Alcotest.fail "of_cwd failed"
  | Ok ws ->
    let r = Par_code_approvals.classify ws ~argv:["ls"; "lib/foo.ml"] in
    Alcotest.(check bool) "relative path is In_project" true
      (r = Par_code_approvals.In_project)

let test_classify_in_project_no_paths () =
  match Par.Workspace.of_cwd () with
  | Error _ -> Alcotest.fail "of_cwd failed"
  | Ok ws ->
    let r = Par_code_approvals.classify ws ~argv:["pytest"; "-q"] in
    Alcotest.(check bool) "no paths is In_project" true
      (r = Par_code_approvals.In_project)

let test_classify_external_path () =
  match Par.Workspace.of_cwd () with
  | Error _ -> Alcotest.fail "of_cwd failed"
  | Ok ws ->
    let r = Par_code_approvals.classify ws ~argv:["ls"; "/tmp/definitely-outside-par-code-xyz"] in
    (match r with
     | Par_code_approvals.External_path ps ->
       Alcotest.(check int) "one external path" 1 (List.length ps)
     | other ->
       Alcotest.fail (Printf.sprintf "expected External_path, got %s"
         (match other with In_project -> "In_project" | Unknown -> "Unknown" | Sensitive _ -> "Sensitive" | External_path _ -> "External_path")))

let test_classify_sensitive () =
  (* /etc/passwd is External_path when workspace is CWD (not under root).
     To test Sensitive: use a workspace rooted at HOME; $HOME/.ssh/test
     IS under root AND hits the sensitive prefix → Permission_denied. *)
  let home = try Sys.getenv "HOME" with Not_found -> "/" in
  match Par.Workspace.of_dir home with
  | Error _ -> Alcotest.fail "of_dir HOME failed"
  | Ok ws ->
    let ssh_path = Filename.concat (Filename.concat home ".ssh") "test_key" in
    let r = Par_code_approvals.classify ws ~argv:["cat"; ssh_path] in
    (match r with
     | Par_code_approvals.Sensitive ps ->
       Alcotest.(check int) "one sensitive path" 1 (List.length ps)
     | other ->
       Alcotest.fail (Printf.sprintf "expected Sensitive for %s, got %s" ssh_path
         (match other with In_project -> "In_project" | Unknown -> "Unknown" | Sensitive _ -> "Sensitive" | External_path _ -> "External_path")))

let test_classify_etc_external () =
  match Par.Workspace.of_cwd () with
  | Error _ -> Alcotest.fail "of_cwd failed"
  | Ok ws ->
    let r = Par_code_approvals.classify ws ~argv:["cat"; "/etc/passwd"] in
    (match r with
     | Par_code_approvals.External_path ps ->
       Alcotest.(check int) "one external path" 1 (List.length ps)
     | other ->
       Alcotest.fail (Printf.sprintf "expected External_path, got %s"
         (match other with In_project -> "In_project" | Unknown -> "Unknown" | Sensitive _ -> "Sensitive" | External_path _ -> "External_path")))

let test_classify_delete_command () =
  match Par.Workspace.of_cwd () with
  | Error _ -> Alcotest.fail "of_cwd failed"
  | Ok ws ->
    let r = Par_code_approvals.classify ws ~argv:["rm"; "-rf"; "lib/"] in
    (match r with
     | Par_code_approvals.External_path ps ->
       Alcotest.(check string) "argv0 as path" "rm" (List.hd ps)
     | other ->
       Alcotest.fail (Printf.sprintf "expected External_path for rm, got %s"
         (match other with In_project -> "In_project" | Unknown -> "Unknown" | Sensitive _ -> "Sensitive" | External_path _ -> "External_path")))

let test_classify_dotdot_unknown () =
  match Par.Workspace.of_cwd () with
  | Error _ -> Alcotest.fail "of_cwd failed"
  | Ok ws ->
    let r = Par_code_approvals.classify ws ~argv:["cat"; "../outside"] in
    Alcotest.(check bool) ".. path is Unknown" true
      (r = Par_code_approvals.Unknown)

let () =
  let open Alcotest in
  run "Approvals" [
    "matches", [
      test_case "exact prefix"     `Quick test_matches_exact_prefix;
      test_case "star suffix"      `Quick test_matches_star_suffix;
      test_case "no match"         `Quick test_matches_no_match;
      test_case "empty patterns"   `Quick test_matches_empty_patterns;
    ];
    "store", [
      test_case "add+load roundtrip" `Quick test_add_load_roundtrip;
      test_case "missing file"       `Quick test_load_missing_file;
    ];
    "classify", [
      test_case "in_project relative" `Quick test_classify_in_project_relative;
      test_case "in_project no paths" `Quick test_classify_in_project_no_paths;
      test_case "external path"       `Quick test_classify_external_path;
      test_case "sensitive"           `Quick test_classify_sensitive;
      test_case "etc external"        `Quick test_classify_etc_external;
      test_case "delete command"      `Quick test_classify_delete_command;
      test_case "dotdot unknown"      `Quick test_classify_dotdot_unknown;
    ];
  ]
