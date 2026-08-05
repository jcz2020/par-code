open Par

let failf fmt = Printf.ksprintf (fun s -> Alcotest.fail s) fmt

let string_contains s sub =
  let len_s = String.length s in
  let len_sub = String.length sub in
  let rec search i =
    if i + len_sub > len_s then false
    else if String.sub s i len_sub = sub then true
    else search (i + 1)
  in
  len_sub = 0 || search 0

let make_message (role : Types.message_role) (text : string) : Types.message =
  { role
  ; content_blocks = [Types.Text_block { text; cache_control = None }]
  ; tool_calls = None
  ; tool_call_id = None
  ; name = None
  ; reasoning_content = None
  }

let make_conv (msgs : (Types.message_role * string) list) : Types.conversation =
  { messages = List.map (fun (r, t) -> make_message r t) msgs
  ; metadata = []
  }

let with_test_token (f : Types.cancellation_token -> unit) =
  Eio_mock.Backend.run (fun () ->
    Eio.Switch.run (fun sw ->
      let tok = Cancellation.create_token sw in
      f tok
    )
  )

let setup () = Par_code_mode.current := Build

let rec rm_rf p =
  if Sys.file_exists p then
    if Sys.is_directory p then begin
      Array.iter (fun e -> rm_rf (Filename.concat p e)) (Sys.readdir p);
      Unix.rmdir p
    end else Sys.remove p

let with_temp_dir (f : string -> unit) =
  let tmpfile = Filename.temp_file "par_plan_test_" "" in
  Sys.remove tmpfile;
  Unix.mkdir tmpfile 0o755;
  Fun.protect
    ~finally:(fun () -> rm_rf tmpfile)
    (fun () -> f tmpfile)

(* -- Schema / structure tests --------------------------------------------- *)

let test_plan_enter_tool_name () =
  Alcotest.(check string) "plan_enter tool name"
    "plan_enter" Par_code_plan_tools.plan_enter_tool.descriptor.Types.name

let test_plan_exit_tool_name () =
  Alcotest.(check string) "plan_exit tool name"
    "plan_exit" Par_code_plan_tools.plan_exit_tool.descriptor.Types.name

let test_plan_enter_input_schema_empty () =
  let schema = Par_code_plan_tools.plan_enter_tool.descriptor.Types.input_schema in
  let expected = `Assoc
    [ ("type", `String "object")
    ; ("properties", `Assoc [])
    ; ("required", `List [])
    ]
  in
  Alcotest.(check string) "plan_enter input_schema"
    (Yojson.Safe.to_string expected) (Yojson.Safe.to_string schema)

let test_plan_exit_input_schema_empty () =
  let schema = Par_code_plan_tools.plan_exit_tool.descriptor.Types.input_schema in
  let expected = `Assoc
    [ ("type", `String "object")
    ; ("properties", `Assoc [])
    ; ("required", `List [])
    ]
  in
  Alcotest.(check string) "plan_exit input_schema"
    (Yojson.Safe.to_string expected) (Yojson.Safe.to_string schema)

(* -- Handler behavior tests ----------------------------------------------- *)

let test_plan_enter_handler_switches_to_plan () =
  setup ();
  with_test_token (fun tok ->
    let result = Par_code_plan_tools.plan_enter_handler `Null tok in
    Alcotest.(check bool) "current is Plan" true
      (!Par_code_mode.current = Par_code_mode.Plan);
    match result with
    | Types.Success json ->
      let open Yojson.Safe.Util in
      let ok = json |> member "ok" |> to_bool in
      let mode = json |> member "mode" |> to_string in
      Alcotest.(check bool) "ok is true" true ok;
      Alcotest.(check string) "mode is plan" "plan" mode
    | Types.Error _ -> Alcotest.fail "expected Success, got Error"
    | Types.Handoff _ -> Alcotest.fail "expected Success, got Handoff"
    | Types.Approval_required _ -> Alcotest.fail "expected Success, got Approval_required"
  )

let test_plan_enter_handler_returns_previous_mode () =
  Par_code_mode.current := Par_code_mode.Plan;
  with_test_token (fun tok ->
    let result = Par_code_plan_tools.plan_enter_handler `Null tok in
    match result with
    | Types.Success json ->
      let open Yojson.Safe.Util in
      let prev = json |> member "previous_mode" |> to_string in
      Alcotest.(check string) "previous_mode is plan" "plan" prev
    | _ -> Alcotest.fail "expected Success"
  )

