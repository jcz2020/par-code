open Par

let goal_done_input_schema : Yojson.Safe.t =
  `Assoc [
    ("type", `String "object");
    ("properties", `Assoc [
      ("summary", `Assoc [
        ("type", `String "string");
        ("description", `String "Summary of what was accomplished and evidence that the goal is met");
      ]);
    ]);
    ("required", `List [`String "summary"]);
  ]

let goal_done_tool_binding : Types.tool_binding =
  let descriptor = {
    Types.
    name = "goal_done";
    description =
      "Signal that you believe the current goal has been achieved. \
       Provide a summary of what was accomplished with concrete evidence \
       (test results, build output, file changes). The judge model will \
       verify your claim before the goal is marked as complete.";
    input_schema = goal_done_input_schema;
    output_schema = None;
    permission = Types.Allow;
    timeout = Some 30.0;
    concurrency_limit = None;
    on_update = None;
    cache_control = None;
  } in
  let handler json _tok =
    let open Yojson.Safe.Util in
    let summary =
      try json |> member "summary" |> to_string
      with Type_error _ -> ""
    in
    if summary = "" then
      Types.Error
        { category = Types.Invalid_input "goal_done"
        ; message = "Missing 'summary' field"
        ; retryable = false
        ; metadata = []
        }
    else begin
      Par_code_goal.set_done_signal summary;
      Types.Success (`String "Completion signaled — the judge will verify your claim.")
    end
  in
  { descriptor; handler }
