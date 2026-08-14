(* par_code_progress.ml — No-progress detection and completion-claim heuristics.
 *
 * Pure predicates extracted for testability. Used by the REPL goal block (W5)
 * to detect "lying flat" (no progress) and "drift" (false completion claims). *)

(** [no_progress ~tool_calls ~goal_done ~text_len] is [true] when the agent
    made no progress this turn: zero tool calls, did not call [goal_done],
    and the assistant text is shorter than 200 characters. *)
let no_progress ~tool_calls ~goal_done ~text_len =
  tool_calls = 0 && not goal_done && text_len < 200

(** [claims_completion text] is [true] when [text] contains a
    completion-claim keyword (完成/done/complete/completed/finished)
    not preceded by a negation pattern within the surrounding context.

    Negation handling (simple substring exclusion):
    - Chinese: 没有完成 / 未完成 / 没完成 → negated
    - English: "not done" / "not complete" / "incomplete" / "unfinished" → negated *)
let claims_completion (text : string) : bool =
  let contains_sub (haystack : string) (needle : string) : bool =
    let lh = String.length haystack and ln = String.length needle in
    let rec go i =
      if i + ln > lh then false
      else if String.sub haystack i ln = needle then true
      else go (i + 1)
    in
    ln = 0 || go 0
  in
  let lower = String.lowercase_ascii text in
  (* English — exclude "not X" / "inX" / "unX" prefixes *)
  (contains_sub lower "done"
   && not (contains_sub lower "not done"))
  || (contains_sub lower "complete"
      && not (contains_sub lower "not complete")
      && not (contains_sub lower "incomplete"))
  || (contains_sub lower "completed"
      && not (contains_sub lower "not completed")
      && not (contains_sub lower "incomplete"))
  || (contains_sub lower "finished"
      && not (contains_sub lower "not finished")
      && not (contains_sub lower "unfinished"))
  (* Chinese — exclude negation: 没有完成 / 未完成 / 还没完成 *)
  || (contains_sub text "完成"
      && not (contains_sub text "没有完成")
      && not (contains_sub text "未完成")
      && not (contains_sub text "还没完成"))
