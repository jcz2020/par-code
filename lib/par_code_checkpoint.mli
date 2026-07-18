(* par_code_checkpoint.mli — Checkpoint storage and session continuity (v0.4.0). *)

val checkpoint_writer_agent_id : string
(** Agent ID for the checkpoint-writer LLM agent. *)

val checkpoint_writer_system_prompt : string
(** System prompt instructing the LLM to produce structured checkpoint JSON. *)

type checkpoint_entry = {
  task : string;
  decisions : string list;
  files_changed : string list;
  interfaces : string list;
  open_threads : string list;
  turn_number : int;
  timestamp : float;
}

val create_schema : Sqlite3.db -> unit
(** Create checkpoints table + index + FTS5 virtual table + sync triggers. Idempotent. *)

val serialize_for_checkpoint : Par.Types.conversation -> turn_number:int -> string
(** Format conversation as readable transcript for the checkpoint LLM. *)

val parse_checkpoint_response : string -> checkpoint_entry option
(** Parse JSON response from checkpoint writer. Returns None on parse failure. *)

val store_checkpoint : Par_code_memory.t ->
                       session_id:string -> project_id:string ->
                       checkpoint_entry ->
                       (unit, [> `Db_error of string]) result

val load_checkpoints : Par_code_memory.t ->
                       session_id:string ->
                       (checkpoint_entry list, [> `Db_error of string]) result

val most_recent_checkpoint : Par_code_memory.t ->
                             session_id:string ->
                             (checkpoint_entry option, [> `Db_error of string]) result

val render_session_brief : Par_code_memory.t -> session_id:string -> string
(** Render recent checkpoints into a compact markdown summary for session resume. *)

val format_checkpoints : checkpoint_entry list -> string
(** v0.4.1 Pillar C: render a list of checkpoints as multi-line text for the
    /checkpoints REPL command. Empty list → "". Each entry: index + turn + task
    headline; optional decisions/files/open sections indented underneath,
    omitted when the corresponding list is empty. *)

val run_checkpoint :
  rt:Par.Runtime.runtime ->
  Par_code_memory.t ->
  session_id:string -> project_id:string ->
  Par.Types.conversation -> turn_number:int ->
  unit
(** Synchronous checkpoint path. Called directly by the manual /checkpoint
    REPL command (user wants verification, willing to wait) and called
    internally by [maybe_checkpoint]'s async dispatcher.
    Preserves v0.4.0's [~save:false ~update_current:false] isolation.
    Non-fatal on error. *)

val maybe_checkpoint :
  rt:Par.Runtime.runtime ->
  Par_code_memory.t ->
  in_flight:bool ref ->
  session_id:string -> project_id:string ->
  Par.Types.conversation -> turn_number:int ->
  enabled:bool -> interval:int ->
  unit
(** v0.4.1 Pillar A: async PERIODIC checkpoint dispatcher. Gate:
    if enabled && turn_number mod interval == 0 && not !in_flight,
    dispatch run_checkpoint as a background Eio.Fiber.fork on
    rt.cancellation_root. The [in_flight] ref is set true when a fiber is
    dispatched and reset false on every exit path (Ok/Error/exception) via
    Fun.protect. Concurrent calls while in_flight are dropped (throttle).
    Non-fatal — errors are logged to stderr from inside the fiber. *)
