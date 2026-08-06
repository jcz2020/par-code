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
    ; timeout = None
    ; concurrency_limit = None
    ; on_update = None
    ; cache_control = None
    }
  in
  let handler json _tok =
    let open Yojson.Safe.Util in
    let agent_type = json |> member "agent_type" |> to_string in
    let task = json |> member "task" |> to_string in
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
              ~on_tool_event:(fun evt ->
                Par_code_ui.render_delegation_tool_event backend ~agent_type:at evt)
              ()
       with
       | Error (err, _conv) ->
         let msg = Printf.sprintf "Subagent failed: %s" (error_to_string err) in
         Par_code_ui.render_delegation_error backend ~agent_type:at ~error:msg;
         Error
           { category = External_failure "delegate"
           ; message = msg
           ; retryable = false
           ; metadata = []
           }
       | Ok result ->
         let text =
           match result.response.text with
           | Some t when String.length t > 0 -> t
           | _ -> "(subagent returned no text)"
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
