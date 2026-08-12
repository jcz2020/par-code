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
    planner_max_iterations = 30;
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
    Alcotest.(check int) "context_budget_tokens roundtrip" 50000 loaded.context_budget_tokens;
    Alcotest.(check int) "planner_max_iterations roundtrip" 30 loaded.planner_max_iterations

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

(* ── default_mode ────────────────────────────────────────────────────── *)

let test_default_mode_is_build () =
  Alcotest.(check bool) "default mode is Build" true
    (default.default_mode = Par_code_mode.Build)

let test_json_roundtrip_default_mode_plan () =
  let cfg = { default with default_mode = Par_code_mode.Plan } in
  let json = to_json cfg in
  match of_json json with
  | Error msg -> Alcotest.fail (Printf.sprintf "of_json failed: %s" msg)
  | Ok loaded ->
    Alcotest.(check bool) "default_mode roundtrip is Plan" true
      (loaded.default_mode = Par_code_mode.Plan)

let test_json_legacy_no_default_mode () =
  (* Simulate a v0.4.x config file that has no default_mode field *)
  let json_str = {|{"provider":"openai","api_key":"sk-test","model":"gpt-4o","persistence":"sqlite","temperature":0.7,"system_prompt":"hello","max_iterations":50,"parallel_tool_execution":true,"event_retention_days":7.0,"auto_extract":true,"embedding_dimension":1536,"checkpoint_enabled":true,"checkpoint_interval":10,"context_budget_tokens":100000}|} in
  let json = Yojson.Safe.from_string json_str in
  match of_json json with
  | Error msg -> Alcotest.fail (Printf.sprintf "of_json failed: %s" msg)
  | Ok loaded ->
    Alcotest.(check bool) "legacy config defaults to Build" true
      (loaded.default_mode = Par_code_mode.Build)

let test_json_legacy_plan_value () =
  let json_str = {|{"provider":"openai","api_key":"","model":"gpt-4o","persistence":"sqlite","temperature":0.7,"system_prompt":"hello","max_iterations":50,"parallel_tool_execution":true,"event_retention_days":7.0,"auto_extract":true,"embedding_dimension":1536,"checkpoint_enabled":true,"checkpoint_interval":10,"context_budget_tokens":100000,"default_mode":"plan"}|} in
  let json = Yojson.Safe.from_string json_str in
  match of_json json with
  | Error msg -> Alcotest.fail (Printf.sprintf "of_json failed: %s" msg)
  | Ok loaded ->
    Alcotest.(check bool) "explicit plan in JSON → Plan" true
      (loaded.default_mode = Par_code_mode.Plan)

let test_show_default_mode () =
  let cfg = { default with api_key = "x"; default_mode = Par_code_mode.Plan } in
  let output = capture_stdout (fun () -> show cfg) in
  Alcotest.(check bool) "shows default_mode" true (string_contains output "default_mode:");
  Alcotest.(check bool) "shows plan" true (string_contains output "plan")

(* ── update_field ────────────────────────────────────────────────────── *)

let setup_test_home f =
  let tmp = Filename.temp_file "par_test_config" "" in
  Sys.remove tmp;
  Unix.mkdir tmp 0o755;
  let prev = try Some (Sys.getenv "HOME") with Not_found -> None in
  Unix.putenv "HOME" tmp;
  (try f tmp with e ->
    (match prev with Some h -> Unix.putenv "HOME" h | None -> ());
    raise e);
  (match prev with Some h -> Unix.putenv "HOME" h | None -> ())

let test_update_string_provider () =
  setup_test_home (fun _ ->
    let r = update_field ~field:"provider" ~value:"  anthropic  " in
    Alcotest.(check string) "provider set" "anthropic" r.provider)

let test_update_string_api_key () =
  setup_test_home (fun _ ->
    let r = update_field ~field:"api_key" ~value:"sk-new-key" in
    Alcotest.(check string) "api_key set" "sk-new-key" r.api_key)

let test_update_optional_string_set () =
  setup_test_home (fun _ ->
    let r = update_field ~field:"api_base" ~value:"https://custom.api.com" in
    Alcotest.(check (option string)) "api_base set" (Some "https://custom.api.com") r.api_base)

