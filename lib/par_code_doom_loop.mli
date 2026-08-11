type t

val create : ?threshold:int -> unit -> t

type action =
  | Continue
  | Nudge of string
  | Force_judge of string
  | Abort of string

val record_call : t -> tool_name:string -> args:Yojson.Safe.t -> action

val record_tool_call : t -> string -> action

val streak_count : t -> int