let test_plan_exit_handler_switches_to_build () =
  Par_code_mode.current := Par_code_mode.Plan;
  with_test_token (fun tok ->
    let result = Par_code_plan_tools.plan_exit_handler `Null tok in
    Alcotest.(check bool) "current is Build" true
      (!Par_code_mode.current = Par_code_mode.Build);
    match result with
    | Types.Success json ->
      let open Yojson.Safe.Util in
      let ok = json |> member "ok" |> to_bool in
      let mode = json |> member "mode" |> to_string in
      Alcotest.(check bool) "ok is true" true ok;
      Alcotest.(check string) "mode is build" "build" mode
    | _ -> Alcotest.fail "expected Success"
  )

let test_plan_exit_handler_returns_no_plan () =
  setup ();
  with_test_token (fun tok ->
    let result = Par_code_plan_tools.plan_exit_handler `Null tok in
    match result with
    | Types.Success json ->
      let open Yojson.Safe.Util in
      let saved = json |> member "plan_saved_to" in
      Alcotest.(check string) "plan_saved_to is null"
        "null" (Yojson.Safe.to_string saved)
    | _ -> Alcotest.fail "expected Success"
  )

(* -- persist_plan_file tests ---------------------------------------------- *)

let test_persist_writes_to_temp_dir () =
  with_temp_dir (fun tmpdir ->
    let old_cwd = Sys.getcwd () in
    Sys.chdir tmpdir;
    Fun.protect ~finally:(fun () -> Sys.chdir old_cwd) (fun () ->
      let conv = make_conv
        [ (Types.User, "plan this feature")
        ; (Types.Assistant, "## Goal\nBuild the feature\n\n## Steps\n1. Do stuff")
        ]
      in
      match Par_code_plan_tools.persist_plan_file conv with
      | Some path ->
        Alcotest.(check bool) "file exists" true (Sys.file_exists path);
        let content = In_channel.with_open_bin path In_channel.input_all in
        Alcotest.(check bool) "content contains plan body" true
          (string_contains content "Build the feature")
      | None -> Alcotest.fail "persist_plan_file returned None"
    )
  )

let test_persist_lazy_creates_plans_dir () =
  with_temp_dir (fun tmpdir ->
    let old_cwd = Sys.getcwd () in
    Sys.chdir tmpdir;
    Fun.protect ~finally:(fun () -> Sys.chdir old_cwd) (fun () ->
      let plans_dir = Filename.concat (Filename.concat tmpdir ".par") "plans" in
      Alcotest.(check bool) ".par/plans/ does not exist before" false
        (Sys.file_exists plans_dir);
      let conv = make_conv
        [ (Types.Assistant, "plan content here") ]
      in
      (match Par_code_plan_tools.persist_plan_file conv with
       | Some _ ->
         Alcotest.(check bool) ".par/plans/ was created" true
           (Sys.file_exists plans_dir && Sys.is_directory plans_dir)
       | None -> Alcotest.fail "persist_plan_file returned None")
    )
  )

let test_persist_filename_is_iso8601 () =
  with_temp_dir (fun tmpdir ->
    let old_cwd = Sys.getcwd () in
    Sys.chdir tmpdir;
    Fun.protect ~finally:(fun () -> Sys.chdir old_cwd) (fun () ->
      let conv = make_conv
        [ (Types.Assistant, "some plan") ]
      in
      match Par_code_plan_tools.persist_plan_file conv with
      | Some path ->
        let basename = Filename.basename path in
        let regex = Str.regexp "^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]-[0-9][0-9]-[0-9][0-9]Z\\.md$" in
        Alcotest.(check bool) "filename matches ISO8601 pattern" true
          (Str.string_match regex basename 0)
      | None -> Alcotest.fail "persist_plan_file returned None"
    )
  )

let test_persist_no_assistant_returns_none () =
  with_temp_dir (fun tmpdir ->
    let old_cwd = Sys.getcwd () in
    Sys.chdir tmpdir;
    Fun.protect ~finally:(fun () -> Sys.chdir old_cwd) (fun () ->
      let conv = make_conv
        [ (Types.User, "help me plan this")
        ; (Types.Tool, "tool output")
        ]
      in
      match Par_code_plan_tools.persist_plan_file conv with
      | None -> ()
      | Some _ -> Alcotest.fail "expected None for conversation without assistant"
    )
  )

