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
  let oc = open_out (config_path ()) in
  output_string oc (Yojson.Safe.pretty_to_string ~std:true (to_json cfg));
  output_char oc '\n';
  close_out oc

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
    ?(max_tokens = None) ?(top_p = None) ?(parallel_tool_execution = None)
    ?(event_retention_days = None) ?(auto_extract = None)
    ?(embedding_base_url = None) ?(embedding_model = None)
    ?(embedding_dimension = None)
    ?(checkpoint_enabled = None) ?(checkpoint_interval = None)
    ?(context_budget_tokens = None) () =
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
  }

let require_config () =
  match load () with
  | Some cfg -> cfg
  | None ->
    Printf.eprintf "No config found at %s.\nRun `par config` first.\n%!"
      (config_path ());
    exit 1

let prompt_line label default =
  let prompt = match default with
    | Some d -> Printf.sprintf "%s [%s]: " label d
    | None -> Printf.sprintf "%s: " label
  in
  Printf.printf "%s%!" prompt;
  match input_line stdin with
  | line when String.trim line <> "" -> String.trim line
  | exception End_of_file -> Option.value default ~default:""
  | _ -> Option.value default ~default:""

let run_wizard () =
  let existing = load () in
  (match existing with
   | Some cfg ->
     Printf.printf "Current config (%s):\n" (config_path ());
     Printf.printf "  Provider:    %s\n" cfg.provider;
     Printf.printf "  Model:       %s\n" cfg.model;
     Printf.printf "  API Base:    %s\n" (match cfg.api_base with Some u -> u | None -> "(default)");
     Printf.printf "  Temperature: %.1f\n" cfg.temperature;
     Printf.printf "  Max iter:    %d\n" cfg.max_iterations;
     Printf.printf "\nEnter new values or press Enter to keep current.\n\n%!"
   | None ->
     Printf.printf "Welcome to par! First-time setup.\n\n%!");

  let prov_default = match existing with Some c -> Some c.provider | None -> Some default.provider in
  let provider = prompt_line "Provider (openai/anthropic/ollama/+custom-name)" prov_default in

  let api_key_default = match existing with Some c when c.api_key <> "" -> Some c.api_key | _ -> None in
  let api_key = prompt_line "API Key" api_key_default in

  let api_base =
    let hint = match String.lowercase_ascii provider with
      | "anthropic" -> "https://api.anthropic.com"
      | "ollama" -> "http://localhost:11434/v1"
      | _ -> "https://api.openai.com/v1"
    in
    let prev = match existing with Some c -> c.api_base | None -> None in
    Printf.printf "API Base URL (default: %s)%s: %!" hint
      (match prev with Some b -> Printf.sprintf " [%s]" b | None -> "");
    match input_line stdin with
    | line when String.trim line <> "" -> Some (String.trim line)
    | exception End_of_file -> prev
    | _ -> prev
  in

  let model_default = match existing with Some c -> Some c.model | None -> Some default.model in
  let model = prompt_line "Model name" model_default in

  let temp_default =
    match existing with Some c -> Printf.sprintf "%.1f" c.temperature | None -> Printf.sprintf "%.1f" default.temperature
  in
  let temp_str = prompt_line "Temperature" (Some temp_default) in
  let temperature = match float_of_string_opt temp_str with Some f -> f | None -> default.temperature in

  let max_iter_default =
    match existing with Some c -> Some (string_of_int c.max_iterations) | None -> Some "50"
  in
  let max_iter_str = prompt_line "Max ReAct iterations" max_iter_default in
  let max_iterations = match int_of_string_opt max_iter_str with Some n when n > 0 -> n | _ -> 50 in

  Printf.printf "\nEmbedding API (for semantic memory search).\n%!";
  Printf.printf "  Uses your chat provider by default. Configure separately if your\n%!";
  Printf.printf "  provider doesn't support /embeddings or uses a different dimension.\n%!";
  let sep_embed =
    Printf.printf "Configure separate embedding API? [y/N]: %!";
    match input_line stdin with
    | line when String.lowercase_ascii (String.trim line) = "y" -> true
    | exception End_of_file -> false
    | _ -> false
  in
  let embedding_base_url, embedding_model, embedding_dimension =
    if sep_embed then begin
      let emb_base =
        let hint = "https://api.openai.com/v1" in
        Printf.printf "Embedding API Base URL (default: %s): %!" hint;
        match input_line stdin with
        | line when String.trim line <> "" -> Some (String.trim line)
        | exception End_of_file -> Some hint
        | _ -> Some hint
      in
      let emb_model =
        Printf.printf "Embedding model name (default: text-embedding-3-small): %!";
        match input_line stdin with
        | line when String.trim line <> "" -> Some (String.trim line)
        | exception End_of_file -> None
        | _ -> None
      in
      let emb_dim =
        Printf.printf "Embedding dimension [1536]: %!";
        match input_line stdin with
        | line when String.trim line <> "" ->
          (match int_of_string_opt (String.trim line) with
           Some n -> n | None -> 1536)
        | exception End_of_file -> 1536
        | _ -> 1536
      in
      (emb_base, emb_model, emb_dim)
    end else
      (None, None, default.embedding_dimension)
  in

  let cfg = {
    provider; api_key; api_base; model;
    persistence = "sqlite"; db_uri = None;
    temperature; system_prompt = default_system_prompt; max_iterations;
    max_tokens = None; top_p = None;
    parallel_tool_execution = true;
    event_retention_days = 7.0;
    auto_extract = true;
    embedding_base_url; embedding_model; embedding_dimension;
    checkpoint_enabled = true; checkpoint_interval = 10; context_budget_tokens = 100000;
  } in
  save cfg;
  Printf.printf "\nSaved config to %s\n%!" (config_path ())
