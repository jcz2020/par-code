(* test_par_code_edit_preview.ml — the diff and the edit-approval preview. *)

let check name expected actual = Alcotest.(check string) name expected actual

let join lines = String.concat "\n" lines

let identical_files_differ_nowhere () =
  Alcotest.(check (list string)) "no hunks" []
    (Par_code_diff.unified ~context:3 ~old_text:"a\nb\n" ~new_text:"a\nb\n")

let changed_line_shows_context () =
  let out =
    Par_code_diff.unified ~context:3
      ~old_text:"alpha\nbeta\ngamma\ndelta\n"
      ~new_text:"alpha\nBETA\ngamma\ndelta\n"
  in
  Alcotest.(check (list string)) "header and rows"
    [ "@@ -1,4 +1,4 @@"; " alpha"; "-beta"; "+BETA"; " gamma"; " delta" ]
    out

let appended_line () =
  Alcotest.(check (list string)) "append"
    [ "@@ -1,1 +1,2 @@"; " a"; "+b" ]
    (Par_code_diff.unified ~context:3 ~old_text:"a" ~new_text:"a\nb")

let new_file () =
  Alcotest.(check (list string)) "create"
    [ "@@ -1,0 +1,2 @@"; "+x"; "+y" ]
    (Par_code_diff.unified ~context:3 ~old_text:"" ~new_text:"x\ny")

let apply_edits_replace_once () =
  match
    Par_code_edit_preview.apply_edits "a b a"
      [ ("a", "X") ]
  with
  | Ok s -> check "first only" "X b a" s
  | Error e -> Alcotest.fail ("unexpected error: " ^ e)

let apply_edits_missing_text () =
  match Par_code_edit_preview.apply_edits "abc" [ ("zzz", "q") ] with
  | Ok _ -> Alcotest.fail "a missing old text must be reported"
  | Error missing -> check "names the text" "zzz" missing

let with_temp_cwd f =
  let old = Sys.getcwd () in
  let dir = Filename.temp_file "par_preview" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o700;
  Fun.protect
    ~finally:(fun () -> Sys.chdir old; ignore (Sys.command ("rm -rf " ^ Filename.quote dir)))
    (fun () -> Sys.chdir dir; f dir)

let write_preview_creates_and_overwrites () =
  with_temp_cwd (fun _dir ->
      let input = Yojson.Safe.from_string {|{"path":"x.txt","content":"one\ntwo\n"}|} in
      (match
         Par_code_edit_preview.for_tool ~cwd:(Sys.getcwd ()) ~tool:"write" ~input
       with
       | Some p -> check "create title" "Create x.txt" p.Par_code_edit_preview.title
       | None -> Alcotest.fail "write must have a preview");
      let oc = open_out "x.txt" in
      output_string oc "one\n";
      close_out oc;
      match
        Par_code_edit_preview.for_tool ~cwd:(Sys.getcwd ()) ~tool:"write" ~input
      with
      | Some p ->
        check "overwrite title" "Overwrite x.txt" p.Par_code_edit_preview.title;
        let text =
          p.Par_code_edit_preview.body |> List.map fst |> join
        in
        Alcotest.(check bool) "shows the added line" true
          (String.length text > 0 && String.contains text '+')
      | None -> Alcotest.fail "overwrite must have a preview")

let apply_patch_preview_keeps_markers () =
  let patch = "--- a/x\n+++ b/x\n@@ -1 +1 @@\n-old\n+new\n" in
  let input = Yojson.Safe.from_string (Yojson.Safe.to_string (`Assoc [ ("patch", `String patch) ])) in
  match Par_code_edit_preview.for_tool ~cwd:"." ~tool:"apply_patch" ~input with
  | Some p ->
    let text = p.Par_code_edit_preview.body |> List.map fst |> join in
    Alcotest.(check bool) "removal marker" true (String.contains text '-');
    Alcotest.(check bool) "addition marker" true (String.contains text '+')
  | None -> Alcotest.fail "apply_patch must have a preview"

let policy_always_never_asks () =
  Par_code_edit_preview.allow_session := false;
  Alcotest.(check bool) "always" false (Par_code_edit_preview.should_ask ~policy:"always");
  Alcotest.(check bool) "ask" true (Par_code_edit_preview.should_ask ~policy:"ask");
  Par_code_edit_preview.allow_session := true;
  Alcotest.(check bool) "session allow" false (Par_code_edit_preview.should_ask ~policy:"ask");
  Par_code_edit_preview.allow_session := false

let () =
  Alcotest.run "par_edit_preview"
    [ ( "diff",
        [ Alcotest.test_case "identical" `Quick identical_files_differ_nowhere
        ; Alcotest.test_case "changed" `Quick changed_line_shows_context
        ; Alcotest.test_case "append" `Quick appended_line
        ; Alcotest.test_case "new_file" `Quick new_file
        ] )
    ; ( "edits",
        [ Alcotest.test_case "replace_once" `Quick apply_edits_replace_once
        ; Alcotest.test_case "missing" `Quick apply_edits_missing_text
        ] )
    ; ( "preview",
        [ Alcotest.test_case "write" `Quick write_preview_creates_and_overwrites
        ; Alcotest.test_case "patch" `Quick apply_patch_preview_keeps_markers
        ; Alcotest.test_case "policy" `Quick policy_always_never_asks
        ] )
    ]