let test_persist_no_permission_returns_none () =
  if Unix.getuid () = 0 then
    Alcotest.(check (unit)) "skip when root" () ()
  else
  with_temp_dir (fun tmpdir ->
    let old_cwd = Sys.getcwd () in
    Sys.chdir tmpdir;
    Fun.protect ~finally:(fun () ->
      Sys.chdir old_cwd;
      let par_dir = Filename.concat tmpdir ".par" in
      if Sys.file_exists par_dir then
        (try Unix.chmod par_dir 0o755 with _ -> ())
    ) (fun () ->
      let par_dir = Filename.concat tmpdir ".par" in
      Unix.mkdir par_dir 0o755;
      let plans_dir = Filename.concat par_dir "plans" in
      Unix.mkdir plans_dir 0o555;
      let conv = make_conv
        [ (Types.Assistant, "a plan") ]
      in
      match Par_code_plan_tools.persist_plan_file conv with
      | None -> ()
      | Some _ -> Alcotest.fail "expected None when plans dir is read-only"
    )
  )

(* -- parse_plan_timestamp tests ------------------------------------------- *)

let test_parse_valid_timestamp () =
  match Par_code_plan_tools.parse_plan_timestamp "2026-07-27T14-30-00Z.md" with
  | Some ts ->
    (* Exact value from the code's JDN float formula *)
    Alcotest.(check (float 1.0)) "timestamp value" 1785162600.0 ts
  | None -> Alcotest.fail "expected Some for valid timestamp"

let test_parse_without_md_extension () =
  let with_md = Par_code_plan_tools.parse_plan_timestamp "2026-07-27T14-30-00Z.md" in
  let without_md = Par_code_plan_tools.parse_plan_timestamp "2026-07-27T14-30-00Z" in
  match (with_md, without_md) with
  | Some a, Some b ->
    Alcotest.(check (float 1.0)) "same timestamp" a b
  | _ -> Alcotest.fail "expected Some for both with and without .md"

let test_parse_invalid_filename () =
  match Par_code_plan_tools.parse_plan_timestamp "not-a-timestamp.md" with
  | None -> ()
  | Some _ -> Alcotest.fail "expected None for invalid filename"

let test_parse_empty_string () =
  match Par_code_plan_tools.parse_plan_timestamp "" with
  | None -> ()
  | Some _ -> Alcotest.fail "expected None for empty string"

(* -- list_plans tests ----------------------------------------------------- *)

let make_plans_dir tmp =
  let par_dir = Filename.concat tmp ".par" in
  let plans_dir = Filename.concat par_dir "plans" in
  (try Unix.mkdir par_dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  (try Unix.mkdir plans_dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  plans_dir

let write_file path content =
  let oc = open_out path in
  Fun.protect ~finally:(fun () -> close_out oc)
    (fun () -> output_string oc content)

let test_list_plans_empty_dir () =
  with_temp_dir (fun tmpdir ->
    let old_cwd = Sys.getcwd () in
    Sys.chdir tmpdir;
    Fun.protect ~finally:(fun () -> Sys.chdir old_cwd) (fun () ->
      match Par_code_plan_tools.list_plans ~limit:10 with
      | Ok [] -> ()
      | Ok _  -> Alcotest.fail "expected empty list when .par/plans doesn't exist"
      | Error (`Plan_error msg) -> failf "list_plans error: %s" msg))

let test_list_plans_with_files () =
  with_temp_dir (fun tmpdir ->
    let old_cwd = Sys.getcwd () in
    Sys.chdir tmpdir;
    Fun.protect ~finally:(fun () -> Sys.chdir old_cwd) (fun () ->
      let plans_dir = make_plans_dir tmpdir in
      write_file (Filename.concat plans_dir "2026-07-25T10-00-00Z.md") "plan A";
      write_file (Filename.concat plans_dir "2026-07-27T14-30-00Z.md") "plan B";
      write_file (Filename.concat plans_dir "2026-07-26T12-00-00Z.md") "plan C";
      match Par_code_plan_tools.list_plans ~limit:10 with
      | Ok entries ->
        Alcotest.(check int) "count" 3 (List.length entries);
        let filenames =
          List.map (fun (e : Par_code_plan_tools.plan_entry) -> e.filename) entries
        in
        Alcotest.(check (list string)) "sorted newest-first"
          [ "2026-07-27T14-30-00Z.md"
          ; "2026-07-26T12-00-00Z.md"
          ; "2026-07-25T10-00-00Z.md"
          ] filenames;
        List.iter (fun (e : Par_code_plan_tools.plan_entry) ->
          Alcotest.(check bool) "size > 0" true (e.size > 0)) entries;
        List.iter (fun (e : Par_code_plan_tools.plan_entry) ->
          match e.timestamp with
          | Some _ -> ()
          | None -> failf "expected timestamp for %s" e.filename) entries
      | Error (`Plan_error msg) -> failf "list_plans error: %s" msg))

let test_list_plans_limit () =
  with_temp_dir (fun tmpdir ->
    let old_cwd = Sys.getcwd () in
    Sys.chdir tmpdir;
    Fun.protect ~finally:(fun () -> Sys.chdir old_cwd) (fun () ->
      let plans_dir = make_plans_dir tmpdir in
      for i = 1 to 5 do
        let name = Printf.sprintf "2026-07-%02dT10-00-00Z.md" (20 + i) in
        write_file (Filename.concat plans_dir name) (Printf.sprintf "plan %d" i)
      done;
      match Par_code_plan_tools.list_plans ~limit:2 with
      | Ok entries ->
        Alcotest.(check int) "limited to 2" 2 (List.length entries)
      | Error (`Plan_error msg) -> failf "list_plans error: %s" msg))

(* -- show_plan tests ------------------------------------------------------ *)

let test_show_plan_existing () =
  with_temp_dir (fun tmpdir ->
    let old_cwd = Sys.getcwd () in
    Sys.chdir tmpdir;
    Fun.protect ~finally:(fun () -> Sys.chdir old_cwd) (fun () ->
      let plans_dir = make_plans_dir tmpdir in
      let content = "# My Plan\n\nDo the thing." in
      write_file (Filename.concat plans_dir "2026-07-27T14-30-00Z.md") content;
      match Par_code_plan_tools.show_plan "2026-07-27T14-30-00Z.md" with
      | Ok text -> Alcotest.(check string) "content" content text
      | Error (`Plan_error msg) -> failf "show_plan error: %s" msg))

let test_show_plan_auto_md () =
  with_temp_dir (fun tmpdir ->
    let old_cwd = Sys.getcwd () in
    Sys.chdir tmpdir;
    Fun.protect ~finally:(fun () -> Sys.chdir old_cwd) (fun () ->
      let plans_dir = make_plans_dir tmpdir in
      let content = "# Auto MD Plan" in
      write_file (Filename.concat plans_dir "2026-07-27T14-30-00Z.md") content;
      match Par_code_plan_tools.show_plan "2026-07-27T14-30-00Z" with
      | Ok text -> Alcotest.(check string) "content" content text
      | Error (`Plan_error msg) -> failf "show_plan auto .md error: %s" msg))

let test_show_plan_not_found () =
  with_temp_dir (fun tmpdir ->
    let old_cwd = Sys.getcwd () in
    Sys.chdir tmpdir;
    Fun.protect ~finally:(fun () -> Sys.chdir old_cwd) (fun () ->
      let _ = make_plans_dir tmpdir in
      match Par_code_plan_tools.show_plan "nonexistent.md" with
      | Ok _ -> Alcotest.fail "expected Error for non-existent file"
      | Error (`Plan_error _) -> ()))

(* -- prune_plans tests ---------------------------------------------------- *)

let test_prune_old_files () =
  with_temp_dir (fun tmpdir ->
    let old_cwd = Sys.getcwd () in
    Sys.chdir tmpdir;
    Fun.protect ~finally:(fun () -> Sys.chdir old_cwd) (fun () ->
      let plans_dir = make_plans_dir tmpdir in
      write_file (Filename.concat plans_dir "2020-01-01T00-00-00Z.md") "old plan";
      write_file (Filename.concat plans_dir "2026-07-27T14-30-00Z.md") "recent plan";
      match Par_code_plan_tools.prune_plans ~older_than_days:30 with
      | Ok n ->
        Alcotest.(check int) "pruned count" 1 n;
        Alcotest.(check bool) "old file deleted" false
          (Sys.file_exists (Filename.concat plans_dir "2020-01-01T00-00-00Z.md"));
        Alcotest.(check bool) "recent file kept" true
          (Sys.file_exists (Filename.concat plans_dir "2026-07-27T14-30-00Z.md"))
      | Error (`Plan_error msg) -> failf "prune_plans error: %s" msg))

let test_prune_keeps_recent () =
  with_temp_dir (fun tmpdir ->
    let old_cwd = Sys.getcwd () in
    Sys.chdir tmpdir;
    Fun.protect ~finally:(fun () -> Sys.chdir old_cwd) (fun () ->
      let plans_dir = make_plans_dir tmpdir in
      write_file (Filename.concat plans_dir "2026-07-27T14-30-00Z.md") "recent A";
      write_file (Filename.concat plans_dir "2026-07-26T10-00-00Z.md") "recent B";
      match Par_code_plan_tools.prune_plans ~older_than_days:365 with
      | Ok n ->
        Alcotest.(check int) "none pruned" 0 n;
        Alcotest.(check bool) "file A exists" true
          (Sys.file_exists (Filename.concat plans_dir "2026-07-27T14-30-00Z.md"));
        Alcotest.(check bool) "file B exists" true
          (Sys.file_exists (Filename.concat plans_dir "2026-07-26T10-00-00Z.md"))
      | Error (`Plan_error msg) -> failf "prune_plans error: %s" msg))

let test_prune_no_files () =
  with_temp_dir (fun tmpdir ->
    let old_cwd = Sys.getcwd () in
    Sys.chdir tmpdir;
    Fun.protect ~finally:(fun () -> Sys.chdir old_cwd) (fun () ->
      let _ = make_plans_dir tmpdir in
      match Par_code_plan_tools.prune_plans ~older_than_days:30 with
      | Ok n -> Alcotest.(check int) "empty dir prune" 0 n
      | Error (`Plan_error msg) -> failf "prune_plans error: %s" msg))

let test_prune_undated_file () =
  with_temp_dir (fun tmpdir ->
    let old_cwd = Sys.getcwd () in
    Sys.chdir tmpdir;
    Fun.protect ~finally:(fun () -> Sys.chdir old_cwd) (fun () ->
      let plans_dir = make_plans_dir tmpdir in
      write_file (Filename.concat plans_dir "my-plan.md") "undated plan";
      match Par_code_plan_tools.prune_plans ~older_than_days:0 with
      | Ok n ->
        Alcotest.(check int) "undated not pruned" 0 n;
        Alcotest.(check bool) "undated file kept" true
          (Sys.file_exists (Filename.concat plans_dir "my-plan.md"))
      | Error (`Plan_error msg) -> failf "prune_plans error: %s" msg))

(* -- Test registration ---------------------------------------------------- *)

let () =
  Alcotest.run "par_plan_tools"
    [ "schema", [
        Alcotest.test_case "plan_enter tool name"      `Quick test_plan_enter_tool_name;
        Alcotest.test_case "plan_exit tool name"       `Quick test_plan_exit_tool_name;
        Alcotest.test_case "plan_enter schema empty"   `Quick test_plan_enter_input_schema_empty;
        Alcotest.test_case "plan_exit schema empty"    `Quick test_plan_exit_input_schema_empty;
      ];
      "handlers", [
        Alcotest.test_case "enter switches to plan"       `Quick test_plan_enter_handler_switches_to_plan;
        Alcotest.test_case "enter returns previous mode"  `Quick test_plan_enter_handler_returns_previous_mode;
        Alcotest.test_case "exit switches to build"       `Quick test_plan_exit_handler_switches_to_build;
        Alcotest.test_case "exit returns no plan"         `Quick test_plan_exit_handler_returns_no_plan;
      ];
      "persist", [
        Alcotest.test_case "writes to temp dir"          `Quick test_persist_writes_to_temp_dir;
        Alcotest.test_case "lazy creates plans dir"      `Quick test_persist_lazy_creates_plans_dir;
        Alcotest.test_case "filename is iso8601"         `Quick test_persist_filename_is_iso8601;
        Alcotest.test_case "no assistant returns None"   `Quick test_persist_no_assistant_returns_none;
        Alcotest.test_case "no permission returns None"  `Quick test_persist_no_permission_returns_none;
      ];
      "parse_plan_timestamp", [
        Alcotest.test_case "valid_timestamp"       `Quick test_parse_valid_timestamp;
        Alcotest.test_case "without_md_extension"  `Quick test_parse_without_md_extension;
        Alcotest.test_case "invalid_filename"      `Quick test_parse_invalid_filename;
        Alcotest.test_case "empty_string"          `Quick test_parse_empty_string;
      ];
      "list_plans", [
        Alcotest.test_case "empty_dir"   `Quick test_list_plans_empty_dir;
        Alcotest.test_case "with_files"  `Quick test_list_plans_with_files;
        Alcotest.test_case "limit"       `Quick test_list_plans_limit;
      ];
      "show_plan", [
        Alcotest.test_case "existing"    `Quick test_show_plan_existing;
        Alcotest.test_case "auto_md"     `Quick test_show_plan_auto_md;
        Alcotest.test_case "not_found"   `Quick test_show_plan_not_found;
      ];
      "prune_plans", [
        Alcotest.test_case "old_files"       `Quick test_prune_old_files;
        Alcotest.test_case "keeps_recent"    `Quick test_prune_keeps_recent;
        Alcotest.test_case "no_files"        `Quick test_prune_no_files;
        Alcotest.test_case "undated_file"    `Quick test_prune_undated_file;
      ];
    ]
