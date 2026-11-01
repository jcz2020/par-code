(* test_par_code_setup.ml — Integration tests for planner agent registration.
 *
 * Approach: minimal Runtime via Eio_mock.Backend.run with mock tools,
 * then registers the planner agent using the same filter logic as
 * par_code_setup.ml. Exercises real Runtime APIs without LLM/persistence. *)

open Par

let mock_handler : Yojson.Safe.t -> Types.cancellation_token -> Types.handler_result =
  fun _input _tok -> Types.Success `Null

let make_mock_tool name =
  { Types.descriptor =
      { Types.name;
        description = Printf.sprintf "mock %s tool" name;
        input_schema = `Assoc [];
        output_schema = None;
        permission = Allow;
        timeout = None;
        concurrency_limit = None;
        on_update = None;
        cache_control = None };
    handler = mock_handler }

let all_tool_names =
  [ "read"; "write_file"; "edit_file"; "grep"; "find"; "ls";
    "recall_memory"; "search_history";
    "git_status"; "git_log";
    (* A write-capable tool the SDK added in 0.11 — the planner must filter
       it out like any other editor. *)
    "apply_patch";
    Par_code_plan_tools.plan_enter_tool.descriptor.Types.name;
    Par_code_plan_tools.plan_exit_tool.descriptor.Types.name ]

let test_model : Types.model_config =
  { provider = `Openai;
    model_name = "test-model";
    api_base = None;
    temperature = 0.0;
    max_tokens = None;
    top_p = None;
    stop_sequences = None }

let with_test_runtime f =
  Eio_mock.Backend.run (fun () ->
    Eio.Switch.run (fun sw ->
      let config : Types.runtime_config =
        { persistence = `Sqlite ":memory:";
          event_bus = Runtime.default_event_bus_config;
          default_quota = Runtime.default_quota;
          shutdown = Runtime.default_shutdown_config;
          llm_providers = [];
          eval_limits = { max_depth = 10; max_node_visits = 1000 };
          parallel_tool_execution = false;
          bash_confirm = Runtime.default_bash_confirm;
          event_retention_seconds = 0.0;
          max_tool_schema_tokens = None }
      in
      match Runtime.create ~config sw with
      | Error _ -> Alcotest.fail "Runtime.create failed"
      | Ok rt ->
        List.iter (fun name ->
          let tb = make_mock_tool name in
          match Runtime.register_tool rt
            ~name:tb.descriptor.Types.name
            ~description:tb.descriptor.Types.description
            ~input_schema:tb.descriptor.Types.input_schema
            ~handler:tb.handler
            () with
          | Ok _ -> ()
          | Error _ -> Alcotest.failf "register_tool %s failed" name)
          all_tool_names;
        f sw rt))

(** Uses the PRODUCTION allowlist from par_code_setup.ml, so this test guards
    the real filter instead of a copy of it. *)
