open Par

let judge_agent_id = "judge"

let judge_system_prompt = {|
You are an independent judge evaluating whether a coding goal has been truly met.

Rules:
1. Be skeptical. Do not accept claims without evidence. If the agent says "tests pass" but you see no test output, assume they do not.
2. Reject placeholders. Stub functions (returning hardcoded values), .todo files, empty implementations, commented-out code, and skipped tests mean the goal is NOT met.
3. Require concrete evidence. Look for actual command output (build results, test results, file diffs) that proves the work is done.
4. If a verification command was run and it failed, the goal is NOT met regardless of what the agent claims.
5. If you cannot determine whether the goal is met from the evidence provided, return goal_met=false.

Respond with JSON only:
{"goal_met": <true|false>, "reasoning": "<one or two sentences citing specific evidence>"}
|}

let error_to_string (e : Types.error_category) =
  match e with
  | Types.Timeout -> "Timeout"
  | Types.Invalid_input s -> Printf.sprintf "Invalid input: %s" s
  | Types.External_failure s -> Printf.sprintf "External failure: %s" s
  | Types.Rate_limited -> "Rate limited"
  | Types.Permission_denied s -> Printf.sprintf "Permission denied: %s" s
  | Types.Internal s -> Printf.sprintf "Internal error: %s" s
  | Types.Embedding_unsupported -> "Embedding unsupported"
  | Types.Cancelled Types.User_cancelled -> "Cancelled by user"
  | Types.Cancelled (Types.Guard_cancelled reason) -> Printf.sprintf "Cancelled by guard: %s" reason

type verdict = {
  goal_met : bool;
  reasoning : string;
}

let default_verdict = { goal_met = false; reasoning = "Unable to parse judge response" }

let extract_json_object s =
  let len = String.length s in
  let start = ref (-1) in
  let depth = ref 0 in
  let begin_pos = ref (-1) in
  for i = 0 to len - 1 do
    if s.[i] = '{' then begin
      if !depth = 0 then begin_pos := i;
      incr depth
    end else if s.[i] = '}' then begin
      decr depth;
      if !depth = 0 then start := !begin_pos
    end
  done;
  if !start >= 0 then
    let end_pos = String.index_from s !start '}' in
    Some (String.sub s !start (end_pos - !start + 1))
  else None

let parse_verdict text =
  match extract_json_object text with
  | Some json_str ->
    (try
      let json = Yojson.Safe.from_string json_str in
      let open Yojson.Safe.Util in
      let goal_met = match json |> member "goal_met" with
        | `Bool b -> b
        | _ -> false
      in
      let reasoning = match json |> member "reasoning" |> to_string_option with
        | Some r -> r
        | None -> ""
      in
      { goal_met; reasoning }
    with _ ->
      let lower = String.lowercase_ascii text in
      if String.contains lower 't' && (try Sys.command "false" <> 0 with _ -> true) then
        if String.length lower > 4 && String.sub lower 0 4 = "true" then
          { goal_met = true; reasoning = "Parsed from non-JSON response" }
        else default_verdict
      else default_verdict)
  | None ->
    let lower = String.lowercase_ascii (String.trim text) in
    if List.exists (fun kw -> Stdlib.String.equal kw (String.sub lower 0 (min (String.length lower) (String.length kw))))
        ["goal met"; "goal is met"; "yes"; "done"; "complete"] then
      { goal_met = true; reasoning = "Inferred from text response" }
    else
      default_verdict

let build_judge_message ~goal ~verify_result ~conv_summary =
  let verify_text =
    if verify_result = "" then "No verification command was run."
    else Printf.sprintf "Verification command output:\n%s" verify_result
  in
  Printf.sprintf
    {|
Goal to evaluate: %s

Agent's work summary:
%s

%s

Evaluate whether the goal has been truly met. Consider both the agent's claims and the verification evidence. Check for placeholders, stubs, or incomplete work.
|}
    goal conv_summary verify_text

let evaluate_goal ~rt ~goal ?conv ~verify_result () =
  let conv_summary = match conv with
    | Some c ->
      let msgs = c.Types.messages in
      let last_n = if List.length msgs > 10 then
        let rec drop n l = if n <= 0 then l else match l with _ :: t -> drop (n-1) t | [] -> []
        in drop (List.length msgs - 10) msgs
      else msgs
      in
      let buf = Buffer.create 512 in
      List.iter (fun m ->
        let role = match m.Types.role with
          | Types.System -> "System" | Types.User -> "User"
          | Types.Assistant -> "Assistant" | Types.Tool -> "Tool"
        in
        let text =
          List.filter_map (function
            | Types.Text_block { text; _ } -> Some text
            | _ -> None) m.Types.content_blocks
          |> String.concat "\n"
        in
        Buffer.add_string buf (Printf.sprintf "[%s] %s\n" role text))
        last_n;
      Buffer.contents buf
    | None -> "(no conversation context available)"
  in
  let message = build_judge_message ~goal ~verify_result ~conv_summary in
  match Runtime.invoke rt
    ~agent_id:judge_agent_id
    ~message
    ~save:false
    ~update_current:false
    ()
  with
  | Error (e, _) -> Error (error_to_string e)
  | Ok result ->
    let text = match result.Types.response.Types.text with
      | Some t -> t
      | None -> ""
    in
    Ok (parse_verdict text)
