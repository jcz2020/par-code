open Par

val plan_enter_handler : Yojson.Safe.t -> Types.cancellation_token -> Types.handler_result
val plan_exit_handler : Yojson.Safe.t -> Types.cancellation_token -> Types.handler_result
val plan_enter_tool : Types.tool_binding
val plan_exit_tool : Types.tool_binding
val persist_plan_file : Types.conversation -> string option

type plan_entry = { filename : string; size : int; timestamp : float option }

val parse_plan_timestamp : string -> float option
val list_plans : limit:int -> (plan_entry list, [> `Plan_error of string]) result
val show_plan : string -> (string, [> `Plan_error of string]) result
val prune_plans : older_than_days:int -> (int, [> `Plan_error of string]) result
