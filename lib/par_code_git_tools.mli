(** Read-only git tools for the planner agent.

    Exposes [git_status] and [git_log] as PAR tool bindings so the planner
    can inspect the working tree and commit history without a bash tool. *)

open Par

val parse_git_status : string -> Yojson.Safe.t
(** [parse_git_status output] parses [git status --porcelain=v1 -b] output
    into a JSON object with "branch" and "files" keys. *)

val parse_git_log : string -> Yojson.Safe.t
(** [parse_git_log output] parses [git log --format='%H|%s|%ai'] output
    into a JSON object with a "commits" key. *)

val tools : process_mgr:_ Eio.Process.mgr -> Types.tool_binding list
(** [tools ~process_mgr] returns the [git_status] and [git_log] tool bindings.
    The tools use [process_mgr] to spawn git subprocesses. *)
