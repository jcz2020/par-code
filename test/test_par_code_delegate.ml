(* test_par_code_delegate.ml — v0.10.0: delegate_batch input validation and the
   success/failure interleave. Pure in-process checks: no runtime, no LLM. *)

let task_json at task =
  `Assoc [ ("agent_type", `String at); ("task", `String task) ]

let batch_json tasks : Yojson.Safe.t = `Assoc [ ("tasks", `List tasks) ]

let test_batch_accepts_explore () =
  let json = batch_json [ task_json "explore" "find the config loader" ] in
  match Par_code_delegate.parse_batch_input json with
  | Ok [ ("explore", "find the config loader") ] -> ()
  | Ok _ -> Alcotest.fail "unexpected parsed task list"
  | Error msg -> Alcotest.failf "expected a valid batch, got: %s" msg

let test_batch_rejects_general () =
  let json =
    batch_json
      [ task_json "explore" "read"; task_json "general" "rewrite the module" ]
  in
  match Par_code_delegate.parse_batch_input json with
  | Ok _ -> Alcotest.fail "a 'general' task must be rejected"
  | Error msg -> Alcotest.(check bool) "names the reason" true (String.length msg > 0)

let test_batch_rejects_too_many () =
  let tasks = List.init 6 (fun i -> task_json "explore" (string_of_int i)) in
  match Par_code_delegate.parse_batch_input (batch_json tasks) with
  | Ok _ -> Alcotest.fail "six tasks must be rejected"
  | Error _ -> ()

let test_batch_rejects_malformed () =
  let json =
    batch_json
      [ `Assoc [ ("agent_type", `String "explore") ]; task_json "explore" "read" ]
  in
  match Par_code_delegate.parse_batch_input json with
  | Ok _ -> Alcotest.fail "an entry without a task must be rejected"
  | Error _ -> ()

(* -- merge_batch_results ------------------------------------------------- *)

let json_of s = `String s

let test_merge_all_success () =
  let merged =
    Par_code_delegate.merge_batch_results ~inputs:[ "a"; "b" ]
      ~successes:[ ("a", json_of "ra"); ("b", json_of "rb") ]
      ~failures:[]
  in
  match merged with
  | [ `Ok (`String "ra"); `Ok (`String "rb") ] -> ()
  | _ -> Alcotest.fail "successes must come back in input order"

let test_merge_interleaves_failures () =
  let merged =
    Par_code_delegate.merge_batch_results ~inputs:[ "a"; "b"; "c" ]
      ~successes:[ ("a", json_of "ra"); ("c", json_of "rc") ]
      ~failures:[ ("b", Par.Types.Timeout) ]
  in
  match merged with
  | [ `Ok (`String "ra"); `Failed Par.Types.Timeout; `Ok (`String "rc") ] -> ()
  | _ -> Alcotest.fail "a failure in the middle must keep its slot"

let test_merge_duplicate_inputs () =
  let merged =
    Par_code_delegate.merge_batch_results ~inputs:[ "same"; "same" ]
      ~successes:[ ("same", json_of "first"); ("same", json_of "second") ]
      ~failures:[]
  in
  match merged with
  | [ `Ok (`String "first"); `Ok (`String "second") ] -> ()
  | _ -> Alcotest.fail "duplicate task text must consume results in order"

let test_merge_missing_result () =
  let merged =
    Par_code_delegate.merge_batch_results ~inputs:[ "a"; "b" ]
      ~successes:[ ("a", json_of "ra") ] ~failures:[]
  in
  match merged with
  | [ `Ok _; `Failed (Par.Types.Internal _) ] -> ()
  | _ -> Alcotest.fail "a missing result must surface as an internal error"

let () =
  Alcotest.run "par_code_delegate"
    [ ( "delegate_batch input"
      , [ Alcotest.test_case "accepts explore" `Quick test_batch_accepts_explore
        ; Alcotest.test_case "rejects general" `Quick test_batch_rejects_general
        ; Alcotest.test_case "rejects too many" `Quick test_batch_rejects_too_many
        ; Alcotest.test_case "rejects malformed" `Quick test_batch_rejects_malformed
        ] )
    ; ( "merge results"
      , [ Alcotest.test_case "all success" `Quick test_merge_all_success
        ; Alcotest.test_case "interleaves failures" `Quick
            test_merge_interleaves_failures
        ; Alcotest.test_case "duplicate inputs" `Quick test_merge_duplicate_inputs
        ; Alcotest.test_case "missing result" `Quick test_merge_missing_result
        ] )
    ]
