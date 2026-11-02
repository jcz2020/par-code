(* test_par_code_max_mode.ml — strategy seeds, candidate prompts, usage merge. *)

open Par

let string_contains s sub =
  let len_s = String.length s in
  let len_sub = String.length sub in
  let rec search i =
    if i + len_sub > len_s then false
    else if String.sub s i len_sub = sub then true
    else search (i + 1)
  in
  len_sub = 0 || search 0

let test_seed_count () =
  Alcotest.(check int) "three strategy seeds" 3
    (List.length Par_code_max_mode.strategy_seeds)

let test_seed_rotation () =
  Alcotest.(check string) "index 0 is first seed"
    (List.nth Par_code_max_mode.strategy_seeds 0)
    (Par_code_max_mode.seed_for 0);
  Alcotest.(check string) "index 2 is third seed"
    (List.nth Par_code_max_mode.strategy_seeds 2)
    (Par_code_max_mode.seed_for 2)

let test_seed_wraps () =
  Alcotest.(check string) "index 3 wraps to seed 0"
    (Par_code_max_mode.seed_for 0)
    (Par_code_max_mode.seed_for 3)

let test_seeds_differ () =
  let seeds = Par_code_max_mode.strategy_seeds in
  Alcotest.(check int) "every seed is distinct" (List.length seeds)
    (List.length (List.sort_uniq String.compare seeds))

let test_candidate_prompt_carries_both_parts () =
  let prompt =
    Par_code_max_mode.candidate_prompt ~seed:"ANGLE-XYZ" ~message:"REQUEST-ABC"
  in
  Alcotest.(check bool) "seed present" true (string_contains prompt "ANGLE-XYZ");
  Alcotest.(check bool) "message present" true
    (string_contains prompt "REQUEST-ABC")

let test_clamp_candidates () =
  Alcotest.(check int) "1 clamps up to 2" 2
    (Par_code_max_mode.clamp_candidates 1);
  Alcotest.(check int) "0 clamps up to 2" 2
    (Par_code_max_mode.clamp_candidates 0);
  Alcotest.(check int) "3 stays" 3 (Par_code_max_mode.clamp_candidates 3);
  Alcotest.(check int) "5 stays" 5 (Par_code_max_mode.clamp_candidates 5);
  Alcotest.(check int) "9 clamps down to 5" 5
    (Par_code_max_mode.clamp_candidates 9)

let usage ?(p = 0) ?(c = 0) () : Types.usage_stats =
  { Types.prompt_tokens = p
  ; completion_tokens = c
  ; total_tokens = p + c
  ; cached_tokens = 0
  ; cache_creation_input_tokens = 0
  ; cache_read_input_tokens = 0
  }

let test_merge_usage_sums () =
  let merged = Par_code_max_mode.merge_usage [ usage ~p:10 ~c:5 (); usage ~p:3 ~c:1 () ] in
  Alcotest.(check int) "prompt tokens summed" 13 merged.Types.prompt_tokens;
  Alcotest.(check int) "completion tokens summed" 6 merged.Types.completion_tokens;
  Alcotest.(check int) "total tokens summed" 19 merged.Types.total_tokens

let test_merge_usage_empty () =
  let merged = Par_code_max_mode.merge_usage [] in
  Alcotest.(check int) "empty merge is zero" 0 merged.Types.total_tokens

let test_candidate_usages_skip_failures () =
  let conv : Types.conversation = { messages = []; metadata = [] } in
  let mk index p =
    { Par_code_max_mode.index
    ; text = "t"
    ; conversation = conv
    ; usage = usage ~p ~c:0 ()
    ; events = []
    }
  in
  let outcome =
    { Par_code_max_mode.candidates = [ mk 0 4; mk 2 6 ]
    ; failures = [ (1, "boom") ]
    }
  in
  let usages = Par_code_max_mode.candidate_usages outcome in
  Alcotest.(check int) "one usage per successful candidate" 2
    (List.length usages);
  Alcotest.(check int) "merged prompt tokens" 10
    (Par_code_max_mode.merge_usage usages).Types.prompt_tokens

let test_copy_conversation_isolated () =
  let msg : Types.message =
    { role = Types.User
    ; content_blocks = [ Types.Text_block { text = "hi"; cache_control = None } ]
    ; tool_calls = None
    ; tool_call_id = None
    ; name = None
    ; reasoning_content = None
    }
  in
  let original : Types.conversation =
    { messages = [ msg ]; metadata = [ ("k", `String "v") ] }
  in
  let copy = Par_code_max_mode.copy_conversation original in
  Alcotest.(check int) "same message count" (List.length original.messages)
    (List.length copy.messages);
  let original_untouched =
    match original.messages with
    | [ m ] -> ( match m.content_blocks with
        | [ Types.Text_block { text; _ } ] -> text = "hi"
        | _ -> false)
    | _ -> false
  in
  Alcotest.(check bool) "original conversation unchanged" true original_untouched;
  Alcotest.(check bool) "copy is a distinct record"
    false (copy == original)

let () =
  Alcotest.run "par_code_max_mode"
    [ "strategy_seeds", [
        Alcotest.test_case "count"      `Quick test_seed_count;
        Alcotest.test_case "rotation"   `Quick test_seed_rotation;
        Alcotest.test_case "wraps"      `Quick test_seed_wraps;
        Alcotest.test_case "distinct"   `Quick test_seeds_differ;
      ];
      "candidate_prompt", [
        Alcotest.test_case "carries seed and message" `Quick
          test_candidate_prompt_carries_both_parts;
      ];
      "clamp", [
        Alcotest.test_case "bounds" `Quick test_clamp_candidates;
      ];
      "usage", [
        Alcotest.test_case "sums"            `Quick test_merge_usage_sums;
        Alcotest.test_case "empty"           `Quick test_merge_usage_empty;
        Alcotest.test_case "outcome_skips_failures" `Quick
          test_candidate_usages_skip_failures;
      ];
      "conversation_copy", [
        Alcotest.test_case "isolated" `Quick test_copy_conversation_isolated;
      ];
    ]
