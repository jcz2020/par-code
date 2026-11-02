(* par_code_payload.mli — conversation payload hygiene. *)

(** [sanitize conv] returns a conversation that strict providers accept:
    every Tool result is paired with an earlier announcing tool_call, and
    every tool_call's arguments are a JSON object (non-objects become [{}]).
    The transformation is idempotent. *)
val sanitize : Par.Types.conversation -> Par.Types.conversation
