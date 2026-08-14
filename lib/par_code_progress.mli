(* lib/par_code_progress.mli — No-progress detection and completion-claim heuristics. *)

val no_progress : tool_calls:int -> goal_done:bool -> text_len:int -> bool
(** [no_progress ~tool_calls ~goal_done ~text_len] is [true] when the agent
    made no progress this turn: zero tool calls, did not call [goal_done],
    and the assistant text is shorter than 200 characters. *)

val claims_completion : string -> bool
(** [claims_completion text] is [true] when [text] contains a
    completion-claim keyword (完成/done/complete/completed/finished)
    not preceded by a negation pattern. *)
