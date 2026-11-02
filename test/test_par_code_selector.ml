(* test_par_code_selector.ml — selector JSON parsing and message assembly. *)

let string_contains s sub =
  let len_s = String.length s in
  let len_sub = String.length sub in
  let rec search i =
    if i + len_sub > len_s then false
    else if String.sub s i len_sub = sub then true
    else search (i + 1)
  in
  len_sub = 0 || search 0

let test_parse_plain () =
  match
    Par_code_selector.parse_choice ~n:3
      {|{"choice": 2, "kind": "answer", "plan": "", "reasoning": "reuses the helper"}|}
  with
  | None -> Alcotest.fail "expected a choice"
  | Some c ->
    Alcotest.(check int) "1-based 2 becomes index 1" 1 c.Par_code_selector.index;
    Alcotest.(check bool) "kind answer"
      true (c.Par_code_selector.kind = Par_code_selector.Answer);
    Alcotest.(check string) "reasoning kept" "reuses the helper"
      c.Par_code_selector.reasoning

let test_parse_wrapped_in_prose () =
  match
    Par_code_selector.parse_choice ~n:2
      "Here is my pick:\n{\"choice\": 1, \"kind\": \"execute\", \"plan\": \"add the retry loop\"}\nDone."
  with
  | None -> Alcotest.fail "prose-wrapped JSON must still parse"
  | Some c ->
    Alcotest.(check int) "index 0" 0 c.Par_code_selector.index;
    Alcotest.(check bool) "kind execute"
      true (c.Par_code_selector.kind = Par_code_selector.Execute);
    Alcotest.(check string) "plan kept" "add the retry loop"
      c.Par_code_selector.plan

let test_parse_out_of_range () =
  match Par_code_selector.parse_choice ~n:3 {|{"choice": 7, "kind": "execute"}|} with
  | None -> Alcotest.fail "out-of-range must still return a fallback choice"
  | Some c ->
    Alcotest.(check int) "falls back to candidate 1" 0 c.Par_code_selector.index;
    Alcotest.(check bool) "falls back to answer"
      true (c.Par_code_selector.kind = Par_code_selector.Answer)

let test_parse_negative () =
  match Par_code_selector.parse_choice ~n:3 {|{"choice": -1, "kind": "execute"}|} with
  | None -> Alcotest.fail "negative must still return a fallback choice"
  | Some c ->
    Alcotest.(check int) "index 0" 0 c.Par_code_selector.index;
    Alcotest.(check bool) "kind reset to answer"
      true (c.Par_code_selector.kind = Par_code_selector.Answer)

let test_parse_zero_is_first () =
  match Par_code_selector.parse_choice ~n:3 {|{"choice": 0, "kind": "execute"}|} with
  | None -> Alcotest.fail "explicit 0 should map to the first candidate"
  | Some c ->
    Alcotest.(check int) "index 0" 0 c.Par_code_selector.index;
    Alcotest.(check bool) "kind preserved"
      true (c.Par_code_selector.kind = Par_code_selector.Execute)

let test_parse_missing_choice_field () =
  match Par_code_selector.parse_choice ~n:3 {|{"kind": "answer", "reasoning": "x"}|} with
  | None -> Alcotest.fail "missing choice must fall back, not fail"
  | Some c ->
    Alcotest.(check int) "index 0" 0 c.Par_code_selector.index

let test_parse_string_choice () =
  match Par_code_selector.parse_choice ~n:3 {|{"choice": "3", "kind": "answer"}|} with
  | None -> Alcotest.fail "numeric string should parse"
  | Some c -> Alcotest.(check int) "index 2" 2 c.Par_code_selector.index

let test_parse_float_choice () =
  match Par_code_selector.parse_choice ~n:3 {|{"choice": 2.0, "kind": "answer"}|} with
  | None -> Alcotest.fail "float choice should parse"
  | Some c -> Alcotest.(check int) "index 1" 1 c.Par_code_selector.index

