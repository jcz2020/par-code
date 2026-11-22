open Par

let blocks () : Types.content_block list =
  [ Types.Text_block { text = ""; cache_control = None } ]

let msg ?tool_calls ?tool_call_id (role : Types.message_role) : Types.message =
  { Types.role; content_blocks = blocks (); tool_calls; tool_call_id;
    name = None }

let tc id args : Types.tool_call =
  { Types.id; name = "bash"; arguments = args }

let conv msgs : Types.conversation = { Types.messages = msgs; metadata = [] }

let test_leading_orphan_dropped () =
  let out =
    Par_code_payload.sanitize
      (conv [ msg Types.System; msg ~tool_call_id:"gone" Types.Tool; msg Types.User ])
  in
  Alcotest.(check int) "orphan tool result dropped" 2 (List.length out.Types.messages)

let test_valid_pair_kept () =
  let out =
    Par_code_payload.sanitize
      (conv
         [ msg Types.System; msg Types.User
         ; msg ~tool_calls:[ tc "call_1" (`Assoc [ ("argv", `List [ `String "echo" ]) ]) ]
             Types.Assistant
         ; msg ~tool_call_id:"call_1" Types.Tool ])
  in
  Alcotest.(check int) "paired tool result kept" 4 (List.length out.Types.messages)

let test_middle_orphan_dropped () =
  let out =
    Par_code_payload.sanitize
      (conv
         [ msg Types.System
         ; msg ~tool_calls:[ tc "call_1" (`Assoc []) ] Types.Assistant
         ; msg ~tool_call_id:"call_1" Types.Tool
         ; msg ~tool_call_id:"ghost" Types.Tool
         ; msg Types.User ])
  in
  Alcotest.(check int) "middle orphan dropped" 4 (List.length out.Types.messages)

let args_of (m : Types.message) =
  match m.Types.tool_calls with
  | Some (call :: _) -> Yojson.Safe.to_string call.Types.arguments
  | _ -> "no tool call"

let test_null_arguments_become_object () =
  (* The call keeps a matching result: since v0.15.3 sanitize also drops a call
     whose result is missing, since providers reject that shape. *)
  let out =
    Par_code_payload.sanitize
      (conv
         [ msg Types.System
         ; msg ~tool_calls:[ tc "call_1" `Null ] Types.Assistant
         ; msg ~tool_call_id:"call_1" Types.Tool ])
  in
  match out.Types.messages with
  | [ _; assistant; _ ] ->
    Alcotest.(check string) "null arguments become {}" "{}" (args_of assistant)
  | _ -> Alcotest.fail "unexpected message count"

let test_non_object_arguments_become_object () =
  let out =
    Par_code_payload.sanitize
      (conv
         [ msg Types.System
         ; msg ~tool_calls:[ tc "call_1" (`String "not an object") ] Types.Assistant
         ; msg ~tool_call_id:"call_1" Types.Tool ])
  in
  match out.Types.messages with
  | [ _; assistant; _ ] ->
    Alcotest.(check string) "string arguments become {}" "{}" (args_of assistant)
  | _ -> Alcotest.fail "unexpected message count"

let test_empty_tool_call_id_result_dropped () =
  let out =
    Par_code_payload.sanitize
      (conv [ msg Types.System; msg ~tool_call_id:"" Types.Tool; msg Types.User ])
  in
  Alcotest.(check int) "result without an id dropped" 2 (List.length out.Types.messages)

let test_idempotent () =
  let input =
    conv
      [ msg Types.System
      ; msg ~tool_call_id:"ghost" Types.Tool
      ; msg ~tool_calls:[ tc "call_1" `Null ] Types.Assistant
      ; msg ~tool_call_id:"call_1" Types.Tool ]
  in
  let once = Par_code_payload.sanitize input in
  let twice = Par_code_payload.sanitize once in
  Alcotest.(check int) "second pass is a no-op" (List.length once.Types.messages)
    (List.length twice.Types.messages)


(* v0.15.3: a result must sit immediately after the assistant message that
   announced it, and a call must have a result; otherwise the provider rejects
   the whole request after an aborted turn. *)
let test_result_after_other_message_dropped () =
  let out =
    Par_code_payload.sanitize
      (conv
         [ msg Types.User
         ; msg ~tool_calls:[ tc "call_1" (`Assoc []) ] Types.Assistant
         ; msg Types.User
         ; msg ~tool_call_id:"call_1" Types.Tool ])
  in
  Alcotest.(check int) "non-adjacent result dropped" 3
    (List.length out.Types.messages)

