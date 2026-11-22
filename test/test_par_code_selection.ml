(* test_par_code_selection.ml — pure selection and clipboard helpers. *)

let no_style = Par_code_ui.no_style

let check name expected actual = Alcotest.(check string) name expected actual

let base64_vectors () =
  let open Par_code_clipboard in
  check "empty" "" (base64 "");
  check "one byte" "Zg==" (base64 "f");
  check "two bytes" "Zm8=" (base64 "fo");
  check "three bytes" "Zm9v" (base64 "foo");
  check "text" "aGVsbG8gd29ybGQ=" (base64 "hello world")

let osc52_wraps_the_payload () =
  Alcotest.(check string) "sequence"
    "\027]52;c;Zm9v\007"
    (Par_code_clipboard.osc52 "foo")

let with_temp_dir f =
  let dir = Filename.temp_file "par_clip" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o700;
  Fun.protect
    ~finally:(fun () -> ignore (Sys.command ("rm -rf " ^ Filename.quote dir)))
    (fun () -> f dir)

let command_copy_writes_stdin () =
  with_temp_dir (fun dir ->
      let script = Filename.concat dir "clip.sh" in
      let out = Filename.concat dir "out" in
      let oc = open_out script in
      output_string oc (Printf.sprintf "#!/bin/sh\ncat > %s\n" (Filename.quote out));
      close_out oc;
      Unix.chmod script 0o755;
      (match Par_code_clipboard.copy_via_command script "hello" with
       | Ok () -> ()
       | Error e -> Alcotest.fail ("command copy failed: " ^ e));
      let ic = open_in out in
      let got = really_input_string ic (in_channel_length ic) in
      close_in ic;
      check "stdin reached the command" "hello" got)

let missing_command_is_not_available () =
  Alcotest.(check bool) "missing" false
    (Par_code_clipboard.command_available "/nonexistent/clipboard-tool")

let normalize_orders_points () =
  let a, b = Par_code_selection.normalize (2, 5) (1, 3) in
  Alcotest.(check (pair int int)) "start" (1, 3) a;
  Alcotest.(check (pair int int)) "end" (2, 5) b

let line_span_covers_inner_lines () =
  let a = (1, 3) and b = (3, 2) in
  Alcotest.(check (option (pair int int))) "before" None
    (Par_code_selection.line_span a b 0);
  Alcotest.(check (option (pair int int))) "first" (Some (3, max_int))
    (Par_code_selection.line_span a b 1);
  Alcotest.(check (option (pair int int))) "middle" (Some (0, max_int))
    (Par_code_selection.line_span a b 2);
  Alcotest.(check (option (pair int int))) "last" (Some (0, 2))
    (Par_code_selection.line_span a b 3);
  Alcotest.(check (option (pair int int))) "after" None
    (Par_code_selection.line_span a b 4)

let select_runs_reverses_the_span () =
  let runs = [ ("abcdef", no_style) ] in
  let out = Par_code_selection.select_runs runs ~from:2 ~to_:4 in
  check "text kept" "abcdef"
    (String.concat "" (List.map fst out));
  let reversed =
    List.filter_map
      (fun (s, (sty : Par_code_ui.style)) -> if sty.reverse then Some s else None)
      out
  in
  check "only the span" "cd" (String.concat "" reversed)

let select_runs_splits_across_styles () =
  let bold = Par_code_ui.style ~bold:true () in
  let runs = [ ("ab", no_style); ("cd", bold) ] in
  let out = Par_code_selection.select_runs runs ~from:1 ~to_:3 in
  check "text kept" "abcd" (String.concat "" (List.map fst out));
  let reversed =
    List.filter_map
      (fun (s, (sty : Par_code_ui.style)) -> if sty.reverse then Some s else None)
      out
  in
  check "b and c" "bc" (String.concat "" reversed)

let select_runs_counts_cjk_columns () =
  let runs = [ ("中文ab", no_style) ] in
  let out = Par_code_selection.select_runs runs ~from:2 ~to_:4 in
  let reversed =
    List.filter_map
      (fun (s, (sty : Par_code_ui.style)) -> if sty.reverse then Some s else None)
      out
  in
  (* 中 occupies columns 0-2, 文 2-4; selecting 2..4 takes the whole glyph. *)
  check "one wide glyph" "文" (String.concat "" reversed)

let text_of_runs_uses_columns () =
  check "middle" "bc" (Par_code_selection.text_of_runs [ ("abcd", no_style) ] ~from:1 ~to_:3);
  check "cjk" "文" (Par_code_selection.text_of_runs [ ("中文ab", no_style) ] ~from:2 ~to_:4)

let text_of_lines_joins_rows () =
  let lines = [ [ ("abc", no_style) ]; [ ("def", no_style) ] ] in
  check "two rows" "bc\ndef"
    (Par_code_selection.text_of_lines lines (0, 1) (1, 3))

let char_count_is_codepoints () =
  Alcotest.(check int) "ascii" 5 (Par_code_selection.char_count "hello");
  Alcotest.(check int) "chinese" 7 (Par_code_selection.char_count "一加一等于二。")

let () =
  Alcotest.run "par_selection"
    [ ( "clipboard",
        [ Alcotest.test_case "base64" `Quick base64_vectors
        ; Alcotest.test_case "osc52" `Quick osc52_wraps_the_payload
        ; Alcotest.test_case "command" `Quick command_copy_writes_stdin
        ; Alcotest.test_case "missing" `Quick missing_command_is_not_available
        ] )
    ; ( "geometry",
        [ Alcotest.test_case "normalize" `Quick normalize_orders_points
        ; Alcotest.test_case "line_span" `Quick line_span_covers_inner_lines
        ; Alcotest.test_case "text_of_lines" `Quick text_of_lines_joins_rows
        ; Alcotest.test_case "char_count" `Quick char_count_is_codepoints
        ] )
    ; ( "runs",
        [ Alcotest.test_case "reverses_span" `Quick select_runs_reverses_the_span
        ; Alcotest.test_case "across_styles" `Quick select_runs_splits_across_styles
        ; Alcotest.test_case "cjk_columns" `Quick select_runs_counts_cjk_columns
        ; Alcotest.test_case "text_of_runs" `Quick text_of_runs_uses_columns
        ] )
    ]
