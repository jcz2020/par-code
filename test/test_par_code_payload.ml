open Par

let blocks () : Types.content_block list =
  [ Types.Text_block { text = ""; cache_control = None } ]

let msg ?tool_calls ?tool_call_id (role : Types.message_role) : Types.message =
  { Types.role; content_blocks = blocks (); tool_calls; tool_call_id;
    name = None; reasoning_content = None }

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
  let out =
    Par_code_payload.sanitize
      (conv [ msg Types.System; msg ~tool_calls:[ tc "call_1" `Null ] Types.Assistant ])
  in
  match out.Types.messages with
  | [ _; assistant ] ->
    Alcotest.(check string) "null arguments become {}" "{}" (args_of assistant)
  | _ -> Alcotest.fail "unexpected message count"

let test_non_object_arguments_become_object () =
  let out =
    Par_code_payload.sanitize
      (conv
         [ msg Types.System
         ; msg ~tool_calls:[ tc "call_1" (`String "not an object") ] Types.Assistant ])
  in
  match out.Types.messages with
  | [ _; assistant ] ->
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

let () =
  Alcotest.run "payload"
    [ ( "sanitize"
      , [ Alcotest.test_case "leading orphan" `Quick test_leading_orphan_dropped
        ; Alcotest.test_case "valid pair" `Quick test_valid_pair_kept
        ; Alcotest.test_case "middle orphan" `Quick test_middle_orphan_dropped
        ; Alcotest.test_case "null args" `Quick test_null_arguments_become_object
        ; Alcotest.test_case "non-object args" `Quick test_non_object_arguments_become_object
        ; Alcotest.test_case "empty tool id" `Quick test_empty_tool_call_id_result_dropped
        ; Alcotest.test_case "idempotent" `Quick test_idempotent
        ] )
    ]
