(* par_code_payload.mli — conversation payload hygiene. *)

(** [sanitize conv] returns a conversation that strict providers accept:
    every Tool result is paired with an earlier announcing tool_call, and
    every tool_call's arguments are a JSON object (non-objects become [{}]).
    The transformation is idempotent. *)
val sanitize : Par.Types.conversation -> Par.Types.conversation

(** [max_tool_result_chars] bounds one tool result. A grep hit can be an entire
    minified file or a binary blob; without a cap one such result reached
    649 MB in a real session and made every request take minutes. *)
val max_tool_result_chars : int

(** [configure ~max_chars ~retention_days ~spill_dir] sets the runtime limit and
    where oversized results are spilled. [spill_dir] is relative to the cwd (or
    absolute); [None] disables spilling. Called once from [Par_code_setup]. *)
val configure :
  max_chars:int -> retention_days:float -> spill_dir:string option -> unit

(** [cap_handler_result r] applies the configured limit to a tool handler's
    result, drops control characters, and leaves small results untouched. When
    the limit is exceeded and spilling is configured, the full text is written
    to a file and the returned preview names that file. Installed around every
    host-registered and MCP tool in [Par_code_setup]. *)
val cap_handler_result :
  ?tool_name:string -> Par.Types.handler_result -> Par.Types.handler_result
