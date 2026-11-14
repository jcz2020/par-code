open Par

let explore_agent_id = "explore"
let general_agent_id = "general"

let explore_system_prompt = {|
You are a code exploration agent. Your job is to investigate specific questions
about the codebase and report findings concisely.

You have read-only tools — no writing or editing. Focus on answering the
specific question asked. Do not produce plans or action items — just report
what you find.

Be thorough but efficient. Use grep and find to locate relevant code, read it,
and summarize your findings in a clear, structured way.
|}

let general_system_prompt = {|
You are a general-purpose coding agent. Complete the assigned task using all
available tools. Write code, run commands, and edit files as needed.

Work autonomously — when you're done, provide a concise summary of what you did,
what files you changed, and any issues you encountered.
|}

let error_to_string (e : Types.error_category) =
  match e with
  | Types.Timeout -> "Timeout"
  | Types.Invalid_input s -> Printf.sprintf "Invalid input: %s" s
  | Types.External_failure s -> Printf.sprintf "External failure: %s" s
  | Types.Rate_limited -> "Rate limited"
  | Types.Permission_denied s -> Printf.sprintf "Permission denied: %s" s
  | Types.Internal s -> Printf.sprintf "Internal error: %s" s
  | Types.Embedding_unsupported -> "Embedding not supported"
  | Types.Cancelled Types.User_cancelled -> "Cancelled by user"
  | Types.Cancelled (Types.Guard_cancelled reason) -> Printf.sprintf "Cancelled by guard: %s" reason

let delegate_input_schema : Yojson.Safe.t =
  `Assoc
    [ ("type", `String "object")
    ; ("properties", `Assoc
        [ ("agent_type", `Assoc
            [ ("type", `String "string")
            ; ("enum", `List [`String "explore"; `String "general"])
            ; ("description", `String
                 "Type of subagent: 'explore' for read-only investigation, \
                  'general' for full-capability work")
            ])
        ; ("task", `Assoc
            [ ("type", `String "string")
            ; ("description", `String
                 "Clear, specific task description for the subagent")
            ])
        ])
    ; ("required", `List [`String "agent_type"; `String "task"])
    ]

let make_delegate_tool
    ~rt
    ~(ui : Par_code_ui.backend Lazy.t)
    : Types.tool_binding =
  let open Types in
  let descriptor =
    { name = "delegate"
    ; description =
        "Delegate a task to a subagent for focused investigation or \
         implementation work. The subagent runs autonomously and returns its \
         findings. Use 'explore' for read-only codebase investigation \
         (finding files, understanding architecture) and 'general' for tasks \
         requiring file edits or bash commands."
    ; input_schema = delegate_input_schema
    ; output_schema = None
    ; permission = Allow
    ; timeout = Some 300.0
    ; concurrency_limit = None
    ; on_update = None
    ; cache_control = None
    }
  in
  let handler json tok =
    let open Yojson.Safe.Util in
    let agent_type, task =
      try
        (json |> member "agent_type" |> to_string,
         json |> member "task" |> to_string)
      with Type_error _ ->
        ("", "")
    in
    if agent_type = "" || task = "" then
      Types.Error
        { category = Types.Invalid_input "delegate"
        ; message = "Missing 'agent_type' or 'task' field"
        ; retryable = false
        ; metadata = []
        }
    else
    match agent_type with
    | "explore" | "general" as at ->
      let agent_id =
        if at = "explore" then explore_agent_id
        else general_agent_id
      in
      let backend = Lazy.force ui in
      Par_code_ui.render_delegation_start backend ~agent_type:at ~task;
      (match Runtime.invoke rt
              ~agent_id
              ~message:task
              ~save:false
              ~update_current:false
              ~cancellation_token:tok
              ~on_tool_event:(fun evt ->
                Par_code_ui.render_delegation_tool_event backend ~agent_type:at evt)
              ()
       with
       | Error (err, _conv) ->
         let msg = Printf.sprintf "Subagent failed: %s" (error_to_string err) in
         Par_code_ui.render_delegation_error backend ~agent_type:at ~error:msg;
         Types.Error
           { category = Types.External_failure "delegate"
           ; message = msg
           ; retryable = false
           ; metadata = []
           }
       | Ok result ->
         let text =
           match result.response.text with
           | Some t when String.length t > 0 -> t
           | _ ->
             (match result.response.Types.finish_reason with
              | Types.Tool_calls ->
                "(subagent hit max iterations — work may be incomplete)"
              | Types.Max_tokens ->
                "(subagent hit max tokens — output truncated)"
              | _ -> "(subagent returned no text)")
         in
         Par_code_ui.render_delegation_result backend ~agent_type:at ~text;
         Success (`String text))
    | other ->
      Error
        { category = Invalid_input "delegate"
        ; message =
            Printf.sprintf
              "Unknown agent type '%s'. Use 'explore' or 'general'." other
        ; retryable = false
        ; metadata = []
        }
  in
  { descriptor; handler }

(* ---------------------------------------------------------------------- *)
(* delegate_batch — v0.10.0: bounded fan-out over independent subagent tasks *)
(* ---------------------------------------------------------------------- *)