let test_update_optional_string_empty_clears () =
  setup_test_home (fun _ ->
    let _ = update_field ~field:"api_base" ~value:"https://x.com" in
    let r = update_field ~field:"api_base" ~value:"" in
    Alcotest.(check (option string)) "api_base cleared" None r.api_base)

let test_update_optional_string_none_clears () =
  setup_test_home (fun _ ->
    let _ = update_field ~field:"embedding_model" ~value:"text-embedding-3-small" in
    let r = update_field ~field:"embedding_model" ~value:"none" in
    Alcotest.(check (option string)) "embedding_model cleared" None r.embedding_model)

let test_update_float_temperature () =
  setup_test_home (fun _ ->
    let r = update_field ~field:"temperature" ~value:"0.3" in
    Alcotest.(check (float 0.001)) "temperature set" 0.3 r.temperature)

let test_update_optional_float_set () =
  setup_test_home (fun _ ->
    let r = update_field ~field:"top_p" ~value:"0.95" in
    (match r.top_p with
     | Some f -> Alcotest.(check (float 0.001)) "top_p set" 0.95 f
     | None -> Alcotest.fail "top_p should be Some"))

let test_update_optional_float_clear () =
  setup_test_home (fun _ ->
    let _ = update_field ~field:"top_p" ~value:"0.9" in
    let r = update_field ~field:"top_p" ~value:"" in
    Alcotest.(check (option (float 0.001))) "top_p cleared" None r.top_p)

let test_update_int_max_iterations () =
  setup_test_home (fun _ ->
    let r = update_field ~field:"max_iterations" ~value:"100" in
    Alcotest.(check int) "max_iterations set" 100 r.max_iterations)

let test_update_int_planner_max_iterations () =
  setup_test_home (fun _ ->
    let r = update_field ~field:"planner_max_iterations" ~value:"20" in
    Alcotest.(check int) "planner_max_iterations set" 20 r.planner_max_iterations)

let test_update_int_checkpoint_interval () =
  setup_test_home (fun _ ->
    let r = update_field ~field:"checkpoint_interval" ~value:"5" in
    Alcotest.(check int) "checkpoint_interval set" 5 r.checkpoint_interval)

let test_update_int_context_budget () =
  setup_test_home (fun _ ->
    let r = update_field ~field:"context_budget_tokens" ~value:"50000" in
    Alcotest.(check int) "context_budget_tokens set" 50000 r.context_budget_tokens)

let test_update_optional_int_set () =
  setup_test_home (fun _ ->
    let r = update_field ~field:"max_tokens" ~value:"8192" in
    Alcotest.(check (option int)) "max_tokens set" (Some 8192) r.max_tokens)

let test_update_optional_int_clear () =
  setup_test_home (fun _ ->
    let _ = update_field ~field:"max_tokens" ~value:"4096" in
    let r = update_field ~field:"max_tokens" ~value:"none" in
    Alcotest.(check (option int)) "max_tokens cleared" None r.max_tokens)

let test_update_bool_true () =
  setup_test_home (fun _ ->
    let r = update_field ~field:"parallel_tool_execution" ~value:"false" in
    Alcotest.(check bool) "set false" false r.parallel_tool_execution;
    let r2 = update_field ~field:"parallel_tool_execution" ~value:"yes" in
    Alcotest.(check bool) "set yes" true r2.parallel_tool_execution)

let test_update_bool_false () =
  setup_test_home (fun _ ->
    let r = update_field ~field:"auto_extract" ~value:"0" in
    Alcotest.(check bool) "set 0" false r.auto_extract;
    let r2 = update_field ~field:"auto_extract" ~value:"true" in
    Alcotest.(check bool) "set true" true r2.auto_extract)

let test_update_bool_case_insensitive () =
  setup_test_home (fun _ ->
    let r = update_field ~field:"checkpoint_enabled" ~value:"FALSE" in
    Alcotest.(check bool) "FALSE" false r.checkpoint_enabled;
    let r2 = update_field ~field:"checkpoint_enabled" ~value:"Yes" in
    Alcotest.(check bool) "Yes" true r2.checkpoint_enabled)

