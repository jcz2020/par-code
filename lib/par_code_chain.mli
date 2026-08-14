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

val should_continue : chain_state -> bool

val continuation_message : unit -> string

type cancel_outcome = Pause_goal | Abort_goal of string

val cancel_outcome : Types.cancel_reason -> cancel_outcome

type sigint_action = Request_cancel | Force_exit | Exit_now

val sigint_action : in_invoke:bool -> cancel_pending:bool -> sigint_action

val counts_invoke_error : Types.error_category -> bool
