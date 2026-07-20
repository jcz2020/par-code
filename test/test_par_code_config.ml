(* test_par_code_config.ml — Tests for config mask_api_key, show, and JSON round-trip. *)

open Par_code_config

(* ── mask_api_key ─────────────────────────────────────────────────────── *)

let test_mask_short () =
  Alcotest.(check string) "short key masked" "****" (mask_api_key "abc")

let test_mask_empty () =
  Alcotest.(check string) "empty key" "****" (mask_api_key "")

let test_mask_exactly_four () =
  Alcotest.(check string) "exactly 4 chars" "****" (mask_api_key "abcd")

let test_mask_long () =
  Alcotest.(check string) "long key masked" "sk-a****3456" (mask_api_key "sk-abcdef123456")

let test_mask_five () =
  Alcotest.(check string) "5 chars" "a****e" (mask_api_key "abcde")

let test_mask_typical () =
  Alcotest.(check string) "typical API key" "sk-t****5678" (mask_api_key "sk-test12345678")

(* ── JSON round-trip ──────────────────────────────────────────────────── *)

let string_contains s sub =
  let len_s = String.length s in
  let len_sub = String.length sub in
  let rec search i =
    if i + len_sub > len_s then false
    else if String.sub s i len_sub = sub then true
    else search (i + 1)
  in
  len_sub = 0 || search 0

let test_json_roundtrip () =
  let cfg = { default with
    api_key = "sk-test12345678";
    model = "gpt-4o";
    temperature = 0.5;
    max_tokens = Some 4096;
    top_p = Some 0.9;
    auto_extract = false;
    checkpoint_enabled = false;
    checkpoint_interval = 5;
    context_budget_tokens = 50000;
  } in
  let json = to_json cfg in
  match of_json json with
  | Error msg -> Alcotest.fail (Printf.sprintf "of_json failed: %s" msg)
  | Ok loaded ->
    Alcotest.(check string) "provider roundtrip" "openai" loaded.provider;
    Alcotest.(check string) "api_key roundtrip" "sk-test12345678" loaded.api_key;
    Alcotest.(check string) "model roundtrip" "gpt-4o" loaded.model;
    Alcotest.(check (float 0.01)) "temperature roundtrip" 0.5 loaded.temperature;
    Alcotest.(check (option int)) "max_tokens roundtrip" (Some 4096) loaded.max_tokens;
    (match loaded.top_p with
     | Some f -> Alcotest.(check (float 0.01)) "top_p roundtrip" 0.9 f
     | None -> Alcotest.fail "top_p should be Some 0.9");
    Alcotest.(check bool) "auto_extract roundtrip" false loaded.auto_extract;
    Alcotest.(check bool) "checkpoint_enabled roundtrip" false loaded.checkpoint_enabled;
    Alcotest.(check int) "checkpoint_interval roundtrip" 5 loaded.checkpoint_interval;
    Alcotest.(check int) "context_budget_tokens roundtrip" 50000 loaded.context_budget_tokens

let test_json_optional_fields_missing () =
  let json_str = {|{"provider":"anthropic","api_key":"sk-xyz","model":"claude-3","persistence":"sqlite","temperature":0.8,"system_prompt":"hello","max_iterations":30,"parallel_tool_execution":true,"event_retention_days":7.0,"auto_extract":true,"embedding_dimension":1536,"checkpoint_enabled":true,"checkpoint_interval":10,"context_budget_tokens":100000}|} in
  let json = Yojson.Safe.from_string json_str in
  match of_json json with
  | Error msg -> Alcotest.fail (Printf.sprintf "of_json failed: %s" msg)
  | Ok loaded ->
    Alcotest.(check (option int)) "max_tokens missing → None" None loaded.max_tokens;
    (match loaded.top_p with
     | None -> ()
     | Some _ -> Alcotest.fail "top_p should be None");
    Alcotest.(check (option string)) "api_base missing → None" None loaded.api_base;
    Alcotest.(check (option string)) "db_uri missing → None" None loaded.db_uri

