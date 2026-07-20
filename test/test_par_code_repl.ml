(* test_par_code_repl.ml — Tests for session cost tracking and /cost output. *)

open Par_code_repl

let string_contains s sub =
  let len_s = String.length s in
  let len_sub = String.length sub in
  let rec search i =
    if i + len_sub > len_s then false
    else if String.sub s i len_sub = sub then true
    else search (i + 1)
  in
  len_sub = 0 || search 0

let make_usage ~prompt ~completion ~total =
  Par.Types.{ prompt_tokens = prompt; completion_tokens = completion;
              total_tokens = total; cached_tokens = 0;
              cache_creation_input_tokens = 0; cache_read_input_tokens = 0 }

let test_empty_cost () =
  let s = empty_cost in
  Alcotest.(check int) "llm_calls" 0 s.llm_calls;
  Alcotest.(check int) "prompt_tokens" 0 s.prompt_tokens;
  Alcotest.(check int) "completion_tokens" 0 s.completion_tokens;
  Alcotest.(check int) "total_tokens" 0 s.total_tokens

let test_add_usage_single () =
  let u = make_usage ~prompt:100 ~completion:50 ~total:150 in
  let s = add_usage empty_cost u in
  Alcotest.(check int) "calls" 1 s.llm_calls;
  Alcotest.(check int) "prompt" 100 s.prompt_tokens;
  Alcotest.(check int) "completion" 50 s.completion_tokens;
  Alcotest.(check int) "total" 150 s.total_tokens

let test_add_usage_accumulates () =
  let u1 = make_usage ~prompt:100 ~completion:50 ~total:150 in
  let u2 = make_usage ~prompt:200 ~completion:100 ~total:300 in
  let s = add_usage (add_usage empty_cost u1) u2 in
  Alcotest.(check int) "calls" 2 s.llm_calls;
  Alcotest.(check int) "prompt" 300 s.prompt_tokens;
  Alcotest.(check int) "completion" 150 s.completion_tokens;
  Alcotest.(check int) "total" 450 s.total_tokens

let test_add_usage_zero () =
  let u = make_usage ~prompt:0 ~completion:0 ~total:0 in
  let s = add_usage empty_cost u in
  Alcotest.(check int) "calls" 1 s.llm_calls;
  Alcotest.(check int) "total" 0 s.total_tokens

let test_format_output_zero () =
  let output = format_cost_output ~cost:empty_cost
    ~context_tokens:0 ~turn_count:0 ~metrics:[] in
  Alcotest.(check bool) "has header" true (string_contains output "Session usage:");
  Alcotest.(check bool) "shows 0 calls" true (string_contains output "LLM calls:");
  Alcotest.(check bool) "shows 0 prompt" true (string_contains output "Prompt tokens:");
  Alcotest.(check bool) "shows 0 total" true (string_contains output "Total tokens:");
  Alcotest.(check bool) "shows context size" true (string_contains output "Context size:");
  Alcotest.(check bool) "shows turns" true (string_contains output "Turns completed:");
  Alcotest.(check bool) "has metrics section" true (string_contains output "Operational metrics:");
  Alcotest.(check bool) "has note" true (string_contains output "excludes async")

let test_format_output_with_data () =
  let u = make_usage ~prompt:500 ~completion:250 ~total:750 in
  let s = add_usage (add_usage (add_usage empty_cost u) u) u in
  let output = format_cost_output ~cost:s
    ~context_tokens:4200 ~turn_count:3
    ~metrics:[("llm.calls", 3); ("llm.errors", 0)] in
  Alcotest.(check bool) "shows 3 calls" true (string_contains output "3");
  Alcotest.(check bool) "shows prompt 1500" true (string_contains output "1500");
  Alcotest.(check bool) "shows total 2250" true (string_contains output "2250");
  Alcotest.(check bool) "shows context 4200" true (string_contains output "4200");
  Alcotest.(check bool) "shows llm.calls metric" true (string_contains output "llm.calls");
  Alcotest.(check bool) "shows llm.errors metric" true (string_contains output "llm.errors")

let test_format_output_metrics_list () =
  let metrics = [("a", 1); ("b", 2); ("c", 3)] in
  let output = format_cost_output ~cost:empty_cost
    ~context_tokens:0 ~turn_count:0 ~metrics in
  Alcotest.(check bool) "shows metric a" true (string_contains output "a: 1");
  Alcotest.(check bool) "shows metric b" true (string_contains output "b: 2");
  Alcotest.(check bool) "shows metric c" true (string_contains output "c: 3")

let () =
  Alcotest.run "par_repl"
    [ "cost_state", [
        Alcotest.test_case "empty_cost"         `Quick test_empty_cost;
        Alcotest.test_case "add_usage_single"    `Quick test_add_usage_single;
        Alcotest.test_case "add_usage_accumulates" `Quick test_add_usage_accumulates;
        Alcotest.test_case "add_usage_zero"      `Quick test_add_usage_zero;
      ];
      "format_cost", [
        Alcotest.test_case "output_zero"         `Quick test_format_output_zero;
        Alcotest.test_case "output_with_data"    `Quick test_format_output_with_data;
        Alcotest.test_case "output_metrics_list" `Quick test_format_output_metrics_list;
      ];
    ]
