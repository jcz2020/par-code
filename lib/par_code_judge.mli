type verdict = {
  goal_met : bool;
  reasoning : string;
}

val judge_agent_id : string
val judge_system_prompt : string

val parse_verdict : string -> verdict
val build_judge_message : goal:string -> verify_result:string -> conv_summary:string -> string

val evaluate_goal :
  rt:Par.Runtime.runtime ->
  goal:string ->
  ?conv:Par.Types.conversation ->
  verify_result:string ->
  unit ->
  (verdict, string) result