let test_update_default_mode () =
  setup_test_home (fun _ ->
    let r = update_field ~field:"default_mode" ~value:"plan" in
    Alcotest.(check bool) "set to plan" true (r.default_mode = Par_code_mode.Plan);
    let r2 = update_field ~field:"default_mode" ~value:"BUILD" in
    Alcotest.(check bool) "set to build" true (r2.default_mode = Par_code_mode.Build))

let test_update_persistence () =
  setup_test_home (fun _ ->
    let r = update_field ~field:"persistence" ~value:"memory" in
    Alcotest.(check string) "persistence set" "memory" r.persistence)

let test_update_embedding_dimension () =
  setup_test_home (fun _ ->
    let r = update_field ~field:"embedding_dimension" ~value:"768" in
    Alcotest.(check int) "embedding_dimension set" 768 r.embedding_dimension)

let test_update_db_uri () =
  setup_test_home (fun _ ->
    let r = update_field ~field:"db_uri" ~value:"postgres://localhost/db" in
    Alcotest.(check (option string)) "db_uri set" (Some "postgres://localhost/db") r.db_uri)

let test_update_event_retention_days () =
  setup_test_home (fun _ ->
    let r = update_field ~field:"event_retention_days" ~value:"14.5" in
    Alcotest.(check (float 0.001)) "event_retention_days set" 14.5 r.event_retention_days)

let test_update_embedding_base_url () =
  setup_test_home (fun _ ->
    let r = update_field ~field:"embedding_base_url" ~value:"https://embed.api.com" in
    Alcotest.(check (option string)) "embedding_base_url set" (Some "https://embed.api.com") r.embedding_base_url)

let test_update_saves_to_disk () =
  setup_test_home (fun _ ->
    let _ = update_field ~field:"model" ~value:"claude-3-opus" in
    match load () with
    | None -> Alcotest.fail "config should exist on disk"
    | Some loaded -> Alcotest.(check string) "model persisted" "claude-3-opus" loaded.model)

let test_update_unknown_field () =
  setup_test_home (fun _ ->
    let pid = Unix.fork () in
    if pid = 0 then begin
      (try ignore (update_field ~field:"nonexistent" ~value:"x") with _ -> ());
      exit 0
    end else
      let _, status = Unix.waitpid [] pid in
      match status with
      | Unix.WEXITED n when n <> 0 -> ()
      | _ -> Alcotest.fail "unknown field should exit non-zero")

let test_update_system_prompt_rejected () =
  setup_test_home (fun _ ->
    let pid = Unix.fork () in
    if pid = 0 then begin
      (try ignore (update_field ~field:"system_prompt" ~value:"test") with _ -> ());
      exit 0
    end else
      let _, status = Unix.waitpid [] pid in
      match status with
      | Unix.WEXITED n when n <> 0 -> ()
      | _ -> Alcotest.fail "system_prompt should exit non-zero")

let test_update_invalid_float () =
  setup_test_home (fun _ ->
    let pid = Unix.fork () in
    if pid = 0 then begin
      (try ignore (update_field ~field:"temperature" ~value:"abc") with _ -> ());
      exit 0
    end else
      let _, status = Unix.waitpid [] pid in
      match status with
      | Unix.WEXITED n when n <> 0 -> ()
      | _ -> Alcotest.fail "invalid float should exit non-zero")

let test_update_invalid_int () =
  setup_test_home (fun _ ->
    let pid = Unix.fork () in
    if pid = 0 then begin
      (try ignore (update_field ~field:"max_iterations" ~value:"xyz") with _ -> ());
      exit 0
    end else
      let _, status = Unix.waitpid [] pid in
      match status with
      | Unix.WEXITED n when n <> 0 -> ()
      | _ -> Alcotest.fail "invalid int should exit non-zero")

let test_update_max_iterations_zero () =
  setup_test_home (fun _ ->
    let pid = Unix.fork () in
    if pid = 0 then begin
      (try ignore (update_field ~field:"max_iterations" ~value:"0") with _ -> ());
      exit 0
    end else
      let _, status = Unix.waitpid [] pid in
      match status with
      | Unix.WEXITED n when n <> 0 -> ()
      | _ -> Alcotest.fail "max_iterations=0 should exit non-zero")

