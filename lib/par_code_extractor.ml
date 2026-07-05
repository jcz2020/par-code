(* par_code_extractor.ml — Auto-extraction module for project memory.
 *
 * Uses a dedicated LLM agent to extract structured memories from conversation
 * transcripts. Quality-gated: only extracts facts that would help a future
 * agent act better. Deduplicates against existing memories before storing.
 *
 * The extractor agent is registered by setup.ml (Wave 2). This module only
 * calls it via [Runtime.invoke_generate]. *)

open Par

(* -------------------------------------------------------------------------- *)
(* Agent configuration                                                       *)
(* -------------------------------------------------------------------------- *)

let extractor_agent_id = "memory-extractor"

let extractor_system_prompt = {|
You are a memory extraction agent. Analyze the conversation transcript and
extract durable facts worth remembering for future sessions.

## Categories

- **preference**: User's stated or demonstrated preferences (coding style,
  tool choices, naming conventions, communication style).
- **convention**: Project-level conventions (commit message format, branch
  naming, directory layout, testing patterns, review process).
- **insight**: Non-obvious understanding about the codebase, architecture
  decisions, or domain logic that isn't visible from code alone.
- **gotcha**: Pitfalls, workarounds, known issues, edge cases, things that
  break in unexpected ways.
- **task_map**: Mapping of high-level tasks to specific files, modules, or
  workflows (e.g. "to change auth, edit X and Y and run Z").

## Quality Gate

For each candidate fact, ask: "Will a future agent plausibly act better if it
knows this?" If the answer is no or uncertain, skip it. Do NOT extract:

- Transient state (current bugs being debugged, temporary workarounds)
- Trivially derivable facts (file X exists, function Y takes int)
- One-off opinions that don't generalize
- Information that changes every session

## Output Format

Return a JSON array. Each element:
{"kind":"<category>","content":"<full detail>","summary":"<one-line summary>","citations":["<file or context reference>"]}

Return [] if nothing meets the quality gate. Return ONLY valid JSON, no prose.
|}

(* -------------------------------------------------------------------------- *)
(* Types                                                                     *)
(* -------------------------------------------------------------------------- *)

type extraction_result = {
  kind : Par_code_memory.kind;
  content : string;
  summary : string;
  citations : string list;
}

(* -------------------------------------------------------------------------- *)
(* Transcript serialization                                                  *)
(* -------------------------------------------------------------------------- *)

let extract_text_from_blocks (blocks : Types.content_block list) : string =
  let buf = Buffer.create 512 in
  List.iter (function
    | Types.Text_block { text; _ } ->
      if Buffer.length buf > 0 then Buffer.add_char buf '\n';
      Buffer.add_string buf text
    | _ -> ()
  ) blocks;
  Buffer.contents buf

let serialize_transcript (conv : Types.conversation) : string =
  let user_assistant_msgs =
    List.filter (fun (m : Types.message) ->
      match m.Types.role with
      | Types.User | Types.Assistant -> true
      | Types.System | Types.Tool -> false
    ) conv.Types.messages
  in
  if List.length user_assistant_msgs < 2 then ""
  else
    let buf = Buffer.create 4096 in
    List.iter (fun (m : Types.message) ->
      let role = match m.Types.role with
        | Types.User -> "User"
        | Types.Assistant -> "Assistant"
        | _ -> assert false  (* filtered above *)
      in
      let text = extract_text_from_blocks m.Types.content_blocks in
      if text <> "" then begin
        Buffer.add_string buf (Printf.sprintf "## %s\n\n%s\n\n" role text)
      end
    ) user_assistant_msgs;
    let full = Buffer.contents buf in
    if String.length full > 8000 then
      String.sub full 0 8000
    else
      full

(* -------------------------------------------------------------------------- *)
(* JSON parsing                                                              *)
(* -------------------------------------------------------------------------- *)

let kind_of_string_opt (s : string) : Par_code_memory.kind option =
  match String.lowercase_ascii (String.trim s) with
  | "preference" -> Some Par_code_memory.Preference
  | "convention" -> Some Par_code_memory.Convention
  | "insight"    -> Some Par_code_memory.Insight
  | "gotcha"     -> Some Par_code_memory.Gotcha
  | "task_map"   -> Some Par_code_memory.Task_map
  | _            -> None

