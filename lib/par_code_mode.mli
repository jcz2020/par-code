(* lib/par_code_mode.mli *)
type mode = Plan | Build

val current : mode ref
(** Module-level mutable ref holding the current REPL mode.
    Limitation: assumes single-runtime-per-process. If par-code ever
    supports multiple concurrent runtimes (e.g. embedded mode, parallel
    test runs), this global ref collides. Mitigation at that point:
    request PAR SDK tool_handler signature change to accept ?state,
    or infer mode from last-invoked agent_id (no global ref). *)

val switch : mode -> mode
(** [switch m] sets [current := m] and returns the previous mode. *)

val planner_agent_id : string
(** Agent id for the planner agent ("planner"). *)

val build_agent_id : string
(** Agent id for the build agent ("par"). *)

val agent_id_for : mode -> string
(** Maps a mode to the registered agent_id to pass to [Runtime.invoke]. *)

val label : mode -> string
(** Human-readable label for prompt rendering. *)

val mode_file_path : string
(** Relative path to the persisted mode file ([".par/last_session_mode.txt"]). *)

val save_current_mode_to_disk : unit -> unit
(** Persist [!current] to [mode_file_path]. Best-effort; ignores I/O errors. *)

val load_mode_from_disk : unit -> mode option
(** Read previously saved mode from [mode_file_path]. Returns [None] if file
    doesn't exist or is corrupted. *)