let test_parse_not_json () =
  Alcotest.(check bool) "prose without JSON yields None" true
    (Par_code_selector.parse_choice ~n:3 "I think candidate two is better." = None)

let test_parse_empty () =
  Alcotest.(check bool) "empty input yields None" true
    (Par_code_selector.parse_choice ~n:3 "" = None)

let test_parse_truncated_json () =
  Alcotest.(check bool) "unbalanced braces yield None" true
    (Par_code_selector.parse_choice ~n:3 {|{"choice": 2, "kind": "answer"|} = None)

let test_build_message_numbers_candidates () =
  let m =
    Par_code_selector.build_message ~user_message:"fix the uploader"
      [ "first answer"; "second answer" ]
  in
  Alcotest.(check bool) "user message present" true
    (string_contains m "fix the uploader");
  Alcotest.(check bool) "candidate 1 header" true
    (string_contains m "### Candidate 1");
  Alcotest.(check bool) "candidate 2 header" true
    (string_contains m "### Candidate 2");
  let at sub =
    let n = String.length sub in
    let rec go i =
      if i + n > String.length m then max_int
      else if String.sub m i n = sub then i
      else go (i + 1)
    in
    go 0
  in
  Alcotest.(check bool) "request precedes candidates" true
    (at "User request" < at "### Candidate 1");
  Alcotest.(check bool) "candidates stay in order" true
    (at "### Candidate 1" < at "### Candidate 2")

let test_truncate_short_untouched () =
  Alcotest.(check string) "short text passes through" "abcdef"
    (Par_code_selector.truncate "abcdef")

let test_truncate_long () =
  let long = String.make 100 'x' in
  let t = Par_code_selector.truncate ~limit:10 long in
  Alcotest.(check bool) "truncated marker appended" true
    (string_contains t "[truncated]");
  Alcotest.(check bool) "shorter than input" true (String.length t < String.length long)

let test_build_message_truncates_each_candidate () =
  let long = String.make (Par_code_selector.max_candidate_chars + 500) 'y' in
  let m = Par_code_selector.build_message ~user_message:"q" [ long; "short" ] in
  let marker_count =
    let rec count i acc =
      if i + 11 > String.length m then acc
      else if String.sub m i 11 = "[truncated]" then count (i + 11) (acc + 1)
      else count (i + 1) acc
    in
    count 0 0
  in
  Alcotest.(check int) "only the long candidate is truncated" 1 marker_count

let () =
  Alcotest.run "par_code_selector"
    [ "parse", [
        Alcotest.test_case "plain"              `Quick test_parse_plain;
        Alcotest.test_case "wrapped_in_prose"   `Quick test_parse_wrapped_in_prose;
        Alcotest.test_case "out_of_range"       `Quick test_parse_out_of_range;
        Alcotest.test_case "negative"           `Quick test_parse_negative;
        Alcotest.test_case "zero_is_first"      `Quick test_parse_zero_is_first;
        Alcotest.test_case "missing_choice"     `Quick test_parse_missing_choice_field;
        Alcotest.test_case "string_choice"      `Quick test_parse_string_choice;
        Alcotest.test_case "float_choice"       `Quick test_parse_float_choice;
        Alcotest.test_case "not_json"           `Quick test_parse_not_json;
        Alcotest.test_case "empty"              `Quick test_parse_empty;
        Alcotest.test_case "truncated_json"     `Quick test_parse_truncated_json;
      ];
      "message", [
        Alcotest.test_case "numbers_candidates" `Quick test_build_message_numbers_candidates;
        Alcotest.test_case "truncates_each"     `Quick test_build_message_truncates_each_candidate;
      ];
      "truncate", [
        Alcotest.test_case "short" `Quick test_truncate_short_untouched;
        Alcotest.test_case "long"  `Quick test_truncate_long;
      ];
    ]
