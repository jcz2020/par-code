(* par_code_parallel.ml — v0.10.0: bounded parallel fan-out over Eio fibers.
 *
 * Why this exists instead of Runtime.invoke_parallel: the SDK's parallel entry
 * point routes every spec through Workflow_engine.execute_step, whose
 * Agent_call branch returns only ("text", "tool_calls") and discards the
 * conversation and the usage stats. par-code needs both — a winning candidate
 * must be continued, and every token must be accounted for in /cost — so the
 * fan-out is built here, on Runtime.invoke, where the full Types.response
 * survives. *)

let default_limit = 4
let max_limit = 16

let clamp_limit n = if n < 1 then 1 else if n > max_limit then max_limit else n

let map ?(parallel_limit = default_limit) (f : 'a -> 'b) (items : 'a list) :
    ('b, exn) result list =
  (* Eio's own bounded pool: [Fiber.List.map] behaves like [List.map] (input
     order preserved) while running the calls in separate fibers. *)
  Eio.Fiber.List.map ~max_fibers:(clamp_limit parallel_limit)
    (fun x ->
       match f x with
       | value -> Ok value
       | exception (Eio.Cancel.Cancelled _ as e) -> raise e
       | exception exn -> Error exn)
    items
