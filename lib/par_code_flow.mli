(** v0.10.0 W2: workflows defined as files.

    A flow is [.par/flows/<id>.json] holding a PAR [workflow_def]. The SDK owns
    the engine (register / submit / status / cancel / recover); par-code owns the
    file convention and the slash command, so a flow can be reviewed, diffed and
    shared the way a skill can. *)

val dir : string
(** [".par/flows"] — where project definitions live, relative to the root. *)

val example_dir : string
(** ["examples/flows"] — definitions shipped with the repo. *)

val path_of : string -> string
(** [path_of id] is the project-local file backing flow [id]. *)

val def_of_string : string -> (Par.Types.workflow_def, string) result
(** Pure: parse one definition. Errors name the JSON or the schema problem
    rather than raising. *)

val load : string -> (Par.Types.workflow_def, string) result
(** Read [.par/flows/<id>.json], falling back to the shipped
    [examples/flows/<id>.json] so an example runs out of the box. A missing
    definition is an error naming both directories, not an empty one. *)

val available : unit -> string list
(** Ids on disk — project first, then the shipped examples — sorted and
    de-duplicated. An absent directory contributes nothing. *)

val status_line : Par.Types.workflow_status -> string
(** One line for [workflow_status], including the elapsed time of a completed
    run and the failure category of a failed one. *)

val workflow_of : Par.Types.workflow_def -> Par.Types.workflow
(** Wrap a definition for [Runtime.submit_workflow_async]. *)