let build_planner_descriptors () =
  List.filter_map (fun name ->
    if List.mem name Par_code_setup.planner_tool_names
    then Some { Types.name;
                description = Printf.sprintf "mock %s tool" name;
                input_schema = `Assoc [];
                output_schema = None;
                permission = Allow;
                timeout = None;
                concurrency_limit = None;
                on_update = None;
                cache_control = None }
    else None)
    all_tool_names

let register_planner_agent rt ~max_iterations =
  let planner_descriptors = build_planner_descriptors () in
  match Runtime.make_agent
    ~id:Par_code_mode.planner_agent_id
    ~system_prompt:(Types.stable_prompt "test planner agent")
    ~model:test_model
    ~tools:planner_descriptors
    ~max_iterations
    () with
  | Error e -> Alcotest.failf "make_agent failed: %s" (Par_code_setup.error_to_string e)
  | Ok agent ->
    (match Runtime.register_agent rt agent with
     | Error e -> Alcotest.failf "register_agent failed: %s" (Par_code_setup.error_to_string e)
     | Ok () -> agent)

let find_agent rt agent_id =
  let agents = Runtime.list_agents rt in
  List.find_opt (fun (a : Types.agent_config) -> a.id = agent_id) agents

let tool_names (agent : Types.agent_config) =
  List.map (fun (td : Types.tool_descriptor) -> td.name) agent.tools
  |> List.sort String.compare

let test_planner_agent_registered () =
  with_test_runtime (fun _sw rt ->
    let max_iterations = Par_code_config.default.Par_code_config.max_iterations in
    ignore (register_planner_agent rt ~max_iterations);
    match find_agent rt Par_code_mode.planner_agent_id with
    | None -> Alcotest.fail "planner agent not found in runtime"
    | Some agent ->
      Alcotest.(check string) "agent id is 'planner'"
        "planner" agent.Types.id)

let test_planner_tools_subset_exact () =
  with_test_runtime (fun _sw rt ->
    let max_iterations = Par_code_config.default.Par_code_config.max_iterations in
    ignore (register_planner_agent rt ~max_iterations);
    match find_agent rt Par_code_mode.planner_agent_id with
    | None -> Alcotest.fail "planner agent not found"
    | Some agent ->
      let expected =
        List.sort String.compare
          [ "read"; "grep"; "find"; "ls";
            "recall_memory"; "search_history"; "git_status"; "git_log"; "plan_exit" ]
      in
      let actual = tool_names agent in
      Alcotest.(check int) "tool count is 9"
        9 (List.length actual);
      Alcotest.(check (list string)) "exact tool list"
        expected actual)

let test_planner_no_write_tools () =
  with_test_runtime (fun _sw rt ->
    let max_iterations = Par_code_config.default.Par_code_config.max_iterations in
    ignore (register_planner_agent rt ~max_iterations);
    match find_agent rt Par_code_mode.planner_agent_id with
    | None -> Alcotest.fail "planner agent not found"
    | Some agent ->
      let names = tool_names agent in
      List.iter (fun forbidden ->
        Alcotest.(check bool)
          (Printf.sprintf "'%s' must NOT be in planner tools" forbidden)
          false (List.mem forbidden names))
        [ "write_file"; "edit_file"; "bash"; "plan_enter" ])

let test_planner_max_iterations_match () =
  with_test_runtime (fun _sw rt ->
    let expected_iterations = 42 in
    ignore (register_planner_agent rt ~max_iterations:expected_iterations);
    match find_agent rt Par_code_mode.planner_agent_id with
    | None -> Alcotest.fail "planner agent not found"
    | Some agent ->
      Alcotest.(check int) "max_iterations matches config"
        expected_iterations agent.Types.max_iterations)

(* The SDK version we build against must actually ship the tools the prompt
   tells the model about. This guards the floor: a downgrade or a rename
   upstream fails here instead of silently producing an agent that cannot
   follow its own instructions (the v0.7.4 release failed exactly this way
   when upstream added a required field). *)
let test_sdk_builtin_tool_inventory () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  match Par.Workspace.of_cwd () with
  | Error _ -> Alcotest.fail "workspace construction failed"
  | Ok ws ->
    let names =
      Par.Builtin_tools.builtin_tools ~switch:sw ~net ~workspace:ws
      |> List.map (fun (tb : Par.Types.tool_binding) -> tb.descriptor.name)
    in
    Alcotest.(check bool) "apply_patch ships in the builtin set" true
      (List.mem "apply_patch" names);
    Alcotest.(check bool) "edit and write still ship" true
      (List.mem "edit" names && List.mem "write" names);
    Alcotest.(check bool) "planner allowlist cannot see apply_patch" false
      (List.mem "apply_patch" Par_code_setup.planner_tool_names)

(* Deterministic check of the tool wiring, independent of any model: a valid
   unified diff must actually edit a file inside the workspace. This is the
   capability v0.7.5 claims, and it distinguishes "the tool is broken" from
   "the model produced a bad patch" when a live run fails. *)
let read_file path =
  let ic = open_in_bin path in
  let n = in_channel_length ic in
  let s = really_input_string ic n in
  close_in ic;
  s

let starts_with ~prefix s =
  String.length s >= String.length prefix
  && String.sub s 0 (String.length prefix) = prefix

let test_apply_patch_edits_workspace_file () =
  let tmpfile = Filename.temp_file "par_apply_patch_" "" in
  Sys.remove tmpfile;
  Unix.mkdir tmpfile 0o755;
  let file = Filename.concat tmpfile "a.ml" in
  let oc = open_out file in output_string oc "let a = 1\n"; close_out oc;
  Fun.protect
    ~finally:(fun () ->
      (try Sys.remove file with _ -> ());
      (try Sys.rmdir tmpfile with _ -> ()))
    (fun () ->
      Eio_main.run @@ fun env ->
      Eio.Switch.run @@ fun sw ->
      let net = Eio.Stdenv.net env in
      match Par.Workspace.of_dir tmpfile with
      | Error _ -> Alcotest.fail "workspace construction failed"
      | Ok ws ->
        let tools = Par.Builtin_tools.builtin_tools ~switch:sw ~net ~workspace:ws in
        match List.find_opt
                (fun (tb : Par.Types.tool_binding) -> tb.descriptor.name = "apply_patch")
                tools
        with
        | None -> Alcotest.fail "apply_patch not in the builtin set"
        | Some tb ->
          let patch =
            "--- a/a.ml\n+++ b/a.ml\n@@ -1 +1,2 @@\n+(* module a *)\n let a = 1\n" in
          let input = `Assoc [ "patch", `String patch; "dry_run", `Bool false ] in
          let tok : Par.Types.cancellation_token =
            { switch = sw; cancelled = false; reason = None } in
          (match tb.handler input tok with
           | Par.Types.Success _ ->
             let content = read_file file in
             Alcotest.(check bool) "patch applied to the workspace file" true
               (String.length content > 0
                && (let needle = "module a" in
                    let rec find i =
                      i + String.length needle <= String.length content
                      && (String.sub content i (String.length needle) = needle
                          || find (i + 1))
                    in
                    find 0))
           | Par.Types.Error e ->
             Alcotest.failf "apply_patch rejected a valid diff: %s" e.message
           | Par.Types.Handoff _ | Par.Types.Approval_required _ ->
             Alcotest.fail "apply_patch must neither hand off nor require approval"))

(* Multi-file patches need a `diff --git` header per file section: a bare
   concatenation of two `--- a/x` / `+++ b/x` pairs is mis-parsed as hunk content
   (the second header gets swallowed). This pins the form that works. *)
let test_apply_patch_multi_file () =
  let dir = Filename.temp_file "par_apply_patch_multi_" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  let a = Filename.concat dir "a.ml" and b = Filename.concat dir "b.ml" in
  List.iter
    (fun (p, s) -> let oc = open_out p in output_string oc s; close_out oc)
    [ a, "let a = 1\n"; b, "let b = 2\n" ];
  Fun.protect
    ~finally:(fun () ->
      List.iter (fun p -> try Sys.remove p with _ -> ()) [ a; b ];
      (try Sys.rmdir dir with _ -> ()))
    (fun () ->
      Eio_main.run @@ fun env ->
      Eio.Switch.run @@ fun sw ->
      let net = Eio.Stdenv.net env in
      match Par.Workspace.of_dir dir with
      | Error _ -> Alcotest.fail "workspace construction failed"
      | Ok ws ->
        let tools = Par.Builtin_tools.builtin_tools ~switch:sw ~net ~workspace:ws in
        match List.find_opt
                (fun (tb : Par.Types.tool_binding) -> tb.descriptor.name = "apply_patch")
                tools
        with
        | None -> Alcotest.fail "apply_patch not in the builtin set"
        | Some tb ->
          let patch =
            "diff --git a/a.ml b/a.ml\n--- a/a.ml\n+++ b/a.ml\n@@ -1 +1,2 @@\n+(* module a *)\n let a = 1\n"
            ^ "diff --git a/b.ml b/b.ml\n--- a/b.ml\n+++ b/b.ml\n@@ -1 +1,2 @@\n+(* module b *)\n let b = 2\n" in
          let input = `Assoc [ "patch", `String patch; "dry_run", `Bool false ] in
          let tok : Par.Types.cancellation_token =
            { switch = sw; cancelled = false; reason = None } in
          (match tb.handler input tok with
          | Par.Types.Success _ ->
            Alcotest.(check bool) "a.ml patched" true
              (starts_with ~prefix:"(* module a *)" (read_file a));
            Alcotest.(check bool) "b.ml patched" true
              (starts_with ~prefix:"(* module b *)" (read_file b))
          | Par.Types.Error e ->
            Alcotest.failf "apply_patch rejected a valid multi-file diff: %s" e.message
          | Par.Types.Handoff _ | Par.Types.Approval_required _ ->
            Alcotest.fail "apply_patch must neither hand off nor require approval"))

let () =
  Alcotest.run "par_setup"
    [ "planner_registration", [
        Alcotest.test_case "agent registered"        `Quick test_planner_agent_registered;
        Alcotest.test_case "tools subset exact"      `Quick test_planner_tools_subset_exact;
        Alcotest.test_case "no write tools"          `Quick test_planner_no_write_tools;
        Alcotest.test_case "max_iterations match"    `Quick test_planner_max_iterations_match;
      ];
      "sdk_surface", [
        Alcotest.test_case "builtin inventory matches prompt" `Quick test_sdk_builtin_tool_inventory;
        Alcotest.test_case "apply_patch edits a workspace file" `Quick test_apply_patch_edits_workspace_file;
        Alcotest.test_case "apply_patch applies a multi-file patch" `Quick test_apply_patch_multi_file;
      ] ]