let safe_string_field (assoc : (string * Yojson.Safe.t) list) (key : string) : string =
  match List.assoc_opt key assoc with
  | Some (`String s) -> s
  | _ -> ""

let safe_string_list_field (assoc : (string * Yojson.Safe.t) list) (key : string) : string list =
  match List.assoc_opt key assoc with
  | Some (`List items) ->
    List.filter_map (function `String s -> Some s | _ -> None) items
  | _ -> []

let parse_extraction_result (json : Yojson.Safe.t) : extraction_result option =
  match json with
  | `Assoc assoc ->
    let kind_str = safe_string_field assoc "kind" in
    let content = safe_string_field assoc "content" in
    let summary = safe_string_field assoc "summary" in
    let citations = safe_string_list_field assoc "citations" in
    if content = "" || summary = "" then None
    else begin
      match kind_of_string_opt kind_str with
      | Some kind -> Some { kind; content; summary; citations }
      | None ->
        Printf.eprintf "Warning: unknown memory kind %S, skipping\n%!" kind_str;
        None
    end
  | _ -> None

let parse_extraction_response (text : string) : extraction_result list =
  if String.trim text = "" then []
  else
    match Yojson.Safe.from_string (String.trim text) with
    | `List items ->
      List.filter_map parse_extraction_result items
    | _ ->
      Printf.eprintf "Warning: extraction response is not a JSON array, skipping.\n%!";
      []
    | exception Yojson.Json_error msg ->
      Printf.eprintf "Warning: failed to parse extraction JSON: %s\n%!" msg;
      []

(* -------------------------------------------------------------------------- *)
(* Deduplication                                                             *)
(* -------------------------------------------------------------------------- *)

let deduplicate (mem_db : Par_code_memory.t) ~project_id (r : extraction_result)
    : [`New of Par_code_memory.kind * string * string * string list | `Duplicate of int] =
  let existing = match Par_code_memory.recall mem_db ~project_id ~query:r.summary ~limit:5 () with
    | Ok l -> l
    | Error _ -> []
  in
  let new_lower = String.lowercase_ascii (String.trim r.summary) in
  let is_dup (m : Par_code_memory.memory) =
    let existing_lower = String.lowercase_ascii (String.trim m.Par_code_memory.summary) in
    (* substring match in either direction *)
    String.length new_lower > 0 &&
    String.length existing_lower > 0 &&
    (Str.string_match (Str.regexp_string new_lower) existing_lower 0 ||
     Str.string_match (Str.regexp_string existing_lower) new_lower 0)
  in
  match List.find_opt is_dup existing with
  | Some m -> `Duplicate m.Par_code_memory.id
  | None -> `New (r.kind, r.content, r.summary, r.citations)

(* -------------------------------------------------------------------------- *)
(* Main entry point                                                          *)
(* -------------------------------------------------------------------------- *)

let error_to_string (e : Types.error_category) =
  match e with
  | Types.Timeout -> "Timeout"
  | Types.Invalid_input s -> Printf.sprintf "Invalid input: %s" s
  | Types.External_failure s -> Printf.sprintf "External failure: %s" s
  | Types.Rate_limited -> "Rate limited"
  | Types.Permission_denied s -> Printf.sprintf "Permission denied: %s" s
  | Types.Internal s -> Printf.sprintf "Internal error: %s" s
  | Types.Embedding_unsupported -> "Embedding unsupported"

let run_extraction (rt : Runtime.runtime) (mem_db : Par_code_memory.t)
    ~project_id (conv : Types.conversation) : unit =
  let transcript = serialize_transcript conv in
  if transcript = "" then ()
  else begin
    Printf.eprintf "[extracting memories...]\n%!";
    match Runtime.invoke_generate rt ~agent_id:extractor_agent_id ~message:transcript () with
    | Error (e, _) ->
      Printf.eprintf "Warning: memory extraction failed: %s\n%!"
        (error_to_string e)
    | Ok result ->
      let extractions = parse_extraction_response result.Types.text in
      let new_count = ref 0 in
      let dup_count = ref 0 in
      List.iter (fun r ->
        match deduplicate mem_db ~project_id r with
        | `Duplicate _ -> incr dup_count
        | `New (kind, content, summary, citations) ->
          (match Par_code_memory.add mem_db ~project_id ~kind ~content ~summary
                  ~citations ~source:`Agent with
           | Ok _ -> incr new_count
           | Error (`Db_error msg) ->
             Printf.eprintf "Warning: failed to store memory: %s\n%!" msg)
      ) extractions;
      Printf.eprintf "Extracted %d memories (%d duplicates skipped).\n%!"
        !new_count !dup_count
  end
