(* par_code_delegate.mli — Subagent delegation tool interface. *)

val explore_agent_id : string
val general_agent_id : string
val explore_system_prompt : string
val general_system_prompt : string

val make_delegate_tool :
  rt:Par.Runtime.runtime ->
  ui:Par_code_ui.backend Lazy.t ->
  Par.Types.tool_binding
