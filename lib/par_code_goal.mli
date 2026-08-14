type status = Active | Met | Aborted | Paused | Blocked of string

type goal_state = {
  objective : string;
  step_count : int;
  max_steps : int;
  status : status;
}

val current : goal_state option ref

val set_goal : objective:string -> ?max_steps:int -> unit -> unit
val clear_goal : unit -> unit
val advance_step : unit -> int
val mark_status : status -> unit
val pause_goal : unit -> unit
val resume_goal : unit -> bool
val block_goal : string -> unit
val restore_goal : goal_state -> unit

val status_label : status -> string

val goal_file_path : string
val save_current_goal_to_disk : unit -> unit
val load_goal_from_disk : unit -> goal_state option
val to_json : goal_state -> Yojson.Safe.t
val of_json : Yojson.Safe.t -> goal_state option

val done_signal : string option ref
val set_done_signal : string -> unit
val clear_done_signal : unit -> unit
