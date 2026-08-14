type t

type action =
  | Continue
  | Nudge of string
  | Force_judge of string
  | Abort of string

type tool_event = {
  tool_name : string;
  args_json : Yojson.Safe.t;
  output : string option;
  failed : bool;
}

val create : ?bash_retries:int -> ?edit_matches:int -> ?action_streak:int -> unit -> t

val record : t -> tool_event -> action

val write_incident :
  signal:string -> reason:string -> normalized:string -> original:string -> string

val action_count : t -> int
val total_edit_matches : t -> int
val bash_fail_streak_count : t -> int
val nudged : t -> bool
val forced_judge : t -> bool
val aborted : t -> bool