let test_call_without_result_dropped () =
  let out =
    Par_code_payload.sanitize
      (conv
         [ msg Types.User
         ; msg ~tool_calls:[ tc "call_1" (`Assoc []) ] Types.Assistant
         ; msg Types.Assistant ])
  in
  let calls =
    List.filter_map
      (fun (m : Types.message) -> m.Types.tool_calls)
      out.Types.messages
  in
  Alcotest.(check int) "no dangling call" 0 (List.length calls)

let test_duplicate_result_dropped () =
  let out =
    Par_code_payload.sanitize
      (conv
         [ msg Types.User
         ; msg ~tool_calls:[ tc "call_1" (`Assoc []) ] Types.Assistant
         ; msg ~tool_call_id:"call_1" Types.Tool
         ; msg ~tool_call_id:"call_1" Types.Tool ])
  in
  Alcotest.(check int) "one result kept" 3 (List.length out.Types.messages)

let test_cap_large_string () =
  let big = String.make 100_000 'x' in
  match Par_code_payload.cap_handler_result (Types.Success (`String big)) with
  | Types.Success (`String s) ->
    Alcotest.(check bool) "bounded length" true
      (String.length s <= Par_code_payload.max_tool_result_chars + 80);
    Alcotest.(check bool) "says truncated" true
      (Astring.String.is_infix ~affix:"truncated" s)
  | _ -> Alcotest.fail "expected a capped string"

let test_cap_small_string_untouched () =
  let small = "hello" in
  match Par_code_payload.cap_handler_result (Types.Success (`String small)) with
  | Types.Success (`String s) -> Alcotest.(check string) "unchanged" small s
  | _ -> Alcotest.fail "expected the string back"

let test_cap_list_drops_tail () =
  let big = String.make 100_000 'y' in
  match
    Par_code_payload.cap_handler_result
      (Types.Success (`List [ `String "first"; `String big; `String "last" ]))
  with
  | Types.Success (`List items) ->
    Alcotest.(check bool) "tail bounded" true (List.length items <= 3);
    let any_truncated =
      List.exists
        (fun j ->
          Astring.String.is_infix ~affix:"truncated" (Yojson.Safe.to_string j))
        items
    in
    Alcotest.(check bool) "a truncation marker is present" true any_truncated
  | _ -> Alcotest.fail "expected a capped list"

let test_cap_strips_control_chars () =
  match
    Par_code_payload.cap_handler_result
      (Types.Success (`String "a\000b\001c\nok"))
  with
  | Types.Success (`String s) ->
    Alcotest.(check string) "NUL and C0 dropped" "abc\nok" s
  | _ -> Alcotest.fail "expected the string back"

let test_sanitize_caps_tool_message () =
  let big = String.make 100_000 'z' in
  let tool_msg =
    { Types.role = Types.Tool
    ; content_blocks = [ Types.Text_block { text = big; cache_control = None } ]
    ; tool_calls = None
    ; tool_call_id = Some "call_1"
    ; name = None }
  in
  let out =
    Par_code_payload.sanitize
      (conv
         [ msg Types.System
         ; msg ~tool_calls:[ tc "call_1" (`Assoc []) ] Types.Assistant
         ; tool_msg ])
  in
  match List.rev out.Types.messages with
  | { Types.content_blocks = [ Types.Text_block { text; _ } ]; _ } :: _ ->
    Alcotest.(check bool) "tool text capped" true
      (String.length text < String.length big)
  | _ -> Alcotest.fail "expected the tool message to survive"

let () =
  Alcotest.run "payload"
    [ ( "sanitize"
      , [ Alcotest.test_case "leading orphan" `Quick test_leading_orphan_dropped
        ; Alcotest.test_case "valid pair" `Quick test_valid_pair_kept
        ; Alcotest.test_case "middle orphan" `Quick test_middle_orphan_dropped
        ; Alcotest.test_case "null args" `Quick test_null_arguments_become_object
        ; Alcotest.test_case "non-object args" `Quick test_non_object_arguments_become_object
        ; Alcotest.test_case "empty tool id" `Quick test_empty_tool_call_id_result_dropped
        ; Alcotest.test_case "result after other message" `Quick
            test_result_after_other_message_dropped
        ; Alcotest.test_case "call without result" `Quick
            test_call_without_result_dropped
        ; Alcotest.test_case "duplicate result" `Quick
            test_duplicate_result_dropped
        ; Alcotest.test_case "idempotent" `Quick test_idempotent
        ] )
    ; ( "cap"
      , [ Alcotest.test_case "long string capped" `Quick test_cap_large_string
        ; Alcotest.test_case "short string untouched" `Quick test_cap_small_string_untouched
        ; Alcotest.test_case "list tail dropped" `Quick test_cap_list_drops_tail
        ; Alcotest.test_case "control chars stripped" `Quick test_cap_strips_control_chars
        ; Alcotest.test_case "sanitize caps tool text" `Quick
            test_sanitize_caps_tool_message
        ] )
    ]
