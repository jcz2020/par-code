(* par_code_selector.mli — max-mode candidate selection. *)

val selector_agent_id : string
val selector_system_prompt : string

type kind =
  | Answer
  | Execute

type choice = {
  index : int;
  kind : kind;
  plan : string;
  reasoning : string;
  total_tokens : int option;
}

val default_choice : choice
val max_candidate_chars : int
val truncate : ?limit:int -> string -> string
val build_message : user_message:string -> string list -> string
val parse_choice : n:int -> string -> choice option

val choose :
  rt:Par.Runtime.runtime ->
  user_message:string ->
  string list ->
  (choice, string) result
(** [choose ~rt ~user_message candidates] asks the selector agent to pick one of
    [candidates]. The index in the result is 0-based. [Error] means the selector
    call or its parse failed; callers fall back to [default_choice]. *)
