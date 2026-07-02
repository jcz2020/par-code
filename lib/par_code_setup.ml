(* par_code_setup.ml — Runtime bootstrap layer (方案 C).
 *
 * Encapsulates PAR SDK wiring: persistence, LLM/embedding services, runtime
 * creation, builtin-tool registration, bash-tool install, agent registration.
 * bin/main.ml calls [setup_runtime] instead of duplicating PAR's bin/main.ml.
 *
 * Retirement condition: if PAR exposes a public bootstrap library, migrate
 * this module to delegate to it. *)

open Par

let error_to_string (e : Types.error_category) =
  match e with
  | Types.Timeout -> "Timeout"
  | Types.Invalid_input s -> Printf.sprintf "Invalid input: %s" s
  | Types.External_failure s -> Printf.sprintf "External failure: %s" s
  | Types.Rate_limited -> "Rate limited"
  | Types.Permission_denied s -> Printf.sprintf "Permission denied: %s" s
  | Types.Internal s -> Printf.sprintf "Internal error: %s" s
  | Types.Embedding_unsupported -> "Embedding unsupported"

let ensure_rng () = Mirage_crypto_rng_unix.use_default ()

let make_persistence_service (cfg : Par_code_config.config) =
  let path = Par_code_config.db_path () in
  let retention = cfg.Par_code_config.event_retention_days *. 24. *. 60. *. 60. in
  match Sqlite_persistence.create ~retention_ttl:retention path with
  | Error e ->
    Printf.eprintf "Error opening SQLite database (%s): %s\n%!" path (error_to_string e);
    exit 1
  | Ok t ->
    { Types.
      save_events_fn = (fun events -> Sqlite_persistence.save_events t events);
      load_events_fn = (fun task_id -> Sqlite_persistence.load_events t task_id);
      load_events_by_session_fn = (fun sid -> Sqlite_persistence.load_events_by_session t sid);
      load_sessions_fn = (fun limit -> Sqlite_persistence.load_sessions t limit);
      save_task_state_fn = (fun ts -> Sqlite_persistence.save_task_state t ts);
      load_task_state_fn = (fun task_id -> Sqlite_persistence.load_task_state t task_id);
      save_workflow_state_fn = (fun id status ckpt -> Sqlite_persistence.save_workflow_state t id status ckpt);
      load_workflow_state_fn = (fun id -> Sqlite_persistence.load_workflow_state t id);
      load_all_suspended_workflows_fn = (fun () -> Sqlite_persistence.load_all_suspended_workflows t);
      save_workflow_def_fn = (fun id def -> Sqlite_persistence.save_workflow_def t id def);
      load_all_workflow_defs_fn = (fun () -> Sqlite_persistence.load_all_workflow_defs t);
      save_conversation_fn = (fun sid conv -> Sqlite_persistence.save_conversation t sid conv);
      load_conversation_fn = (fun sid -> Sqlite_persistence.load_conversation t sid);
      load_most_recent_conversation_fn = (fun () -> Sqlite_persistence.load_most_recent_conversation t);
      close_fn = (fun () -> Sqlite_persistence.close t);
    }

let make_llm_service (tag : Par_code_config.provider_tag) api_key api_base
    (net : [< `Generic | `Unix > `Generic ] Eio.Net.ty Eio.Resource.t) =
  let open Types in
  let net_gen = (net :> [ `Generic ] Eio.Net.ty Eio.Net.t) in
  let wrap_openai ?(base_url = api_base) () =
    let cfg = Openai { api_key; base_url; organization = None; embedding_model = None; prompt_cache_key = None } in
    match Openai_provider.create cfg with
    | Error e ->
      Printf.eprintf "Error creating OpenAI provider: %s\n%!" (error_to_string e);
      exit 1
    | Ok t ->
      Openai_provider.set_network t net_gen;
      { complete_fn = (fun mc tools conv -> Openai_provider.complete t mc tools conv);
        stream_fn = (fun mc tools conv sc cb -> Openai_provider.stream t mc tools conv sc cb);
        close_fn = (fun () -> Openai_provider.close t);
        complete_structured_fn = Some (fun mc tools conv schema -> Openai_provider.complete_structured t mc tools conv schema);
        list_models_fn = None;
        supports_native_tools_fn = None;
        context_window_fn = None;
        cache_control_fn = None; }
  in
  match tag with
  | `Openai -> wrap_openai ()
  | `Ollama -> wrap_openai ~base_url:(Some "http://localhost:11434/v1") ()
  | `Custom _ ->
    (match api_base with
     | None ->
       Printf.eprintf "Error: custom provider requires --api-base\n%!";
       exit 1
     | _ -> wrap_openai ())
  | `Anthropic ->
    let cfg = Anthropic { api_key; base_url = api_base } in
    (match Anthropic_provider.create cfg with
     | Error e ->
       Printf.eprintf "Error creating Anthropic provider: %s\n%!" (error_to_string e);
       exit 1
     | Ok t ->
       Anthropic_provider.set_network t net_gen;
       { complete_fn = (fun mc tools conv -> Anthropic_provider.complete t mc tools conv);
         stream_fn = (fun mc tools conv sc cb -> Anthropic_provider.stream t mc tools conv sc cb);
         close_fn = (fun () -> Anthropic_provider.close t);
         complete_structured_fn = Some (fun mc tools conv schema -> Anthropic_provider.complete_structured t mc tools conv schema);
         list_models_fn = None;
         supports_native_tools_fn = None;
         context_window_fn = None;
         cache_control_fn = None; })

