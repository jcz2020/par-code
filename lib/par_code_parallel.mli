(** v0.10.0: bounded parallel fan-out over Eio fibers.

    par-code needs a fan-out primitive that keeps every per-call detail the SDK
    discards: {!Par.Runtime.invoke_parallel} routes each spec through
    [Workflow_engine.execute_step], whose [Agent_call] branch returns only the
    response text and tool calls — the conversation and the usage stats are
    dropped. A best-of-N winner could therefore not be continued, and no token
    could be accounted for. This module gives the same bounded-concurrency
    shape on top of {!Par.Runtime.invoke}, where the full response survives. *)

val default_limit : int
(** [4] — the same default the SDK's [invoke_parallel] uses. *)

val clamp_limit : int -> int
(** [clamp_limit n] keeps [n] inside 1..16. *)

val map : ?parallel_limit:int -> ('a -> 'b) -> 'a list -> ('b, exn) result list
(** [map ~parallel_limit f items] applies [f] to every item concurrently with at
    most [parallel_limit] calls in flight, and returns one result per item in
    input order.

    An exception raised by [f] is captured as [Error exn] for that item only:
    the rest of the batch still runs. Cancellation is re-raised, because
    swallowing [Eio.Cancel.Cancelled] would break the structured-concurrency
    contract and turn a cancelled turn into a silent partial success.

    Must be called from inside an Eio runtime (it forks fibers to run [f]);
    outside one it raises [Stdlib.Effect.Unhandled]. *)
