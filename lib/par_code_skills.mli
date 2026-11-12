(** User/project skill discovery for v0.9.0 self-improvement.

    Skills live at [<dir>/<id>/skill.md] (project [./.par/skills/] first, then
    [~/.par/skills/]). Only manual skills are registered in W0/W1; they become
    custom slash commands through the REPL. The SDK does not read
    [body_path] at runtime, so [read_body] is the par-code-side bridge. *)

type source = Project | User

type entry = {
  descriptor : Par.Types.skill_descriptor;
  source : source;
}

val reserved_commands : string list
(** Built-in REPL command ids; skills with these ids are rejected. *)

val builtin_skill_ids : string list
(** Built-in SDK skill ids ([Builtin_skills.builtin_skills]); a file-backed
    skill with one of these ids is rejected instead of silently shadowing the
    SDK skill. *)

val source_string : source -> string
(** "project" or "user", for [/skills] output. *)

val scan :
  ?user_dir:string ->
  ?project_dir:string ->
  unit ->
  (entry list * (string * string) list)
(** Pure discovery: valid entries + (directory/id, parse error) pairs. Project
    skills shadow user skills with the same id. *)

val discover_and_register :
  rt:Par.Runtime.runtime ->
  ?user_dir:string ->
  ?project_dir:string ->
  ?auto_activate:bool ->
  unit ->
  (entry list * (string * string) list)
(** Scan + register. Returns (registered, rejected/warnings). Rejected reasons
    include reserved/builtin id conflicts, parse errors, non-manual triggers
    when [auto_activate] is false, and registration errors. On reload an
    already-registered id keeps the fresh descriptor (body and listing are
    live) and is reported only when its frontmatter actually drifted from the
    runtime binding, which PAR 0.12-beta cannot replace without a restart. *)

val reload :
  rt:Par.Runtime.runtime ->
  ?user_dir:string ->
  ?project_dir:string ->
  ?auto_activate:bool ->
  unit ->
  (entry list * (string * string) list)
(** Clear the in-memory registry, force the SDK loader cache to reload, scan
    and register again. *)

val list_custom : unit -> entry list
(** Registered custom skills, sorted by id. *)

val find_manual : string -> entry option
(** A registered manual skill by id, for `/<id>` dispatch. *)

val read_body : entry -> (string, string) result
(** Read the markdown body after the frontmatter. Empty or >64 KB is an error. *)

val frontmatter_diff :
  Par.Types.skill_descriptor -> Par.Types.skill_descriptor -> string list
(** Frontmatter fields (name/description/trigger/tool_filter/system_prompt_override)
    that differ between an already-registered descriptor and a freshly parsed
    one. Empty list = reload changed nothing the runtime binding holds. *)

val clear : unit -> unit
(** Test hook: reset the in-memory registry. *)