let test_update_checkpoint_interval_zero () =
  setup_test_home (fun _ ->
    let pid = Unix.fork () in
    if pid = 0 then begin
      (try ignore (update_field ~field:"checkpoint_interval" ~value:"0") with _ -> ());
      exit 0
    end else
      let _, status = Unix.waitpid [] pid in
      match status with
      | Unix.WEXITED n when n <> 0 -> ()
      | _ -> Alcotest.fail "checkpoint_interval=0 should exit non-zero")

let test_update_context_budget_too_low () =
  setup_test_home (fun _ ->
    let pid = Unix.fork () in
    if pid = 0 then begin
      (try ignore (update_field ~field:"context_budget_tokens" ~value:"500") with _ -> ());
      exit 0
    end else
      let _, status = Unix.waitpid [] pid in
      match status with
      | Unix.WEXITED n when n <> 0 -> ()
      | _ -> Alcotest.fail "context_budget_tokens=500 should exit non-zero")

let test_update_max_tokens_zero () =
  setup_test_home (fun _ ->
    let pid = Unix.fork () in
    if pid = 0 then begin
      (try ignore (update_field ~field:"max_tokens" ~value:"0") with _ -> ());
      exit 0
    end else
      let _, status = Unix.waitpid [] pid in
      match status with
      | Unix.WEXITED n when n <> 0 -> ()
      | _ -> Alcotest.fail "max_tokens=0 should exit non-zero")

let test_update_invalid_bool () =
  setup_test_home (fun _ ->
    let pid = Unix.fork () in
    if pid = 0 then begin
      (try ignore (update_field ~field:"auto_extract" ~value:"maybe") with _ -> ());
      exit 0
    end else
      let _, status = Unix.waitpid [] pid in
      match status with
      | Unix.WEXITED n when n <> 0 -> ()
      | _ -> Alcotest.fail "invalid bool should exit non-zero")

let test_update_invalid_default_mode () =
  setup_test_home (fun _ ->
    let pid = Unix.fork () in
    if pid = 0 then begin
      (try ignore (update_field ~field:"default_mode" ~value:"debug") with _ -> ());
      exit 0
    end else
      let _, status = Unix.waitpid [] pid in
      match status with
      | Unix.WEXITED n when n <> 0 -> ()
      | _ -> Alcotest.fail "invalid mode should exit non-zero")

let test_unknown_field_lists_all () =
  setup_test_home (fun _ ->
    let tmp_err = Filename.temp_file "par_test_err" ".txt" in
    let fd = Unix.openfile tmp_err [Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC] 0o644 in
    let old_stderr = Unix.dup Unix.stderr in
    Unix.dup2 fd Unix.stderr;
    Unix.close fd;
    let pid = Unix.fork () in
    if pid = 0 then begin
      ignore (update_field ~field:"bogus" ~value:"x");
      exit 0
    end else begin
      let _, _ = Unix.waitpid [] pid in
      Unix.dup2 old_stderr Unix.stderr;
      Unix.close old_stderr;
      let ic = open_in tmp_err in
      let n = in_channel_length ic in
      let buf = Bytes.create n in
      really_input ic buf 0 n;
      close_in ic;
      Sys.remove tmp_err;
      let err = Bytes.to_string buf in
      let all_fields = [
        "api_base"; "api_key"; "auto_extract";
        "checkpoint_enabled"; "checkpoint_interval";
        "context_budget_tokens"; "db_uri"; "default_mode";
        "embedding_base_url"; "embedding_dimension"; "embedding_model";
        "event_retention_days";
        "max_iterations"; "max_tokens"; "model";
        "parallel_tool_execution"; "persistence"; "planner_max_iterations";
        "provider";
        "system_prompt"; "temperature"; "top_p";
      ] in
      List.iter (fun field ->
        Alcotest.(check bool)
          (Printf.sprintf "lists %s" field)
          true (string_contains err field)
      ) all_fields
    end)

