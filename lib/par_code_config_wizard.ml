(* par_code_config_wizard.ml — Interactive configuration wizard.
 *
 * Extracted from par_code_config.ml to respect the 800-line static-language
 * file limit. Contains prompt_line and run_wizard only. *)

let prompt_line ui label default =
  let prompt_str = match default with
    | Some d -> Printf.sprintf "%s [%s]: " label d
    | None -> Printf.sprintf "%s: " label
  in
  match Par_code_ui.read_line ui ~prompt:(Par_code_ui.text prompt_str) with
  | Some line when String.trim line <> "" -> String.trim line
  | Some _ -> Option.value default ~default:""
  | None -> Option.value default ~default:""

let run_wizard ?(ui=Par_code_ui.create_backend ()) () =
  let open Par_code_ui in
  let existing = Par_code_config.load () in
  (match existing with
   | Some cfg ->
     render_line ui (textf "Current config (%s):" (Par_code_config.config_path ()));
     render_line ui (textf "  Provider:    %s" cfg.provider);
     render_line ui (textf "  Model:       %s" cfg.model);
     render_line ui (textf "  API Base:    %s" (match cfg.api_base with Some u -> u | None -> "(default)"));
     render_line ui (textf "  Temperature: %.1f" cfg.temperature);
     render_line ui (textf "  Max iter:    %d" cfg.max_iterations);
     render_line ui (text "\nEnter new values or press Enter to keep current.");
     render_line ui empty
   | None ->
     render_line ui (text "Welcome to par! First-time setup.");
     render_line ui empty);

  let prov_default = match existing with Some c -> Some c.provider | None -> Some Par_code_config.default.provider in
  let provider = prompt_line ui "Provider (openai/anthropic/ollama/+custom-name)" prov_default in

  let api_key_default = match existing with Some c when c.api_key <> "" -> Some c.api_key | _ -> None in
  let api_key = prompt_line ui "API Key" api_key_default in

  let api_base =
    let hint = match String.lowercase_ascii provider with
      | "anthropic" -> "https://api.anthropic.com"
      | "ollama" -> "http://localhost:11434/v1"
      | _ -> "https://api.openai.com/v1"
    in
    let prev = match existing with Some c -> c.api_base | None -> None in
    let prompt_str = Printf.sprintf "API Base URL (default: %s)%s: " hint
      (match prev with Some b -> Printf.sprintf " [%s]" b | None -> "")
    in
    match read_line ui ~prompt:(text prompt_str) with
    | Some line when String.trim line <> "" -> Some (String.trim line)
    | Some _ -> prev
    | None -> prev
  in

  let model_default = match existing with Some c -> Some c.model | None -> Some Par_code_config.default.model in
  let model = prompt_line ui "Model name" model_default in

  let temp_default =
    match existing with Some c -> Printf.sprintf "%.1f" c.temperature | None -> Printf.sprintf "%.1f" Par_code_config.default.temperature
  in
  let temp_str = prompt_line ui "Temperature" (Some temp_default) in
  let temperature = match float_of_string_opt temp_str with Some f -> f | None -> Par_code_config.default.temperature in

  let max_iter_default =
    match existing with Some c -> Some (string_of_int c.max_iterations) | None -> Some "50"
  in
  let max_iter_str = prompt_line ui "Max ReAct iterations" max_iter_default in
  let max_iterations = match int_of_string_opt max_iter_str with Some n when n > 0 -> n | _ -> 50 in

  let planner_max_iter_default =
    match existing with Some c -> Some (string_of_int c.planner_max_iterations) | None -> Some "15"
  in
  let planner_max_iter_str = prompt_line ui "Planner max iterations" planner_max_iter_default in
  let planner_max_iterations = match int_of_string_opt planner_max_iter_str with Some n when n > 0 -> n | _ -> 15 in

  render_line ui (text "\n--- Advanced options ---");

  let max_tokens =
    let s = prompt_line ui "max_tokens (blank = unlimited)" None in
    match s with
    | "" -> None
    | s -> (try Some (int_of_string s) with _ ->
        render_warning ui "Invalid int, using unlimited"; None)
  in

  let top_p =
    let s = prompt_line ui "top_p (blank = provider default)" None in
    match s with
    | "" -> None
    | s -> (try Some (float_of_string s) with _ ->
        render_warning ui "Invalid float, using default"; None)
  in

  let auto_extract =
    match read_line ui ~prompt:(text "Enable auto memory extraction at session exit? [Y/n]: ") with
    | Some line when String.lowercase_ascii (String.trim line) = "n" -> false
    | Some _ -> true
    | None -> true
  in

  let checkpoint_enabled =
    match read_line ui ~prompt:(text "Enable session checkpointing? [Y/n]: ") with
    | Some line when String.lowercase_ascii (String.trim line) = "n" -> false
    | Some _ -> true
    | None -> true
  in

  let goal_auto_chain =
    match read_line ui ~prompt:(text "Enable autonomous goal chaining? [Y/n]: ") with
    | Some line when String.lowercase_ascii (String.trim line) = "n" -> false
    | Some _ -> true
    | None -> true
  in

  let checkpoint_interval =
    let s = prompt_line ui "checkpoint_interval (turns, default 10)" (Some "10") in
    (try max 1 (int_of_string s) with _ -> 10)
  in

  let context_budget_tokens =
    let s = prompt_line ui "context_budget_tokens (default 100000)" (Some "100000") in
    (try max 1000 (int_of_string s) with _ -> 100000)
  in

  let default_mode =
    let dm_default = match existing with
      | Some c -> Some (Par_code_mode.label c.default_mode)
      | None -> Some (Par_code_mode.label Par_code_config.default.default_mode)
    in
    let s = prompt_line ui "Default REPL mode on startup (build/plan)" dm_default in
    match String.lowercase_ascii (String.trim s) with
    | "plan" -> Par_code_mode.Plan
    | _ -> Par_code_mode.Build
  in

  let bash_approval =
    let ba_default = match existing with
      | Some c -> Some c.bash_approval
      | None -> Some Par_code_config.default.bash_approval
    in
    let s = prompt_line ui "Bash approval (ask/auto_project/always)" ba_default in
    let v = String.lowercase_ascii (String.trim s) in
    let v = (match v with "ask" | "auto_project" | "always" -> v | _ -> "ask") in
    if v = "always" then
      render_line ui (text "  \xe2\x9a\xa0 always: ALL bash commands run without confirmation");
    v
  in

  render_line ui (text "\nEmbedding API (for semantic memory search).");
  render_line ui (text "  Uses your chat provider by default. Configure separately if your");
  render_line ui (text "  provider doesn't support /embeddings or uses a different dimension.");
  let sep_embed =
    match read_line ui ~prompt:(text "Configure separate embedding API? [y/N]: ") with
    | Some line when String.lowercase_ascii (String.trim line) = "y" -> true
    | Some _ -> false
    | None -> false
  in
  let embedding_base_url, embedding_model, embedding_dimension =
    if sep_embed then begin
      let emb_base =
        let hint = "https://api.openai.com/v1" in
        let prompt_str = Printf.sprintf "Embedding API Base URL (default: %s): " hint in
        match read_line ui ~prompt:(text prompt_str) with
        | Some line when String.trim line <> "" -> Some (String.trim line)
        | Some _ -> Some hint
        | None -> Some hint
      in
      let emb_model =
        match read_line ui ~prompt:(text "Embedding model name (default: text-embedding-3-small): ") with
        | Some line when String.trim line <> "" -> Some (String.trim line)
        | Some _ -> None
        | None -> None
      in
      let emb_dim =
        match read_line ui ~prompt:(text "Embedding dimension [1536]: ") with
        | Some line when String.trim line <> "" ->
          (match int_of_string_opt (String.trim line) with
           Some n -> n | None -> 1536)
        | Some _ -> 1536
        | None -> 1536
      in
      (emb_base, emb_model, emb_dim)
    end else
      (None, None, Par_code_config.default.embedding_dimension)
  in

  let cfg = {
    Par_code_config.
    provider; api_key; api_base; model;
    persistence = "sqlite"; db_uri = None;
    temperature; system_prompt = Par_code_config.default_system_prompt; max_iterations;
    planner_max_iterations;
    max_tokens; top_p;
    parallel_tool_execution = true;
    event_retention_days = 7.0;
    auto_extract;
    embedding_base_url; embedding_model; embedding_dimension;
    checkpoint_enabled; checkpoint_interval; context_budget_tokens;
    default_mode;
    judge_enabled = Par_code_config.default.judge_enabled;
    judge_model = Par_code_config.default.judge_model;
    judge_provider = Par_code_config.default.judge_provider;
    judge_api_key = Par_code_config.default.judge_api_key;
    judge_api_base = Par_code_config.default.judge_api_base;
    goal_verify_command = Par_code_config.default.goal_verify_command;
    goal_max_steps = Par_code_config.default.goal_max_steps;
    doom_loop_threshold = Par_code_config.default.doom_loop_threshold;
    doom_bash_retries = Par_code_config.default.doom_bash_retries;
    doom_edit_matches = Par_code_config.default.doom_edit_matches;
    doom_action_streak = Par_code_config.default.doom_action_streak;
    bash_approval;
    goal_auto_chain;
  } in
  Par_code_config.save cfg;
  render_notice ui (Printf.sprintf "\nSaved config to %s" (Par_code_config.config_path ()))