let batch_max_tasks = 5

let batch_input_schema : Yojson.Safe.t =
  `Assoc
    [ ("type", `String "object")
    ; ( "properties"
      , `Assoc
          [ ( "tasks"
            , `Assoc
                [ ("type", `String "array")
                ; ("minItems", `Int 1)
                ; ("maxItems", `Int batch_max_tasks)
                ; ( "description"
                  , `String
                      "Read-only 'explore' tasks to run concurrently. Use it \
                       when the investigations do not depend on each other." )
                ; ("items", delegate_input_schema)
                ] )
          ] )
    ; ("required", `List [ `String "tasks" ])
    ]

let text_of_response (r : Types.llm_response) : string =
  match r.text with
  | Some t when String.length t > 0 -> t
  | _ ->
    (match r.finish_reason with
     | Types.Tool_calls -> "(subagent hit max iterations - work may be incomplete)"
     | Types.Max_tokens -> "(subagent hit max tokens - output truncated)"
     | _ -> "(subagent returned no text)")

(* Validation is pure so it can be tested without a Runtime or an LLM. *)
let parse_batch_input (json : Yojson.Safe.t) :
  ((string * string) list, string) result =
  let open Yojson.Safe.Util in
  let raw = match json |> member "tasks" with `List l -> l | _ -> [] in
  let parsed =
    List.filter_map
      (fun item ->
         match item |> member "agent_type", item |> member "task" with
         | `String at, `String task when task <> "" -> Some (at, task)
         | _ -> None)
      raw
  in
  let count = List.length parsed in
  if parsed = [] then
    Error "'tasks' must contain at least one {agent_type, task} object"
  else if count <> List.length raw then
    Error "every 'tasks' entry needs a string 'agent_type' and a non-empty 'task'"
  else if count > batch_max_tasks then
    Error (Printf.sprintf "at most %d tasks per call" batch_max_tasks)
  else
    match List.find_opt (fun (at, _) -> at <> "explore") parsed with
    | Some ("general", _) ->
      Error
        "delegate_batch runs read-only 'explore' tasks only: two 'general' \
         subagents would edit one workspace at once. Use 'delegate' for \
         anything that writes."
    | Some (at, _) ->
      Error (Printf.sprintf "Unknown agent type '%s'. Use 'explore'." at)
    | None -> Ok parsed

let make_delegate_batch_tool
    ~rt
    ~(ui : Par_code_ui.backend Lazy.t)
    : Types.tool_binding =
  let open Types in
  let descriptor =
    { name = "delegate_batch"
    ; description =
        "Run up to 5 read-only 'explore' subagents concurrently and return \
         every result. Use this instead of calling 'delegate' several times \
         when the investigations are independent. Read-only by design: two \
         'general' subagents would edit the same workspace at once, so use \
         'delegate' for anything that writes. One failing task does not abort \
         the others."
    ; input_schema = batch_input_schema
    ; output_schema = None
    ; permission = Allow
    ; timeout = Some 900.0
    ; concurrency_limit = None
    ; on_update = None
    ; cache_control = None
    }
  in
  let invalid message =
    Types.Error
      { category = Types.Invalid_input "delegate_batch"
      ; message
      ; retryable = false
      ; metadata = []
      }
  in
  let handler json tok =
    match parse_batch_input json with
    | Error msg -> invalid msg
    | Ok parsed ->
      let count = List.length parsed in
      let backend = Lazy.force ui in
        List.iteri
          (fun i (at, task) ->
             Par_code_ui.render_delegation_start backend ~agent_type:at
               ~task:(Printf.sprintf "[%d/%d] %s" (i + 1) count task))
          parsed;
        let results =
          Par_code_parallel.map
            ~parallel_limit:Par_code_parallel.default_limit
            (fun (_at, task) ->
               let agent_id = explore_agent_id in
               Runtime.invoke rt ~agent_id ~message:task ~save:false
                 ~update_current:false ~cancellation_token:tok ())
            parsed
        in
        (* Render and report in input order: the terminal never has two
           subagents writing into the same line. *)
        let lines =
          List.mapi
            (fun i (r, (at, _)) ->
               let head = Printf.sprintf "[%d/%d]" (i + 1) count in
               match r with
               | Result.Error exn ->
                 let msg = Printf.sprintf "Subagent crashed: %s" (Printexc.to_string exn) in
                 Par_code_ui.render_delegation_error backend ~agent_type:at ~error:msg;
                 Printf.sprintf "%s crashed: %s" head (Printexc.to_string exn)
               | Result.Ok (Result.Error (err, _)) ->
                 let msg = Printf.sprintf "Subagent failed: %s" (error_to_string err) in
                 Par_code_ui.render_delegation_error backend ~agent_type:at ~error:msg;
                 Printf.sprintf "%s failed: %s" head (error_to_string err)
               | Result.Ok (Result.Ok result) ->
                 let text = text_of_response result.Types.response in
                 Par_code_ui.render_delegation_result backend ~agent_type:at ~text;
                 Printf.sprintf "%s\n%s" head text)
            (List.combine results parsed)
        in
        Success (`String (String.concat "\n\n" lines))
  in
  { descriptor; handler }
