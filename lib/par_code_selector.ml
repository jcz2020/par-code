(* par_code_selector.ml — picks the best of N max-mode candidates.
 *
 * A dedicated agent rather than the judge: the judge answers "is the goal met",
 * this answers "which candidate is best and does it need executing". Different
 * prompt, different schema, different model knobs. *)

open Par

let selector_agent_id = "selector"

let selector_system_prompt = {|
You are a selector for a coding agent running in max mode. Several independent
candidates answered the same user request. Choose the one the user should get.

Judge by correctness first, then completeness, then simplicity. Prefer a
candidate that reuses existing code over one that introduces new machinery.
Ignore length: a shorter answer that solves the request beats a longer one that
does not.

Decide the kind:
- "answer"  — the chosen candidate already satisfies the request as written text.
- "execute" — the chosen candidate is a plan of work the user still needs carried
  out (code to write, files to change). Put the instruction for that execution
  in "plan".

Respond with JSON only, no prose before or after:
{"choice": <1-based candidate number>, "kind": "answer" | "execute", "plan": "<instruction for the execution step, empty when kind is answer>", "reasoning": "<one sentence on why this candidate wins>"}
|}

type kind = Answer | Execute

type choice = {
  index : int;
  kind : kind;
  plan : string;
  reasoning : string;
  total_tokens : int option;
}

let default_choice = {
  index = 0;
  kind = Answer;
  plan = "";
  reasoning = "selector unavailable";
  total_tokens = None;
}

let max_candidate_chars = 2000

let truncate ?(limit = max_candidate_chars) (s : string) : string =
  if String.length s <= limit then s
  else String.sub s 0 limit ^ "\n...[truncated]"

let build_message ~(user_message : string) (candidates : string list) : string =
  let b = Buffer.create 1024 in
  Buffer.add_string b "User request:\n";
  Buffer.add_string b user_message;
  Buffer.add_string b "\n\nCandidates:";
  List.iteri
    (fun i text ->
       Buffer.add_string b
         (Printf.sprintf "\n\n### Candidate %d\n%s" (i + 1) (truncate text)))
    candidates;
  Buffer.contents b

let choice_of_int n = function
  | Some c when c >= 1 && c <= n -> Some (c - 1)
  | Some 0 -> Some 0
  | _ -> None

let parse_choice ~(n : int) (text : string) : choice option =
  match Par_code_json_extract.extract_object text with
  | None -> None
  | Some json_str ->
    try
      let json = Yojson.Safe.from_string json_str in
      let open Yojson.Safe.Util in
      let raw =
        match json |> member "choice" with
        | `Int i -> Some i
        | `Float f -> Some (int_of_float f)
        | `String s -> int_of_string_opt (String.trim s)
        | _ -> None
      in
      let kind =
        match json |> member "kind" |> to_string_option with
        | Some k when String.lowercase_ascii (String.trim k) = "execute" -> Execute
        | _ -> Answer
      in
      let plan =
        json |> member "plan" |> to_string_option |> Option.value ~default:""
      in
      let reasoning =
        json |> member "reasoning" |> to_string_option
        |> Option.value ~default:""
      in
      (match choice_of_int n raw with
       | Some index -> Some { index; kind; plan; reasoning; total_tokens = None }
       | None -> Some { default_choice with reasoning })
    with _ -> None

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
  | Types.Cancelled (Types.Guard_cancelled reason) ->
    Printf.sprintf "Cancelled by guard: %s" reason

let choose ~(rt : Runtime.runtime) ~(user_message : string)
    (candidates : string list) : (choice, string) result =
  if candidates = [] then Error "no candidates to choose from"
  else
    let message = build_message ~user_message candidates in
    match
      Runtime.invoke_generate rt ~agent_id:selector_agent_id ~message ~save:false
        ~update_current:false ()
    with
    | Error (e, _) -> Error (error_to_string e)
    | Ok result ->
      (match parse_choice ~n:(List.length candidates) result.Types.text with
       | Some c -> Ok { c with total_tokens = result.Types.total_tokens }
       | None -> Error "selector returned no parsable JSON")
