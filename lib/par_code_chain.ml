open Par

type turn_outcome =
  | Chain_continue of string
  | Chain_stop

type chain_state = {
  goal : Par_code_goal.goal_state option;
  mode : Par_code_mode.mode;
  auto_chain : bool;
  doom_aborted : bool;
  cancelled : bool;
  consecutive_invoke_errors : int;
}

let should_continue (s : chain_state) : bool =
  match s.goal with
  | None -> false
  | Some g ->
    g.status = Active
    && s.mode = Par_code_mode.Build
    && s.auto_chain
    && (not s.doom_aborted)
    && (not s.cancelled)
    && s.consecutive_invoke_errors < 2

let continuation_message () : string =
  "Continue working toward the goal."

type cancel_outcome = Pause_goal | Abort_goal of string

let cancel_outcome (r : Types.cancel_reason) : cancel_outcome =
  match r with
  | Types.User_cancelled -> Pause_goal
  | Types.Guard_cancelled reason -> Abort_goal reason

type sigint_action = Request_cancel | Force_exit | Exit_now

let sigint_action ~in_invoke ~cancel_pending : sigint_action =
  if in_invoke then
    if cancel_pending then Force_exit
    else Request_cancel
  else Exit_now

let contains_ci ~haystack ~needle =
  let haystack = String.lowercase_ascii haystack in
  let needle = String.lowercase_ascii needle in
  let len_h = String.length haystack in
  let len_n = String.length needle in
  if len_n > len_h then false
  else
    let rec go i =
      if i > len_h - len_n then false
      else if String.sub haystack i len_n = needle then true
      else go (i + 1)
    in
    go 0

let is_hit_cap (s : string) : bool =
  contains_ci ~haystack:s ~needle:"max iterations exceeded"

let counts_invoke_error (e : Types.error_category) : bool =
  match e with
  | Types.Cancelled _ -> false
  | Types.External_failure s -> not (is_hit_cap s)
  | Types.Internal s -> not (is_hit_cap s)
  | Types.Timeout
  | Types.Invalid_input _
  | Types.Rate_limited
  | Types.Permission_denied _
  | Types.Embedding_unsupported -> true
