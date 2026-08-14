(* par_code_approvals.mli — Bash approval pattern store + workspace classifier. *)

(** {1 Pattern store} *)

(** Load persisted approval patterns from [.par/approvals.json].
    Returns [[]] if the file is missing or corrupt. *)
val load : unit -> string list

(** [add pattern] appends [pattern] to the store and writes atomically. *)
val add : string -> unit

(** [matches patterns cmd] returns [true] if any pattern matches [cmd].
    A pattern matches if it is a prefix of [cmd], or if it ends with [*]
    and the part before [*] is a prefix of [cmd]. *)
val matches : string list -> string -> bool

(** {1 Workspace classifier} *)

(** Classification of a bash command relative to a workspace. *)
type class_ =
  | In_project
  | External_path of string list
  | Sensitive of string list
  | Unknown

(** [classify ws ~argv] classifies a bash command by inspecting its argv
    tokens for path-like arguments and testing each against [Workspace.admit].

    Error mapping (documented in-module):
    - [Ok _] → path is in-project (not collected)
    - [Error (Invalid_input "absolute path not under any workspace root")] → external
    - [Error (Permission_denied _)] → sensitive
    - [Error (Invalid_input "path contains ..")] → Unknown (fail-closed)
    - [Error (Invalid_input "path contains :")] → Unknown (fail-closed)
    - [Error _] → Unknown (fail-closed)

    If no path-like tokens are found, returns [In_project].
    Delete-class commands (rm/mv/dd/shred/truncate) are forced to
    [External_path [argv0]] regardless of paths. *)
val classify : Par.Workspace.workspace -> argv:string list -> class_
