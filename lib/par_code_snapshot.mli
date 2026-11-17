(** Whole-workspace snapshots and undo (v0.13.0 W2).

    Each user turn is committed into a shadow git repository at
    [<root>/.par/snapshot.git] before the agent runs. [undo] restores the
    workspace — including files a shell command deleted — and records the state
    it replaced, so an undo can be undone. *)

type entry = { sha : string; reason : string; time : int }

val git_dir : string -> string
(** [<root>/.par/snapshot.git]; never the project's own `.git`. *)

val capture : root:string -> reason:string -> (string, string) result
(** Commit the current workspace. Returns the commit sha, or [""] when nothing
    changed since the last snapshot. *)

val list_entries :
  root:string -> ?limit:int -> unit -> entry list
(** Newest first. *)

val undo : root:string -> index:int -> (string, string) result
(** [index = 0] goes back one snapshot (the state before the last turn), [1] two
    turns, and so on. Snapshots the current state first, so it is reversible. *)

val restore : root:string -> sha:string -> (unit, string) result
(** Low-level restore, exposed for tests. Removes files added after [sha] and
    leaves ignored paths (`.par/`, `_build/`, …) alone. *)
