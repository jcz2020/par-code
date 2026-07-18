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

val run_checkpoint :
  rt:Par.Runtime.runtime ->
  Par_code_memory.t ->
  session_id:string -> project_id:string ->
  Par.Types.conversation -> turn_number:int ->
  unit
(** Serialize conv, invoke_generate on rt with ~save:false ~update_current:false, parse, store. Non-fatal on error. *)

val maybe_checkpoint :
  rt:Par.Runtime.runtime ->
  Par_code_memory.t ->
  session_id:string -> project_id:string ->
  Par.Types.conversation -> turn_number:int ->
  enabled:bool -> interval:int ->
  unit
(** Gate: if enabled && turn_number mod interval == 0, run checkpoint synchronously.
    Non-fatal — errors are logged to stderr. *)
