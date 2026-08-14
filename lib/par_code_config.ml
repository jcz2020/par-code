(* par_code_config.ml — Configuration for the par-code coding agent.
 *
 * Mirrors PAR's Par_config but lives at ~/.par/ and ships coding-agent
 * defaults. Supports openai / anthropic / ollama / custom (OpenAI-compatible).
 *
 * Part of par-code's internal bootstrap layer (方案 C): does NOT depend on
 * par_cli (executable package, not linkable). If PAR exposes a public
 * bootstrap library, migrate this module to delegate to it. *)

open Par

type config = {
  provider : string;
  api_key : string;
  api_base : string option;
  model : string;
  persistence : string;
  db_uri : string option;
  temperature : float;
  system_prompt : string;
  max_iterations : int;
  planner_max_iterations : int;
  max_tokens : int option;
  top_p : float option;
  parallel_tool_execution : bool;
  event_retention_days : float;
  auto_extract : bool;
  embedding_base_url : string option;
  embedding_model : string option;
  embedding_dimension : int;
  checkpoint_enabled : bool;
  checkpoint_interval : int;
  context_budget_tokens : int;
  default_mode : Par_code_mode.mode;
  judge_enabled : bool;
  judge_model : string option;
  judge_provider : string option;
  judge_api_key : string option;
  judge_api_base : string option;
  goal_verify_command : string option;
  goal_max_steps : int;
  goal_auto_chain : bool;
  doom_loop_threshold : int;
  doom_bash_retries : int;
  doom_edit_matches : int;
  doom_action_streak : int;
  bash_approval : string;
}

let default_system_prompt = {|
You are par, an interactive coding agent built on the PAR SDK. You help users with software engineering tasks: reading, writing, and editing code, running shell commands, and searching the codebase.

IMPORTANT: Assist with authorized security testing and defensive security. Refuse requests for destructive techniques, DoS attacks, or detection evasion for malicious purposes. Never generate or guess URLs unless confident they help with programming.

## Doing tasks
- When given an unclear instruction, consider it in the context of software engineering and the current working directory. For example, if asked to rename a method, find and modify the code, don't just reply with the new name.
- For exploratory questions ("what do you think about X?", "how should we approach this?"), respond in 2-3 sentences with a recommendation and the main tradeoff. Present it as something the user can redirect, not a decided plan. Don't implement until the user agrees.
- Prefer editing existing files to creating new ones. Superfluous new files add maintenance burden.
- Don't add features, refactor, or introduce abstractions beyond what the task requires. A bug fix doesn't need surrounding cleanup; a one-shot operation doesn't need a helper. Three similar lines is better than a premature abstraction.
- Don't add error handling, fallbacks, or validation for scenarios that can't happen. Trust internal code. Only validate at system boundaries (user input, external APIs).
- Default to writing no comments. Only add one when the WHY is non-obvious: a hidden constraint, a subtle invariant, a workaround. Don't explain WHAT the code does — well-named identifiers do that.
- When debugging, identify root causes rather than addressing symptoms. Don't bypass safety checks (e.g. --no-verify) to make obstacles go away.

## Code quality
- Be careful not to introduce security vulnerabilities (injection, XSS, etc.). If you notice insecure code, fix it immediately.
- Avoid backwards-compatibility hacks. If something is unused, delete it completely.
- For UI or frontend changes, test in a browser before reporting complete. If you can't test the UI, say so explicitly rather than claiming success.

## Tool usage
- Prefer dedicated tools (read, write, edit, grep, find, ls) over bash for file operations. Dedicated tools are faster, safer, and provide better tracking.
- Reserve bash for actual system commands and terminal operations. Never use bash echo to communicate with the user.
- Bash commands require user confirmation. Batch independent tool calls when possible.
- Do not sleep between commands that can run immediately. Do not retry failing commands in a loop — diagnose the root cause.

## Git safety
- NEVER update git config. Always create NEW commits, never amend (amending after hook failure destroys prior work).
- When staging, add specific files by name, not `git add -A` or `git add .` (can include secrets or large files).
- NEVER commit unless the user explicitly asks.
- Never use interactive flags (-i).

## Delegation
- Use the `delegate` tool to assign focused subtasks to subagents when a task is self-contained and can be worked on independently.
- Use `explore` type for read-only investigation: finding files, understanding architecture, searching for patterns. Explore subagents cannot modify files.
- Use `general` type for focused implementation tasks that require writing code or running commands.
- Do NOT delegate entire user requests — delegate specific, well-scoped subtasks (e.g., "find all files that import X" or "add a unit test for function Y").
- Subagents run synchronously and return a text summary. They share the same filesystem — changes made by a `general` subagent are immediately visible.
- Avoid delegating tasks that require knowledge of the current conversation context. Subagents start fresh.

## Actions with care
- For destructive operations (deleting files, force-pushing, rm -rf, overwriting uncommitted changes), check with the user before proceeding.
- If you encounter unexpected state (unfamiliar files, branches, config), investigate before deleting or overwriting — it may be the user's in-progress work.
- A user approving an action once does NOT mean they approve it in all contexts. Re-confirm when scope shifts.
- Report outcomes faithfully: if tests fail, show the output; if a step was skipped, say so.

## Tone and style
- Responses should be short and concise. Match the user's language (Chinese input gets Chinese response).
- Do not use emojis unless the user explicitly requests it.
- When referencing code, use the format file_path:line_number.
- Before your first tool call, state in one sentence what you're about to do. Give brief updates at key moments. End with a 1-2 sentence summary of what changed and what's next.
- Don't narrate internal deliberation. Don't create planning or analysis documents unless asked — work from conversation context.
- Match responses to the task: a simple question gets a direct answer, not headers and sections.

## Memory
- You have access to project memory: recall_memory(query) to search past facts, remember_memory(kind, content, summary) to save new ones, search_history(query) to find past sessions.
- At session end, salient facts are automatically extracted and saved as memories.
- On resume (--resume), a session brief from checkpoints is injected to restore context.
- Memory kinds: preference, convention, insight, gotcha, task_map.
|}


