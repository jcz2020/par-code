(* par_code_context.mli — Budgeted context injection (v0.4.0).
 *
 * Provides token estimation (chars/4 heuristic) and conversation compaction
 * for long-session continuity. No external tokenizer dependency. *)

val token_estimate : Par.Types.conversation -> int
(** Estimate token count using chars/4 heuristic. Conservative (over-estimates)
    so compaction fires early rather than late. *)

val compact :
  Par.Types.conversation ->
  budget_tokens:int ->
  summary:string ->
  ?keep_recent:int ->
  unit ->
  Par.Types.conversation
(** When [token_estimate conv > budget_tokens], replace older messages with
    [summary] while keeping the last [keep_recent] (default 8) messages verbatim.
    Returns [conv] unchanged if under budget or too few messages to compact. *)

val compaction_notice :
  turn:int -> before_tokens:int -> after_tokens:int -> unit
(** Print a one-line compaction notice to stderr for observability. *)
