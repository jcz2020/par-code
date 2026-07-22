(* par_code_context.ml — Budgeted context injection for long-session continuity.
 *
 * Token estimation (chars/4 heuristic) and conversation compaction: when the
 * conversation exceeds the token budget, older messages are replaced with a
 * checkpoint summary while the most recent messages are kept verbatim.
 *
 * No tokenizer dependency — the heuristic is deliberately conservative
 * (compacts early). A real tokenizer can replace this in v0.5.0+. *)

open Par.Types

let ui_notice msg = Par_code_ui.render_notice (Par_code_ui.create_backend ()) msg

(* -------------------------------------------------------------------------- *)
(* Token estimation                                                          *)
(* -------------------------------------------------------------------------- *)

let block_char_length (block : content_block) : int =
  match block with
  | Text_block { text; _ } ->
    String.length text
  | Tool_use_block { id; name; arguments; _ } ->
    String.length id + String.length name
    + String.length (Yojson.Safe.to_string arguments)
  | Tool_result_block { tool_use_id; content; _ } ->
    String.length tool_use_id + String.length content
  | Image_block { data; _ } ->
    String.length data

let message_char_length (msg : message) : int =
  let blocks_chars =
    List.fold_left (fun acc blk -> acc + block_char_length blk)
      0 msg.content_blocks
  in
  let tool_chars =
    match msg.tool_calls with
    | None -> 0
    | Some calls ->
      List.fold_left (fun acc (tc : tool_call) ->
        acc + String.length tc.id + String.length tc.name
        + String.length (Yojson.Safe.to_string tc.arguments)
      ) 0 calls
  in
  blocks_chars + tool_chars

let token_estimate (conv : conversation) : int =
  let total_chars =
    List.fold_left (fun acc msg -> acc + message_char_length msg)
      0 conv.messages
  in
  (total_chars + 3) / 4

(* -------------------------------------------------------------------------- *)
(* List helpers                                                              *)
(* -------------------------------------------------------------------------- *)

let take_last lst n =
  let len = List.length lst in
  if n >= len then lst
  else
    let rec drop_n xs k =
      match xs with
      | [] -> []
      | _ when k <= 0 -> xs
      | _ :: rest -> drop_n rest (k - 1)
    in
    drop_n lst (len - n)

(* -------------------------------------------------------------------------- *)
(* Conversation compaction                                                   *)
(* -------------------------------------------------------------------------- *)

let make_summary_message (summary : string) : message =
  { role = System;
    content_blocks = [ Text_block {
      text = "[Session context summary]\n" ^ summary;
      cache_control = None } ];
    tool_calls = None;
    tool_call_id = None;
    name = None }

let compact (conv : conversation) ~budget_tokens ~summary
    ?(keep_recent = 8) () : conversation =
  let estimated = token_estimate conv in
  if estimated <= budget_tokens then
    conv
  else
    let msgs = conv.messages in
    let len = List.length msgs in
    if len <= keep_recent + 1 then
      conv
    else
      let first = List.hd msgs in
      let rest = List.tl msgs in
      let recent = take_last rest keep_recent in
      let summary_msg = make_summary_message summary in
      { conv with messages = first :: summary_msg :: recent }

let compaction_notice ~turn ~before_tokens ~after_tokens : unit =
  ui_notice (Printf.sprintf "[context compacted at turn %d — ~%dk → ~%dk tokens]"
    turn (before_tokens / 1000) (after_tokens / 1000))