let default = {
  provider = "openai";
  api_key = "";
  api_base = None;
  model = "gpt-4o";
  persistence = "sqlite";
  db_uri = None;
  temperature = 0.7;
  system_prompt = default_system_prompt;
  max_iterations = 50;
  planner_max_iterations = 15;
  max_tokens = None;
  top_p = None;
  parallel_tool_execution = true;
  event_retention_days = 7.0;
  auto_extract = true;
  embedding_base_url = None;
  embedding_model = None;
  embedding_dimension = 1536;
  checkpoint_enabled = true;
  checkpoint_interval = 10;
  context_budget_tokens = 100000;
  default_mode = Par_code_mode.Build;
  judge_enabled = true;
  judge_model = None;
  judge_provider = None;
  judge_api_key = None;
  judge_api_base = None;
  goal_verify_command = None;
  goal_max_steps = 50;
  goal_auto_chain = true;
  doom_loop_threshold = 3;
  doom_bash_retries = 3;
  doom_edit_matches = 2;
  doom_action_streak = 4;
  bash_approval = "ask";
}

let config_dir () =
  let home = try Sys.getenv "HOME" with Not_found -> "/" in
  let dir = Filename.concat home ".par" in
  if not (Sys.file_exists dir) then
    (try Unix.mkdir dir 0o755 with Unix.Unix_error _ -> ());
  dir

let config_path () = Filename.concat (config_dir ()) "config.json"
let db_path () = Filename.concat (config_dir ()) "par.db"

