(* par_code_memory_tools.ml — LLM-facing memory tools for par-code v0.3.0.
 *
 * Two tool bindings that expose the project memory layer to the agent:
 * - recall_memory: FTS5 full-text search over project memories
 * - remember_memory: Save a new memory entry during a coding session
 *
 * Each tool is a [Types.tool_binding] with descriptor + handler, compatible
 * with [Runtime.register_tool]. *)

open Par

(* -- Helpers -------------------------------------------------------------- *)

(** Convert a Unix timestamp (float) to ISO 8601 UTC string. *)
let iso8601_of_float ts =
  let tm = Unix.gmtime ts in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
    (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1) tm.Unix.tm_mday
    tm.Unix.tm_hour tm.Unix.tm_min tm.Unix.tm_sec

(** Convert a [Par_code_memory.kind] to its JSON string representation. *)
let kind_to_string = function
  | Par_code_memory.Preference -> "preference"
  | Par_code_memory.Convention -> "convention"
  | Par_code_memory.Insight    -> "insight"
  | Par_code_memory.Gotcha     -> "gotcha"
  | Par_code_memory.Task_map   -> "task_map"

(** Parse a [Par_code_memory.kind] from a string. *)
let kind_of_string_opt = function
  | "preference" -> Some Par_code_memory.Preference
  | "convention" -> Some Par_code_memory.Convention
  | "insight"    -> Some Par_code_memory.Insight
  | "gotcha"     -> Some Par_code_memory.Gotcha
  | "task_map"   -> Some Par_code_memory.Task_map
  | _            -> None

