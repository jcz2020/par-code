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

let rec rm_rf path =
  try
    if Sys.is_directory path then begin
      Sys.readdir path
      |> Array.iter (fun n -> rm_rf (Filename.concat path n));
      Unix.rmdir path
    end else Sys.remove path
  with _ -> ()

let with_spill_dir f =
  let dir = Filename.temp_file "par-spill" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o700;
  let cwd = Sys.getcwd () in
  Fun.protect
    ~finally:(fun () ->
      Sys.chdir cwd;
      Par_code_payload.configure ~max_chars:32_768 ~retention_days:7.0
        ~spill_dir:None;
      rm_rf dir)
    (fun () -> Sys.chdir dir; f dir)

let test_multi_field_object_is_capped () =
  let big = String.make 60_000 'm' in
  let payload = `Assoc [ ("a", `String big); ("b", `String big) ] in
  match Par_code_payload.cap_handler_result ~tool_name:"mcp" (Types.Success payload) with
  | Types.Success j ->
    let s = Yojson.Safe.to_string j in
    Alcotest.(check bool) "multi-field object bounded" true
      (String.length s < 40_000);
    Alcotest.(check bool) "marker present" true
      (Astring.String.is_infix ~affix:"truncated" s)
  | _ -> Alcotest.fail "expected a capped object"

let test_nested_large_string_is_capped () =
  let big = String.make 100_000 'n' in
  let payload =
    `Assoc [ ("content", `List [ `Assoc [ ("type", `String "text"); ("text", `String big) ] ]) ]
  in
  match Par_code_payload.cap_handler_result ~tool_name:"mcp" (Types.Success payload) with
  | Types.Success j ->
    let s = Yojson.Safe.to_string j in
    Alcotest.(check bool) "nested text is bounded" true
      (String.length s < 40_000);
    Alcotest.(check bool) "marker present" true
      (Astring.String.is_infix ~affix:"truncated" s)
  | _ -> Alcotest.fail "expected a capped object"

let test_control_payloads_untouched () =
  let big = String.make 50_000 'a' in
  let approval =
    Types.Approval_required
      { tool_name = "mcp_write"
      ; tool_input = `Assoc [ ("content", `String big) ]
      ; prompt = "allow?"
      ; timeout = None
      ; allowed_roles = [] }
  in
  match Par_code_payload.cap_handler_result approval with
  | Types.Approval_required { tool_input = `Assoc fields; _ } ->
    let content =
      match List.assoc_opt "content" fields with Some (`String s) -> s | _ -> ""
    in
    Alcotest.(check int) "approval input must stay exact" (String.length big)
      (String.length content)
  | _ -> Alcotest.fail "approval payload must pass through"

let test_error_payload_capped () =
  let big = String.make 50_000 'e' in
  match
    Par_code_payload.cap_handler_result
      (Types.Error
         { category = Types.External_failure "x"
         ; message = big
         ; retryable = false
         ; metadata = [ ("blob", `String big) ] })
  with
  | Types.Error { message; metadata; _ } ->
    Alcotest.(check bool) "error message capped" true
      (String.length message < 5_000);
    let blob =
      match List.assoc_opt "blob" metadata with Some (`String s) -> s | _ -> ""
    in
    Alcotest.(check bool) "metadata capped" true (String.length blob < 5_000)
  | _ -> Alcotest.fail "expected an error"

let test_spill_writes_full_payload () =
  with_spill_dir (fun root ->
      Par_code_payload.configure ~max_chars:1024 ~retention_days:7.0
        ~spill_dir:(Some ".par/tool-results");
      let big = String.make 5000 'q' in
      let out =
        Par_code_payload.cap_handler_result ~tool_name:"grep"
          (Types.Success (`List [ `String big ]))
      in
      match out with
      | Types.Success (`List items) ->
        let marker =
          List.fold_left
            (fun acc j ->
              match j with
              | `String s when Astring.String.is_infix ~affix:"full output:" s -> s
              | _ -> acc)
            "" items
        in
        Alcotest.(check bool) "marker names the file" true (marker <> "");
        let start = String.length "full output: " in
        let rel =
          match Astring.String.find_sub ~sub:"full output: " marker with
          | Some i ->
            let tail = String.sub marker (i + start) (String.length marker - i - start) in
            (match String.index_opt tail ']' with
             | Some j -> String.sub tail 0 j
             | None -> tail)
          | None -> ""
        in
        Alcotest.(check bool) "spill file exists" true
          (rel <> "" && Sys.file_exists (Filename.concat root rel));
        let content =
          let ic = open_in (Filename.concat root rel) in
          let n = in_channel_length ic in
          let s = really_input_string ic n in
          close_in ic;
          s
        in
        Alcotest.(check bool) "full payload is on disk" true
          (Astring.String.is_infix ~affix:big content)
      | _ -> Alcotest.fail "expected a capped list")

let test_retention_prunes_old_files () =
  with_spill_dir (fun root ->
      let dir = Filename.concat root ".par/tool-results" in
      Unix.mkdir (Filename.concat root ".par") 0o700;
      Unix.mkdir dir 0o700;
      let old = Filename.concat dir "old.txt" in
      let oc = open_out old in
      output_string oc "old";
      close_out oc;
      let eight_days_ago = Unix.gettimeofday () -. (8. *. 86400.) in
      Unix.utimes old eight_days_ago eight_days_ago;
      Par_code_payload.configure ~max_chars:32768 ~retention_days:7.0
        ~spill_dir:(Some ".par/tool-results");
      Alcotest.(check bool) "old file removed" false (Sys.file_exists old))

let test_retention_zero_keeps_files () =
  with_spill_dir (fun root ->
      let dir = Filename.concat root ".par/tool-results" in
      Unix.mkdir (Filename.concat root ".par") 0o700;
      Unix.mkdir dir 0o700;
      let old = Filename.concat dir "keep.txt" in
      let oc = open_out old in
      output_string oc "keep";
      close_out oc;
      let eight_days_ago = Unix.gettimeofday () -. (8. *. 86400.) in
      Unix.utimes old eight_days_ago eight_days_ago;
      Par_code_payload.configure ~max_chars:32768 ~retention_days:0.
        ~spill_dir:(Some ".par/tool-results");
      Alcotest.(check bool) "retention 0 keeps the file" true
        (Sys.file_exists old))

let test_spill_disabled_falls_back () =
  with_spill_dir (fun root ->
      Par_code_payload.configure ~max_chars:1024 ~retention_days:7.0
        ~spill_dir:None;
      ignore
        (Par_code_payload.cap_handler_result ~tool_name:"grep"
           (Types.Success (`String (String.make 5000 'z'))));
      Alcotest.(check bool) "no .par dir created" false
        (Sys.file_exists (Filename.concat root ".par")))

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
        ; Alcotest.test_case "nested object capped" `Quick
            test_nested_large_string_is_capped
        ; Alcotest.test_case "multi-field object capped" `Quick
            test_multi_field_object_is_capped
        ; Alcotest.test_case "error payload capped" `Quick
            test_error_payload_capped
        ; Alcotest.test_case "control payloads untouched" `Quick
            test_control_payloads_untouched
        ] )
    ; ( "spill"
      , [ Alcotest.test_case "full payload written" `Quick
            test_spill_writes_full_payload
        ; Alcotest.test_case "retention prunes" `Quick
            test_retention_prunes_old_files
        ; Alcotest.test_case "retention zero keeps" `Quick
            test_retention_zero_keeps_files
        ; Alcotest.test_case "spill disabled" `Quick test_spill_disabled_falls_back
        ] )
    ]
