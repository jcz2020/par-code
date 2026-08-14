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

(* [v0.7.3 W4] IO companion moved verbatim from par_code_repl.ml: consumes
   the doom flags and runs the goal evaluation ladder after a turn
   (v0.7.2 semantics — runs on both Ok and Error invoke results). Mutates
   Par_code_goal state and the passed refs; renders via the ui backend. *)
val run_goal_evaluation :
  rt:Runtime.runtime ->
  ui:Par_code_ui.backend ->
  conv:Types.conversation option ref ->
  goal_feedback:string option ref ->
  no_progress_streak:int ref ->
  goal_verify_cmd:string option ->
  doom_abort:bool ref ->
  doom_abort_msg:string option ref ->
  doom_force_judge:bool ref ->
  tool_count_before:int ->
  unit ->
  unit