let test_system_prompt_exists () =
  Alcotest.(check bool) "system_prompt field exists" true
    (String.length default.system_prompt > 0)

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
      "default_mode", [
        Alcotest.test_case "default_is_build"           `Quick test_default_mode_is_build;
        Alcotest.test_case "roundtrip_plan"             `Quick test_json_roundtrip_default_mode_plan;
        Alcotest.test_case "legacy_no_field"            `Quick test_json_legacy_no_default_mode;
        Alcotest.test_case "legacy_plan_value"          `Quick test_json_legacy_plan_value;
      ];
      "show", [
        Alcotest.test_case "output"              `Quick test_show_output;
        Alcotest.test_case "custom_system_prompt" `Quick test_show_custom_system_prompt;
        Alcotest.test_case "default_mode"        `Quick test_show_default_mode;
      ];
      "update_field", [
        Alcotest.test_case "string_provider"            `Quick test_update_string_provider;
        Alcotest.test_case "string_api_key"             `Quick test_update_string_api_key;
        Alcotest.test_case "optional_string_set"        `Quick test_update_optional_string_set;
        Alcotest.test_case "optional_string_empty"      `Quick test_update_optional_string_empty_clears;
        Alcotest.test_case "optional_string_none"       `Quick test_update_optional_string_none_clears;
        Alcotest.test_case "float_temperature"          `Quick test_update_float_temperature;
        Alcotest.test_case "optional_float_set"         `Quick test_update_optional_float_set;
        Alcotest.test_case "optional_float_clear"       `Quick test_update_optional_float_clear;
        Alcotest.test_case "int_max_iterations"         `Quick test_update_int_max_iterations;
        Alcotest.test_case "int_planner_max_iterations" `Quick test_update_int_planner_max_iterations;
        Alcotest.test_case "int_checkpoint_interval"    `Quick test_update_int_checkpoint_interval;
        Alcotest.test_case "int_context_budget"         `Quick test_update_int_context_budget;
        Alcotest.test_case "optional_int_set"           `Quick test_update_optional_int_set;
        Alcotest.test_case "optional_int_clear"         `Quick test_update_optional_int_clear;
        Alcotest.test_case "bool_true"                  `Quick test_update_bool_true;
        Alcotest.test_case "bool_false"                 `Quick test_update_bool_false;
        Alcotest.test_case "bool_case_insensitive"      `Quick test_update_bool_case_insensitive;
        Alcotest.test_case "default_mode"               `Quick test_update_default_mode;
        Alcotest.test_case "persistence"                `Quick test_update_persistence;
        Alcotest.test_case "embedding_dimension"        `Quick test_update_embedding_dimension;
        Alcotest.test_case "db_uri"                     `Quick test_update_db_uri;
        Alcotest.test_case "event_retention_days"       `Quick test_update_event_retention_days;
        Alcotest.test_case "embedding_base_url"         `Quick test_update_embedding_base_url;
        Alcotest.test_case "saves_to_disk"              `Quick test_update_saves_to_disk;
        Alcotest.test_case "unknown_field"              `Quick test_update_unknown_field;
        Alcotest.test_case "system_prompt_rejected"     `Quick test_update_system_prompt_rejected;
        Alcotest.test_case "invalid_float"              `Quick test_update_invalid_float;
        Alcotest.test_case "invalid_int"                `Quick test_update_invalid_int;
        Alcotest.test_case "max_iterations_zero"        `Quick test_update_max_iterations_zero;
        Alcotest.test_case "checkpoint_interval_zero"   `Quick test_update_checkpoint_interval_zero;
        Alcotest.test_case "context_budget_too_low"     `Quick test_update_context_budget_too_low;
        Alcotest.test_case "max_tokens_zero"            `Quick test_update_max_tokens_zero;
        Alcotest.test_case "invalid_bool"               `Quick test_update_invalid_bool;
        Alcotest.test_case "invalid_default_mode"       `Quick test_update_invalid_default_mode;
        Alcotest.test_case "unknown_field_lists_all"    `Quick test_unknown_field_lists_all;
        Alcotest.test_case "system_prompt_exists"       `Quick test_system_prompt_exists;
      ];
    ]