let to_json (cfg : config) : Yojson.Safe.t =
  let opt_str = function Some s -> `String s | None -> `Null in
  let opt_int = function Some n -> `Int n | None -> `Null in
  let opt_float = function Some f -> `Float f | None -> `Null in
  `Assoc [
    ("provider", `String cfg.provider);
    ("api_key", `String cfg.api_key);
    ("api_base", opt_str cfg.api_base);
    ("model", `String cfg.model);
    ("persistence", `String cfg.persistence);
    ("db_uri", opt_str cfg.db_uri);
    ("temperature", `Float cfg.temperature);
    ("system_prompt", `String cfg.system_prompt);
    ("max_iterations", `Int cfg.max_iterations);
    ("planner_max_iterations", `Int cfg.planner_max_iterations);
    ("max_tokens", opt_int cfg.max_tokens);
    ("top_p", opt_float cfg.top_p);
    ("parallel_tool_execution", `Bool cfg.parallel_tool_execution);
    ("event_retention_days", `Float cfg.event_retention_days);
    ("auto_extract", `Bool cfg.auto_extract);
    ("embedding_base_url", opt_str cfg.embedding_base_url);
    ("embedding_model", opt_str cfg.embedding_model);
    ("embedding_dimension", `Int cfg.embedding_dimension);
    ("checkpoint_enabled", `Bool cfg.checkpoint_enabled);
    ("checkpoint_interval", `Int cfg.checkpoint_interval);
    ("context_budget_tokens", `Int cfg.context_budget_tokens);
    ("default_mode", `String (Par_code_mode.label cfg.default_mode));
    ("judge_enabled", `Bool cfg.judge_enabled);
    ("judge_model", opt_str cfg.judge_model);
    ("judge_provider", opt_str cfg.judge_provider);
    ("judge_api_key", opt_str cfg.judge_api_key);
    ("judge_api_base", opt_str cfg.judge_api_base);
    ("goal_verify_command", opt_str cfg.goal_verify_command);
    ("goal_max_steps", `Int cfg.goal_max_steps);
    ("goal_auto_chain", `Bool cfg.goal_auto_chain);
    ("doom_loop_threshold", `Int cfg.doom_loop_threshold);
    ("doom_bash_retries", `Int cfg.doom_bash_retries);
    ("doom_edit_matches", `Int cfg.doom_edit_matches);
    ("doom_action_streak", `Int cfg.doom_action_streak);
    ("bash_approval", `String cfg.bash_approval);
  ]

let of_json (json : Yojson.Safe.t) : (config, string) result =
  try
    let open Yojson.Safe.Util in
    let get_s f = match json |> member f |> to_string_option with Some s -> s | None -> "" in
    let get_os f = match json |> member f with `Null -> None | v -> to_string_option v in
    let get_f f d = match json |> member f |> to_float_option with Some x -> x | None -> d in
    let get_i f d = match json |> member f |> to_int_option with Some x -> x | None -> d in
    let get_oi f = match json |> member f with `Int n -> Some n | _ -> None in
    let get_of f = match json |> member f with `Float x -> Some x | _ -> None in
    let get_b f d = match json |> member f |> to_bool_option with Some b -> b | None -> d in
    let get_mode f d =
      match json |> member f |> to_string_option with
      | Some s when String.lowercase_ascii s = "plan" -> Par_code_mode.Plan
      | Some s when String.lowercase_ascii s = "build" -> Par_code_mode.Build
      | _ -> d
    in
    Ok {
      provider = get_s "provider";
      api_key = get_s "api_key";
      api_base = get_os "api_base";
      model = get_s "model";
      persistence = get_s "persistence";
      db_uri = get_os "db_uri";
      temperature = get_f "temperature" default.temperature;
      system_prompt =
        (let s = get_s "system_prompt" in
         if s = "" then default.system_prompt else s);
      max_iterations = get_i "max_iterations" default.max_iterations;
      planner_max_iterations = get_i "planner_max_iterations" default.planner_max_iterations;
      max_tokens = get_oi "max_tokens";
      top_p = get_of "top_p";
      parallel_tool_execution = get_b "parallel_tool_execution" default.parallel_tool_execution;
      event_retention_days = get_f "event_retention_days" default.event_retention_days;
      auto_extract = get_b "auto_extract" default.auto_extract;
      embedding_base_url = get_os "embedding_base_url";
      embedding_model = get_os "embedding_model";
      embedding_dimension = get_i "embedding_dimension" default.embedding_dimension;
      checkpoint_enabled = get_b "checkpoint_enabled" default.checkpoint_enabled;
      checkpoint_interval = get_i "checkpoint_interval" default.checkpoint_interval;
      context_budget_tokens = get_i "context_budget_tokens" default.context_budget_tokens;
      default_mode = get_mode "default_mode" default.default_mode;
      judge_enabled = get_b "judge_enabled" default.judge_enabled;
      judge_model = get_os "judge_model";
      judge_provider = get_os "judge_provider";
      judge_api_key = get_os "judge_api_key";
      judge_api_base = get_os "judge_api_base";
      goal_verify_command = get_os "goal_verify_command";
      goal_max_steps = get_i "goal_max_steps" default.goal_max_steps;
      goal_auto_chain = get_b "goal_auto_chain" default.goal_auto_chain;
      doom_loop_threshold = get_i "doom_loop_threshold" default.doom_loop_threshold;
      doom_bash_retries =
        (let raw = json |> member "doom_bash_retries" in
         match raw with `Null ->
           let old = json |> member "doom_loop_threshold" in
           (match old with `Int n -> n | _ -> default.doom_bash_retries)
         | v -> (match Yojson.Safe.Util.to_int_option v with Some n -> n | None -> default.doom_bash_retries));
      doom_edit_matches =
        (let raw = json |> member "doom_edit_matches" in
         match raw with `Null ->
           let old = json |> member "doom_loop_threshold" in
           (match old with `Int n -> n | _ -> default.doom_edit_matches)
         | v -> (match Yojson.Safe.Util.to_int_option v with Some n -> n | None -> default.doom_edit_matches));
      doom_action_streak =
        (let raw = json |> member "doom_action_streak" in
         match raw with `Null ->
           let old = json |> member "doom_loop_threshold" in
           (match old with `Int n -> n | _ -> default.doom_action_streak)
         | v -> (match Yojson.Safe.Util.to_int_option v with Some n -> n | None -> default.doom_action_streak));
      bash_approval =
        (match json |> member "bash_approval" |> to_string_option with
         | Some s when s = "ask" || s = "auto_project" || s = "always" -> s
         | _ -> default.bash_approval);
    }
  with exn -> Error (Printexc.to_string exn)