let make_embedding_service (tag : Par_code_config.provider_tag) api_key api_base
    (net : [< `Generic | `Unix > `Generic ] Eio.Net.ty Eio.Resource.t) =
  let open Types in
  let net_gen = (net :> [ `Generic ] Eio.Net.ty Eio.Net.t) in
  match tag with
  | `Anthropic ->
    { embed_fn = (fun _msgs -> Error Embedding_unsupported);
      close_fn = ignore }
  | `Custom _ ->
    Printf.eprintf "Error: custom provider embeddings not supported\n%!";
    exit 1
  | (`Openai | `Ollama) as t ->
    let base_url = match t with `Ollama -> Some "http://localhost:11434/v1" | _ -> api_base in
    let cfg = Openai { api_key; base_url; organization = None; embedding_model = None; prompt_cache_key = None } in
    (match Openai_provider.create cfg with
     | Error e ->
       Printf.eprintf "Error creating embedding provider: %s\n%!" (error_to_string e);
       exit 1
     | Ok t ->
       Openai_provider.set_network t net_gen;
       { embed_fn = (fun msgs -> Openai_provider.embed t msgs);
         close_fn = (fun () -> Openai_provider.close t) })

let make_runtime_config (cfg : Par_code_config.config) =
  { Types.
    persistence = Par_code_config.to_persistence_config cfg;
    event_bus = Runtime.default_event_bus_config;
    default_quota = Runtime.default_quota;
    shutdown = Runtime.default_shutdown_config;
    llm_providers = [];
    eval_limits = { max_depth = 10; max_node_visits = 1000 };
    parallel_tool_execution = cfg.Par_code_config.parallel_tool_execution;
    bash_confirm = Runtime.default_bash_confirm;
    event_retention_seconds = cfg.Par_code_config.event_retention_days *. 24. *. 60. *. 60.;
  }

let agent_id = "par-code"

let setup_runtime (cfg : Par_code_config.config) ~f =
  ensure_rng ();
  let pers = make_persistence_service cfg in
  let persistence_config = Par_code_config.to_persistence_config cfg in
  let provider_tag = Par_code_config.to_provider_tag cfg in
  let runtime_config = make_runtime_config cfg in
  let _ = persistence_config in
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun switch ->
  let net = Eio.Stdenv.net env in
  let llm = make_llm_service provider_tag cfg.Par_code_config.api_key cfg.Par_code_config.api_base net in
  let embeddings = make_embedding_service provider_tag cfg.Par_code_config.api_key cfg.Par_code_config.api_base net in
  match Runtime.create ~persistence:pers ~llm ~embeddings ~config:runtime_config switch with
  | Error e ->
    Printf.eprintf "Error creating runtime: %s\n%!" (error_to_string e);
    exit 1
  | Ok rt ->
    let tools = Builtin_tools.builtin_tools ~switch ~net ~workspace:(Runtime.workspace rt) in
    List.iter (fun (tb : Types.tool_binding) ->
      (match Runtime.register_tool rt
         ~name:tb.descriptor.Types.name
         ~description:tb.descriptor.Types.description
         ~input_schema:tb.descriptor.Types.input_schema
         ~handler:tb.handler
         ?permission:(match tb.descriptor.Types.permission with Types.Allow -> None | p -> Some p)
         ?timeout:tb.descriptor.Types.timeout
         ?concurrency_limit:tb.descriptor.Types.concurrency_limit
         () with
       | Ok _ -> ()
       | Error e ->
         Printf.eprintf "Failed to register tool %s: %s\n%!"
           tb.descriptor.Types.name (error_to_string e);
         exit 1)
    ) tools;
    (match Runtime.install_bash_tool
       ~process_mgr:(Eio.Stdenv.process_mgr env)
       ~clock:(Eio.Stdenv.clock env)
       rt with
     | Ok _ -> ()
     | Error e ->
       Printf.eprintf "Warning: bash tool not installed: %s\n%!" (error_to_string e));
    let descriptors = List.map (fun (tb : Types.tool_binding) -> tb.descriptor) tools in
    let model_cfg = Par_code_config.to_model_config cfg in
    (match Runtime.make_agent
       ~id:agent_id
       ~system_prompt:(Types.stable_prompt cfg.Par_code_config.system_prompt)
       ~model:model_cfg
       ~tools:descriptors
       ~max_iterations:cfg.Par_code_config.max_iterations
       () with
     | Error e ->
       Printf.eprintf "Agent validation failed: %s\n%!" (error_to_string e);
       exit 1
     | Ok agent ->
       (match Runtime.register_agent rt agent with
        | Error e ->
          Printf.eprintf "Error registering agent: %s\n%!" (error_to_string e);
          exit 1
        | Ok () -> ()));
    Runtime.register_tool_call_hook rt
      (Bash_confirm.make_hook ?confirm_fn:(Some (fun cmd ->
           Printf.eprintf "\n⚠ bash: %s [y/N] " cmd;
           flush stderr;
           match input_line stdin with
           | line when String.lowercase_ascii (String.trim line) = "y" -> true
           | exception _ -> false
           | _ -> false)) Runtime.default_bash_confirm);
    Runtime.register_tool_call_hook rt
      (fun (ctx : Hook.tool_call_context) ->
        Printf.eprintf "  [%s]\n%!" ctx.Hook.tool_name;
        Hook.Allow);
    List.iter (fun (desc : Types.skill_descriptor) ->
      ignore (Runtime.register_skill rt desc : (Types.skill_binding, _) result)
    ) Builtin_skills.builtin_skills;
    f rt;
    ignore (Runtime.close rt)
