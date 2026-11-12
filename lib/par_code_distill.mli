(** v0.9.0 W2: /distill — propose, validate, and write a manual skill.

    The distiller agent only proposes; this module owns validation, the
    confirmation gate, atomic file writes (temp + parse + rename), backups on
    --force, and the post-write reload. *)

type proposal = {
  id : string;
  name : string;
  description : string;
  body : string;
}

val distiller_agent_id : string
val distiller_system_prompt : string

val parse_proposal : string -> (proposal, string) result
(** Lax JSON-object extraction (same tolerance as judge/selector) and field
    extraction; empty body is an error. *)

val valid_id : string -> bool
(** lowercase letters/digits/hyphens, 1..64, no leading/trailing hyphen. *)

val validate_proposal :
  existing:string list ->
  force:bool ->
  proposal ->
  (unit, string) result
(** Rejects invalid ids, reserved command ids, built-in skill ids, existing
    ids without [force], empty name/description, description > 1024, body >
    64 KB. *)

val render_skill_file : proposal -> string
(** Frontmatter + body, with name/description flattened to one line. *)

val write_skill :
  base_dir:string ->
  force:bool ->
  proposal ->
  ((string * string option), string) result
(** Write <base_dir>/<id>/skill.md atomically. The temp file is parsed by the
    SDK loader before the rename; an existing file is backed up to
    <base_dir>/../backups/skills/ when [force] is true. Returns (path, backup). *)

type args = {
  user : bool;  (** [--user] — write into the user skills directory. *)
  force : bool;  (** [--force] — overwrite an existing skill (with backup). *)
  target_id : string option;  (** [--id <id>] — pin the skill id. *)
  request : string;  (** The free-text request. *)
}

val parse_args : string -> (args, string) result
(** Split a [/distill ...] argument string into flags and request text.
    [--id <id>] and [--id=<id>] both pin the target skill id; a missing
    value is an error. *)

val pin_target_id : string option -> proposal -> proposal
(** The pinned [--id] wins over the id the distiller proposed, so
    [/distill --id foo --force] rewrites [foo] instead of hoping the model
    picks it. *)

val run :
  rt:Par.Runtime.runtime ->
  ui:Par_code_ui.backend ->
  mem_db:Par_code_memory.t option ->
  conv:Par.Types.conversation option ->
  ?cancellation_token:Par.Types.cancellation_token ->
  ?on_invoke:(bool -> unit) ->
  args:string ->
  unit ->
  unit
(** REPL entry: parse [--user]/[--force]/[--id], call the distiller agent,
    show the proposal, ask for confirmation, write, and reload the skill
    registry. When a [cancellation_token] is given, Ctrl+C cancels the
    distiller call instead of killing the REPL. [on_invoke] is called with
    [true] right before and [false] right after the model call, so the caller
    can scope the token to the call and leave the confirmation prompt with
    its normal signal handling. *)
