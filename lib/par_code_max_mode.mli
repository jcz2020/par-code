(* par_code_max_mode.mli — Best-of-N candidate fan-out. *)

val candidate_agent_id : string
val candidate_system_prompt : string
val strategy_seeds : string list
val seed_for : int -> string
val candidate_prompt : seed:string -> message:string -> string

type candidate = {
  index : int;
  text : string;
  conversation : Par.Types.conversation;
  usage : Par.Types.usage_stats;
  events : Par.Types.event list;
}

type outcome = {
  candidates : candidate list;
  failures : (int * string) list;
}

val empty_usage : Par.Types.usage_stats
val add_usage : Par.Types.usage_stats -> Par.Types.usage_stats -> Par.Types.usage_stats
val merge_usage : Par.Types.usage_stats list -> Par.Types.usage_stats
val candidate_usages : outcome -> Par.Types.usage_stats list
val clamp_candidates : int -> int

val restore_user_message :
  original:string -> Par.Types.conversation -> Par.Types.conversation
(** [restore_user_message ~original c] rewrites the last user message of [c] to
    [original]. A candidate runs on a wrapper prompt (strategy angle + request),
    and adopting its transcript otherwise persists that wrapper as the user's
    own words in the session, checkpoints and memory extraction. *)

val run_candidates :
  rt:Par.Runtime.runtime ->
  agent_id:string ->
  message:string ->
  ?conversation:Par.Types.conversation ->
  ?system_prompt_appendix:string ->
  n:int ->
  cancellation_token:Par.Types.cancellation_token ->
  ?on_candidate_done:(int -> bool -> unit) ->
  unit ->
  outcome
(** [run_candidates] runs [clamp_candidates n] read-only candidates in parallel
    fibers, each on its own copy of [conversation], sharing [cancellation_token].
    A failing candidate is recorded in [failures] and never aborts the others.
    Completed candidates come back in index order. *)
