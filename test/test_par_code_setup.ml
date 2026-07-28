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
  [ "read_file"; "write_file"; "edit_file"; "grep"; "find_files"; "list_directory";
    "recall_memory"; "search_history";
    "git_status"; "git_log";
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
          event_retention_seconds = 0.0 }
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

(** Same filter as par_code_setup.ml lines 298-306. *)
let build_planner_descriptors () =
  let plan_exit_name = Par_code_plan_tools.plan_exit_tool.descriptor.Types.name in
  List.filter_map (fun name ->
    if List.mem name
         [ "read_file"; "grep"; "find_files"; "list_directory";
           "recall_memory"; "search_history"; "git_status"; "git_log" ]
       || name = plan_exit_name
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
          [ "read_file"; "grep"; "find_files"; "list_directory";
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

let () =
  Alcotest.run "par_setup"
    [ "planner_registration", [
        Alcotest.test_case "agent registered"        `Quick test_planner_agent_registered;
        Alcotest.test_case "tools subset exact"      `Quick test_planner_tools_subset_exact;
        Alcotest.test_case "no write tools"          `Quick test_planner_no_write_tools;
        Alcotest.test_case "max_iterations match"    `Quick test_planner_max_iterations_match;
      ] ]