(** Serialize a [Par_code_memory.memory] record to JSON. *)
let memory_to_json (m : Par_code_memory.memory) : Yojson.Safe.t =
  `Assoc
    [ ("id",          `Int m.id)
    ; ("kind",        `String (kind_to_string m.kind))
    ; ("content",     `String m.content)
    ; ("summary",     `String m.summary)
    ; ("citations",   `List (List.map (fun s -> `String s) m.citations))
    ; ("created_at",  `String (iso8601_of_float m.created_at))
    ; ("usage_count", `Int m.usage_count)
    ]

(** Build an [Error] handler result with the given category and message. *)
let tool_error ~category ~message () =
  let open Types in
  Error { category; message; retryable = false; metadata = [] }

(* -- Tool schemas --------------------------------------------------------- *)

let recall_input_schema : Yojson.Safe.t =
  `Assoc
    [ ("type", `String "object")
    ; ("properties", `Assoc
        [ ("query", `Assoc
            [ ("type", `String "string")
            ; ("description", `String "What to search for")
            ])
        ; ("limit", `Assoc
            [ ("type", `String "integer")
            ; ("description", `String "Max results to return (default 5)")
            ; ("default", `Int 5)
            ])
        ])
    ; ("required", `List [`String "query"])
    ]

let remember_input_schema : Yojson.Safe.t =
  `Assoc
    [ ("type", `String "object")
    ; ("properties", `Assoc
        [ ("kind", `Assoc
            [ ("type", `String "string")
            ; ("enum", `List
                [ `String "preference"; `String "convention"
                ; `String "insight"; `String "gotcha"; `String "task_map"
                ])
            ; ("description", `String "Memory category")
            ])
        ; ("content", `Assoc
            [ ("type", `String "string")
            ; ("description", `String "Full memory text")
            ])
        ; ("summary", `Assoc
            [ ("type", `String "string")
            ; ("description", `String "One-line summary for the index")
            ])
        ; ("citations", `Assoc
            [ ("type", `String "array")
            ; ("items", `Assoc [("type", `String "string")])
            ; ("description", `String "file:line references")
            ])
        ])
    ; ("required", `List [`String "kind"; `String "content"; `String "summary"])
    ]

(* -- Tool bindings -------------------------------------------------------- *)

let tools (mem_db : Par_code_memory.t) : Types.tool_binding list =
  let open Types in
  let recall_memory =
    let descriptor =
      { name = "recall_memory"
      ; description =
          "Search project memories by full-text search. Returns memories \
           relevant to the query, ranked by relevance. Use this when you need \
           to recall past decisions, conventions, preferences, or gotchas \
           about this project."
      ; input_schema = recall_input_schema
      ; output_schema = None
      ; permission = Allow
      ; timeout = Some 10.0
      ; concurrency_limit = None
      ; on_update = None
      ; cache_control = None
      }
    in
    let handler = fun input _tok ->
      let open Yojson.Safe.Util in
      let query_opt = input |> member "query" |> to_string_option in
      match query_opt with
      | None ->
        tool_error ~category:(Invalid_input "Missing required field: query")
          ~message:"The 'query' field is required." ()
      | Some query ->
        let limit =
          match input |> member "limit" with
          | `Null -> 5
          | j -> (try to_int j with _ -> 5)
        in
        let project_id = Par_code_memory.resolve_project_id () in
        (match Par_code_memory.recall mem_db ~project_id ~query ~limit () with
         | Ok memories ->
           let json_memories = `List (List.map memory_to_json memories) in
           Success (`Assoc [("memories", json_memories)])
         | Error (`Db_error msg) ->
           tool_error ~category:(Internal "Database error")
             ~message:(Printf.sprintf "Memory recall failed: %s" msg) ())
    in
    { descriptor; handler }
  in
  let remember_memory =
    let descriptor =
      { name = "remember_memory"
      ; description =
          "Save a new memory for this project. Only call this when a future \
           agent will plausibly act better because of what you write here. \
           If unsure, do not remember. Accepts: kind \
           (preference|convention|insight|gotcha|task_map), content (the full \
           memory text), summary (one-line description for the index), \
           citations (optional file:line references)."
      ; input_schema = remember_input_schema
      ; output_schema = None
      ; permission = Allow
      ; timeout = Some 10.0
      ; concurrency_limit = None
      ; on_update = None
      ; cache_control = None
      }
    in
    let handler = fun input _tok ->
      let open Yojson.Safe.Util in
      let kind_str_opt = input |> member "kind" |> to_string_option in
      let content_opt = input |> member "content" |> to_string_option in
      let summary_opt = input |> member "summary" |> to_string_option in
      match kind_str_opt, content_opt, summary_opt with
      | None, _, _ ->
        tool_error ~category:(Invalid_input "Missing required field: kind")
          ~message:"The 'kind' field is required." ()
      | _, None, _ ->
        tool_error ~category:(Invalid_input "Missing required field: content")
          ~message:"The 'content' field is required." ()
      | _, _, None ->
        tool_error ~category:(Invalid_input "Missing required field: summary")
          ~message:"The 'summary' field is required." ()
      | Some kind_str, Some content, Some summary ->
        (match kind_of_string_opt kind_str with
         | None ->
           tool_error
             ~category:(Invalid_input (Printf.sprintf "Invalid kind: %s" kind_str))
             ~message:
               (Printf.sprintf
                  "Invalid kind '%s'. Must be one of: preference, convention, \
                   insight, gotcha, task_map." kind_str)
             ()
         | Some kind ->
           let citations =
             match input |> member "citations" with
             | `Null -> []
             | `List items ->
               List.filter_map (fun j ->
                 match to_string_option j with
                 | Some s -> Some s
                 | None -> None
               ) items
             | _ -> []
           in
           let project_id = Par_code_memory.resolve_project_id () in
           (match Par_code_memory.add mem_db
                   ~project_id ~kind ~content ~summary ~citations ~source:`Agent
            with
            | Ok id ->
              Success (`Assoc [("id", `Int id); ("status", `String "saved")])
            | Error (`Db_error msg) ->
              tool_error ~category:(Internal "Database error")
                ~message:(Printf.sprintf "Failed to save memory: %s" msg) ()))
    in
    { descriptor; handler }
  in
  [ recall_memory; remember_memory ]
