(** v0.10.0 W2: workflows defined as files.

    A flow is [.par/flows/<id>.json] holding a PAR [workflow_def]. The SDK owns
    the engine (register / submit / status / cancel / recover); par-code owns the
    file convention and the slash command, so a flow can be reviewed, diffed and
    shared the way a skill can. *)

val dir : string
(** [".par/flows"] — where definitions live, relative to the project root. *)

val path_of : string -> string
(** [path_of id] is the file backing flow [id]. *)

val def_of_string : string -> (Par.Types.workflow_def, string) result
(** Pure: parse one definition. Errors name the JSON or the schema problem
    rather than raising. *)

val load : string -> (Par.Types.workflow_def, string) result
(** Read [.par/flows/<id>.json]. A missing file is an error with the expected
    path in it, not an empty definition. *)

val available : unit -> string list
(** Ids of the definitions on disk, sorted. An absent directory is empty. *)

val status_line : Par.Types.workflow_status -> string
(** One line for [workflow_status], including the elapsed time of a completed
    run and the failure category of a failed one. *)

val workflow_of : Par.Types.workflow_def -> Par.Types.workflow
(** Wrap a definition for [Runtime.submit_workflow_async]. *)