let load () : config option =
  let path = config_path () in
  if not (Sys.file_exists path) then None
  else
    try
      let ic = open_in path in
      let n = in_channel_length ic in
      let s = Bytes.create n in
      really_input ic s 0 n;
      close_in ic;
      match of_json (Yojson.Safe.from_string (Bytes.to_string s)) with
      | Ok cfg -> Some cfg
      | Error _ -> None
    with _ -> None

let save (cfg : config) : unit =
  (* Atomic write: write to temp file on the same filesystem, then rename.
     Prevents readers from seeing a partially-truncated file during write —
     the race that caused config_set_test flakiness (~10% failure rate). *)
  let path = config_path () in
  let tmp = path ^ ".tmp" in
  let oc = open_out tmp in
  output_string oc (Yojson.Safe.pretty_to_string ~std:true (to_json cfg));
  output_char oc '\n';
  close_out oc;
  Sys.rename tmp path

type provider_tag = [ `Openai | `Anthropic | `Ollama | `Custom of string ]

let to_provider_tag (cfg : config) : provider_tag =
  match String.lowercase_ascii cfg.provider with
  | "anthropic" -> `Anthropic
  | "ollama" -> `Ollama
  | s when String.length s > 0 && s.[0] = '+' -> `Custom (String.sub s 1 (String.length s - 1))
  | _ -> `Openai

let to_model_config (cfg : config) : Types.model_config =
  { Types.
    provider = (match to_provider_tag cfg with
      | `Openai -> `Openai | `Anthropic -> `Anthropic
      | `Ollama -> `Ollama | `Custom s -> `Custom s);
    model_name = cfg.model;
    api_base = cfg.api_base;
    temperature = cfg.temperature;
    max_tokens = cfg.max_tokens;
    top_p = cfg.top_p;
    stop_sequences = None;
  }

