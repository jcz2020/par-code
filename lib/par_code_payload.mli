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

(** [cap_handler_result r] applies [max_tool_result_chars] to a tool handler's
    result, drops control characters, and leaves small results untouched.
    Installed around every builtin tool in [Par_code_setup]. *)
val cap_handler_result :
  Par.Types.handler_result -> Par.Types.handler_result
