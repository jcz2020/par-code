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

let make_message (role : Types.message_role) (text : string) : Types.message =
  { role
  ; content_blocks = [Types.Text_block { text; cache_control = None }]
  ; tool_calls = None
  ; tool_call_id = None
  ; name = None
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
    ]