let to_persistence_config (_cfg : config) : [ `Sqlite of string ] =
  `Sqlite (db_path ())

let merge
    (cfg : config)
    ?(provider = None) ?(api_key = None) ?(api_base = None)
    ?(model = None) ?(persistence = None) ?(db_uri = None)
    ?(temperature = None) ?(system_prompt = None) ?(max_iterations = None)
    ?(planner_max_iterations = None)
    ?(max_tokens = None) ?(top_p = None) ?(parallel_tool_execution = None)
    ?(event_retention_days = None) ?(auto_extract = None)
    ?(embedding_base_url = None) ?(embedding_model = None)
    ?(embedding_dimension = None)
    ?(checkpoint_enabled = None) ?(checkpoint_interval = None)
    ?(context_budget_tokens = None)
    ?(default_mode = None) ?(bash_approval = None) () =
  {
    provider = Option.value provider ~default:cfg.provider;
    api_key = Option.value api_key ~default:cfg.api_key;
    api_base = (match api_base with Some b -> Some b | None -> cfg.api_base);
    model = Option.value model ~default:cfg.model;
    persistence = Option.value persistence ~default:cfg.persistence;
    db_uri = (match db_uri with Some u -> Some u | None -> cfg.db_uri);
    temperature = Option.value temperature ~default:cfg.temperature;
    system_prompt = Option.value system_prompt ~default:cfg.system_prompt;
    max_iterations = Option.value max_iterations ~default:cfg.max_iterations;
    planner_max_iterations = Option.value planner_max_iterations ~default:cfg.planner_max_iterations;
    max_tokens = (match max_tokens with Some _ as v -> v | None -> cfg.max_tokens);
    top_p = (match top_p with Some _ as v -> v | None -> cfg.top_p);
    parallel_tool_execution = Option.value parallel_tool_execution ~default:cfg.parallel_tool_execution;
    event_retention_days = Option.value event_retention_days ~default:cfg.event_retention_days;
    auto_extract = Option.value auto_extract ~default:cfg.auto_extract;
    embedding_base_url = (match embedding_base_url with Some _ as v -> v | None -> cfg.embedding_base_url);
    embedding_model = (match embedding_model with Some _ as v -> v | None -> cfg.embedding_model);
    embedding_dimension = Option.value embedding_dimension ~default:cfg.embedding_dimension;
    checkpoint_enabled = Option.value checkpoint_enabled ~default:cfg.checkpoint_enabled;
    checkpoint_interval = Option.value checkpoint_interval ~default:cfg.checkpoint_interval;
    context_budget_tokens = Option.value context_budget_tokens ~default:cfg.context_budget_tokens;
    default_mode = (match default_mode with Some m -> m | None -> cfg.default_mode);
    judge_enabled = cfg.judge_enabled;
    judge_model = cfg.judge_model;
    judge_provider = cfg.judge_provider;
    judge_api_key = cfg.judge_api_key;
    judge_api_base = cfg.judge_api_base;
    goal_verify_command = cfg.goal_verify_command;
    goal_max_steps = cfg.goal_max_steps;
    goal_auto_chain = cfg.goal_auto_chain;
    doom_loop_threshold = cfg.doom_loop_threshold;
    doom_bash_retries = cfg.doom_bash_retries;
    doom_edit_matches = cfg.doom_edit_matches;
    doom_action_streak = cfg.doom_action_streak;
    bash_approval = Option.value bash_approval ~default:cfg.bash_approval;
  }

let require_config () =
  match load () with
  | Some cfg -> cfg
  | None ->
    let ui = Par_code_ui.create_backend () in
    Par_code_ui.render_error ui
      (Printf.sprintf "No config found at %s.\nRun `par config` first."
         (config_path ()));
    exit 1

let mask_api_key key =
  let len = String.length key in
  if len <= 4 then "****"
  else if len <= 8 then
    Printf.sprintf "%c****%c" key.[0] key.[len - 1]
  else Printf.sprintf "%s****%s"
    (String.sub key 0 4)
    (String.sub key (len - 4) 4)

let update_field ~field ~value =
  let cfg = match load () with Some c -> c | None -> default in
  let parse_bool v =
    match String.lowercase_ascii (String.trim v) with
    | "true" | "1" | "yes" -> true
    | "false" | "0" | "no" -> false
    | other ->
      Printf.eprintf "Invalid value for %s: expected bool (true/false/yes/no/1/0), got '%s'\n" field other;
      exit 1
  in
  let is_clear v = let v = String.trim v in v = "" || String.lowercase_ascii v = "none" in
  let updated = match String.lowercase_ascii field with
    (* ── Plain string ── *)
    | "provider" -> { cfg with provider = String.trim value }
    | "api_key" -> { cfg with api_key = String.trim value }
    | "model" -> { cfg with model = String.trim value }
    | "persistence" -> { cfg with persistence = String.trim value }
    (* ── Optional string (empty/"none" → None) ── *)
    | "api_base" ->
      let v = String.trim value in
      { cfg with api_base = if is_clear v then None else Some v }
    | "db_uri" ->
      let v = String.trim value in
      { cfg with db_uri = if is_clear v then None else Some v }
    | "embedding_base_url" ->
      let v = String.trim value in
      { cfg with embedding_base_url = if is_clear v then None else Some v }
    | "embedding_model" ->
      let v = String.trim value in
      { cfg with embedding_model = if is_clear v then None else Some v }
    (* ── Required float ── *)
    | "temperature" ->
      (match float_of_string_opt (String.trim value) with
       | Some f -> { cfg with temperature = f }
       | None ->
         Printf.eprintf "Invalid value for temperature: expected float, got '%s'\n" value;
         exit 1)
    | "event_retention_days" ->
      (match float_of_string_opt (String.trim value) with
       | Some f -> { cfg with event_retention_days = f }
       | None ->
         Printf.eprintf "Invalid value for event_retention_days: expected float, got '%s'\n" value;
         exit 1)
    (* ── Optional float ── *)
    | "top_p" ->
      if is_clear value then { cfg with top_p = None }
      else (match float_of_string_opt (String.trim value) with
        | Some f -> { cfg with top_p = Some f }
        | None ->
          Printf.eprintf "Invalid value for top_p: expected float, got '%s'\n" value;
          exit 1)
    (* ── Required int (with validation) ── *)
    | "max_iterations" ->
      (match int_of_string_opt (String.trim value) with
       | Some n when n > 0 -> { cfg with max_iterations = n }
       | Some _ ->
         Printf.eprintf "Invalid value for max_iterations: must be > 0, got '%s'\n" value;
         exit 1
       | None ->
         Printf.eprintf "Invalid value for max_iterations: expected int, got '%s'\n" value;
          exit 1)
    | "planner_max_iterations" ->
      (match int_of_string_opt (String.trim value) with
       | Some n when n > 0 -> { cfg with planner_max_iterations = n }
       | Some _ ->
         Printf.eprintf "Invalid value for planner_max_iterations: must be > 0, got '%s'\n" value;
         exit 1
       | None ->
         Printf.eprintf "Invalid value for planner_max_iterations: expected int, got '%s'\n" value;
         exit 1)
    | "embedding_dimension" ->
      (match int_of_string_opt (String.trim value) with
       | Some n when n > 0 -> { cfg with embedding_dimension = n }
       | Some _ ->
         Printf.eprintf "Invalid value for embedding_dimension: must be > 0, got '%s'\n" value;
         exit 1
       | None ->
         Printf.eprintf "Invalid value for embedding_dimension: expected int, got '%s'\n" value;
         exit 1)
    | "checkpoint_interval" ->
      (match int_of_string_opt (String.trim value) with
       | Some n when n >= 1 -> { cfg with checkpoint_interval = n }
       | Some _ ->
         Printf.eprintf "Invalid value for checkpoint_interval: must be >= 1, got '%s'\n" value;
         exit 1
       | None ->
         Printf.eprintf "Invalid value for checkpoint_interval: expected int, got '%s'\n" value;
         exit 1)
    | "context_budget_tokens" ->
      (match int_of_string_opt (String.trim value) with
       | Some n when n >= 1000 -> { cfg with context_budget_tokens = n }
       | Some _ ->
         Printf.eprintf "Invalid value for context_budget_tokens: must be >= 1000, got '%s'\n" value;
         exit 1
       | None ->
         Printf.eprintf "Invalid value for context_budget_tokens: expected int, got '%s'\n" value;
         exit 1)
    (* ── Optional int ── *)
    | "max_tokens" ->
      if is_clear value then { cfg with max_tokens = None }
      else (match int_of_string_opt (String.trim value) with
        | Some n when n > 0 -> { cfg with max_tokens = Some n }
        | Some _ ->
          Printf.eprintf "Invalid value for max_tokens: must be > 0, got '%s'\n" value;
          exit 1
        | None ->
          Printf.eprintf "Invalid value for max_tokens: expected int, got '%s'\n" value;
          exit 1)
    (* ── Bool ── *)
    | "parallel_tool_execution" -> { cfg with parallel_tool_execution = parse_bool value }
    | "auto_extract" -> { cfg with auto_extract = parse_bool value }
    | "checkpoint_enabled" -> { cfg with checkpoint_enabled = parse_bool value }
    | "judge_enabled" -> { cfg with judge_enabled = parse_bool value }
    | "goal_auto_chain" -> { cfg with goal_auto_chain = parse_bool value }
    (* ── Optional string ── *)
    | "judge_model" ->
      let v = String.trim value in
      { cfg with judge_model = if is_clear v then None else Some v }
    | "judge_provider" ->
      let v = String.trim value in
      { cfg with judge_provider = if is_clear v then None else Some v }
    | "judge_api_key" ->
      let v = String.trim value in
      { cfg with judge_api_key = if is_clear v then None else Some v }
    | "judge_api_base" ->
      let v = String.trim value in
      { cfg with judge_api_base = if is_clear v then None else Some v }
    | "goal_verify_command" ->
      let v = String.trim value in
      { cfg with goal_verify_command = if is_clear v then None else Some v }
    (* ── Required int with validation ── *)
    | "goal_max_steps" ->
      (match int_of_string_opt (String.trim value) with
       | Some n when n > 0 -> { cfg with goal_max_steps = n }
       | Some _ ->
         Printf.eprintf "Invalid value for goal_max_steps: must be > 0, got '%s'\n" value;
         exit 1
       | None ->
         Printf.eprintf "Invalid value for goal_max_steps: expected int, got '%s'\n" value;
         exit 1)
    | "doom_loop_threshold" ->
      Printf.eprintf "doom_loop_threshold is deprecated. Use doom_bash_retries, doom_edit_matches, doom_action_streak.\n";
      (match int_of_string_opt (String.trim value) with
       | Some n when n >= 1 ->
         { cfg with doom_loop_threshold = n; doom_bash_retries = n; doom_edit_matches = n; doom_action_streak = n }
       | Some _ ->
         Printf.eprintf "Invalid value for doom_loop_threshold: must be >= 1, got '%s'\n" value;
         exit 1
       | None ->
         Printf.eprintf "Invalid value for doom_loop_threshold: expected int, got '%s'\n" value;
         exit 1)
    | "doom_bash_retries" ->
      (match int_of_string_opt (String.trim value) with
       | Some n when n >= 1 -> { cfg with doom_bash_retries = n }
       | Some _ ->
         Printf.eprintf "Invalid value for doom_bash_retries: must be >= 1, got '%s'\n" value;
         exit 1
       | None ->
         Printf.eprintf "Invalid value for doom_bash_retries: expected int, got '%s'\n" value;
         exit 1)
    | "doom_edit_matches" ->
      (match int_of_string_opt (String.trim value) with
       | Some n when n >= 1 -> { cfg with doom_edit_matches = n }
       | Some _ ->
         Printf.eprintf "Invalid value for doom_edit_matches: must be >= 1, got '%s'\n" value;
         exit 1
       | None ->
         Printf.eprintf "Invalid value for doom_edit_matches: expected int, got '%s'\n" value;
         exit 1)
    | "doom_action_streak" ->
      (match int_of_string_opt (String.trim value) with
       | Some n when n >= 1 -> { cfg with doom_action_streak = n }
       | Some _ ->
         Printf.eprintf "Invalid value for doom_action_streak: must be >= 1, got '%s'\n" value;
         exit 1
       | None ->
         Printf.eprintf "Invalid value for doom_action_streak: expected int, got '%s'\n" value;
         exit 1)
    (* ── Enum ── *)
    | "default_mode" ->
      (match String.lowercase_ascii (String.trim value) with
       | "plan" -> { cfg with default_mode = Par_code_mode.Plan }
       | "build" -> { cfg with default_mode = Par_code_mode.Build }
       | other ->
         Printf.eprintf "Invalid mode '%s'. Use 'plan' or 'build'.\n" other;
         exit 1)
    | "bash_approval" ->
      (match String.lowercase_ascii (String.trim value) with
       | "ask" | "auto_project" | "always" as v -> { cfg with bash_approval = v }
       | other ->
         Printf.eprintf "Invalid bash_approval '%s'. Use 'ask', 'auto_project', or 'always'.\n" other;
         exit 1)
    (* ── Excluded ── *)
    | "system_prompt" ->
      Printf.eprintf "system_prompt is multiline; set it via 'par config' wizard instead.\n";
      exit 1
    (* ── Unknown ── *)
    | other ->
      Printf.eprintf "Unknown config field '%s'.\n" other;
      Printf.eprintf "Supported fields:\n";
      List.iter (fun f -> Printf.eprintf "  %s\n" f)
        [ "api_base"; "api_key"; "auto_extract";
          "bash_approval";
          "checkpoint_enabled"; "checkpoint_interval";
          "context_budget_tokens"; "db_uri"; "default_mode";
          "doom_action_streak"; "doom_bash_retries"; "doom_edit_matches";
          "embedding_base_url"; "embedding_dimension"; "embedding_model";
          "event_retention_days";
          "goal_auto_chain"; "goal_max_steps"; "goal_verify_command";
          "judge_api_base"; "judge_api_key";
          "judge_enabled"; "judge_model"; "judge_provider";
          "max_iterations"; "max_tokens"; "model";
          "parallel_tool_execution"; "persistence"; "planner_max_iterations";
          "provider";
          "system_prompt"; "temperature"; "top_p" ];
      exit 1
  in
  save updated;
  updated

let show ?(ui=Par_code_ui.create_backend ()) (cfg : config) =
  let open Par_code_ui in
  let line label value = textf "  %-24s %s" label value in
  let image = vcat [
    text "par-code configuration:";
    line "provider:" cfg.provider;
    line "api_key:" (mask_api_key cfg.api_key);
    line "api_base:" (match cfg.api_base with Some s -> s | None -> "<default>");
    line "model:" cfg.model;
    line "persistence:" cfg.persistence;
    line "db_uri:" (match cfg.db_uri with Some s -> s | None -> "<default>");
    line "temperature:" (Printf.sprintf "%.2f" cfg.temperature);
    line "max_iterations:" (string_of_int cfg.max_iterations);
    line "planner_max_iterations:" (string_of_int cfg.planner_max_iterations);
    line "max_tokens:" (match cfg.max_tokens with Some n -> string_of_int n | None -> "<unlimited>");
    line "top_p:" (match cfg.top_p with Some f -> Printf.sprintf "%.4f" f | None -> "<default>");
    line "parallel_tool_execution:" (string_of_bool cfg.parallel_tool_execution);
    line "event_retention_days:" (Printf.sprintf "%.1f" cfg.event_retention_days);
    line "auto_extract:" (string_of_bool cfg.auto_extract);
    line "embedding_base_url:" (match cfg.embedding_base_url with Some s -> s | None -> "<default>");
    line "embedding_model:" (match cfg.embedding_model with Some s -> s | None -> "<default>");
    line "embedding_dimension:" (string_of_int cfg.embedding_dimension);
    line "checkpoint_enabled:" (string_of_bool cfg.checkpoint_enabled);
    line "checkpoint_interval:" (string_of_int cfg.checkpoint_interval);
    line "context_budget_tokens:" (string_of_int cfg.context_budget_tokens);
    line "default_mode:" (Par_code_mode.label cfg.default_mode);
    line "system_prompt:" (if cfg.system_prompt = default.system_prompt then "<default>" else "<custom>");
    line "judge_enabled:" (string_of_bool cfg.judge_enabled);
    line "judge_model:" (match cfg.judge_model with Some s -> s | None -> "<inherit>");
    line "judge_provider:" (match cfg.judge_provider with Some s -> s | None -> "<inherit>");
    line "judge_api_key:" (match cfg.judge_api_key with Some k -> mask_api_key k | None -> "<inherit>");
    line "judge_api_base:" (match cfg.judge_api_base with Some s -> s | None -> "<inherit>");
    line "goal_verify_command:" (match cfg.goal_verify_command with Some s -> s | None -> "<none>");
    line "goal_max_steps:" (string_of_int cfg.goal_max_steps);
    line "goal_auto_chain:" (string_of_bool cfg.goal_auto_chain);
    line "doom_bash_retries:" (string_of_int cfg.doom_bash_retries);
    line "doom_edit_matches:" (string_of_int cfg.doom_edit_matches);
    line "doom_action_streak:" (string_of_int cfg.doom_action_streak);
    line "bash_approval:" cfg.bash_approval;
  ] in
  render_line ui image
