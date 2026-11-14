(* par_code_delegate.mli — Subagent delegation tool interface. *)

val explore_agent_id : string
val general_agent_id : string
val explore_system_prompt : string
val general_system_prompt : string

val make_delegate_tool :
  rt:Par.Runtime.runtime ->
  ui:Par_code_ui.backend Lazy.t ->
  Par.Types.tool_binding

val batch_max_tasks : int
(** Upper bound on tasks accepted by one [delegate_batch] call. *)

val parse_batch_input : Yojson.Safe.t -> ((string * string) list, string) result
(** Pure validation of a [delegate_batch] argument object: 1..{!batch_max_tasks}
    [{agent_type, task}] entries, each with a string agent type and a non-empty
    task. A [general] task is rejected — two writers in one workspace collide —
    and so is anything else but [explore]. Extracted from the tool handler so it
    can be tested without a Runtime. *)

val make_delegate_batch_tool :
  rt:Par.Runtime.runtime ->
  ui:Par_code_ui.backend Lazy.t ->
  Par.Types.tool_binding
(** v0.10.0: run up to {!batch_max_tasks} read-only [explore] subagents
    concurrently through {!Par_code_parallel.map} and return every result.

    Read-only by construction, matching the standing rule that parallel agents
    never race each other on the workspace: a [general] task is rejected with a
    pointer to [delegate]. Write parallelism waits for per-child worktrees.

    Each task keeps the full [Types.llm_response] (text, usage, conversation);
    a task that fails or crashes is reported in place and does not abort the
    others. Results and UI lines are emitted in input order, so concurrent
    children never interleave on one terminal line. *)