let test_json_defaults_fallback () =
  let json_str = {|{"provider":"openai","api_key":"","model":"gpt-4o","persistence":"sqlite","temperature":0.7,"system_prompt":"","max_iterations":0,"parallel_tool_execution":true,"event_retention_days":7.0,"auto_extract":true,"embedding_dimension":1536,"checkpoint_enabled":true,"checkpoint_interval":10,"context_budget_tokens":100000}|} in
  let json = Yojson.Safe.from_string json_str in
  match of_json json with
  | Error msg -> Alcotest.fail (Printf.sprintf "of_json failed: %s" msg)
  | Ok loaded ->
    (* empty system_prompt should fall back to default *)
    Alcotest.(check bool) "empty system_prompt → default" true
      (loaded.system_prompt = default_system_prompt);
    (* max_iterations=0 should use the raw value (of_json doesn't validate > 0) *)
    Alcotest.(check int) "max_iterations=0 preserved" 0 loaded.max_iterations

(* ── show output ──────────────────────────────────────────────────────── *)

let capture_stdout f =
  let tmp = Filename.temp_file "par_test_show" ".txt" in
  let fd_out = Unix.openfile tmp [Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC] 0o644 in
  let old_stdout = Unix.dup Unix.stdout in
  Unix.dup2 fd_out Unix.stdout;
  Unix.close fd_out;
  (try f () with _ -> ());
  flush stdout;
  Unix.dup2 old_stdout Unix.stdout;
  Unix.close old_stdout;
  let ic = open_in tmp in
  let n = in_channel_length ic in
  let s = Bytes.create n in
  really_input ic s 0 n;
  close_in ic;
  Sys.remove tmp;
  Bytes.to_string s

let test_show_output () =
  let cfg = { default with api_key = "sk-test12345678"; model = "gpt-4o" } in
  let output = capture_stdout (fun () -> show cfg) in
  Alcotest.(check bool) "shows provider" true (string_contains output "provider:");
  Alcotest.(check bool) "shows masked api_key" true (string_contains output "sk-t****5678");
  Alcotest.(check bool) "shows model" true (string_contains output "model:");
  Alcotest.(check bool) "shows temperature" true (string_contains output "temperature:");
  Alcotest.(check bool) "shows max_tokens" true (string_contains output "max_tokens:");
  Alcotest.(check bool) "shows auto_extract" true (string_contains output "auto_extract:");
  Alcotest.(check bool) "shows checkpoint_enabled" true (string_contains output "checkpoint_enabled:");
  Alcotest.(check bool) "shows context_budget_tokens" true (string_contains output "context_budget_tokens:");
  Alcotest.(check bool) "system_prompt shows <default>" true (string_contains output "<default>")

let test_show_custom_system_prompt () =
  let cfg = { default with api_key = "x"; system_prompt = "custom prompt here" } in
  let output = capture_stdout (fun () -> show cfg) in
  Alcotest.(check bool) "shows <custom> for non-default prompt" true (string_contains output "<custom>")

(* ── Test runner ──────────────────────────────────────────────────────── *)

let () =
  Alcotest.run "par_code_config"
    [ "mask_api_key", [
        Alcotest.test_case "short"     `Quick test_mask_short;
        Alcotest.test_case "empty"     `Quick test_mask_empty;
        Alcotest.test_case "exactly_4" `Quick test_mask_exactly_four;
        Alcotest.test_case "long"      `Quick test_mask_long;
        Alcotest.test_case "five"      `Quick test_mask_five;
        Alcotest.test_case "typical"   `Quick test_mask_typical;
      ];
      "json_roundtrip", [
        Alcotest.test_case "roundtrip"          `Quick test_json_roundtrip;
        Alcotest.test_case "optional_missing"   `Quick test_json_optional_fields_missing;
        Alcotest.test_case "defaults_fallback"  `Quick test_json_defaults_fallback;
      ];
      "show", [
        Alcotest.test_case "output"              `Quick test_show_output;
        Alcotest.test_case "custom_system_prompt" `Quick test_show_custom_system_prompt;
      ];
    ]
