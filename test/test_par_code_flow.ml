(* test_par_code_flow.ml — v0.10.0 W2: flow definitions on disk.
   Pure checks: parsing, missing files, directory listing. *)

let sample =
  {|{
  "id": "digest",
  "name": "Digest a file",
  "version": 1,
  "steps": ["Agent_call", {"agent_id": "explore", "prompt_template": "Read {{file}} and summarise it.", "response_schema": null}],
  "variables": [["file", "lib/par_code_flow.ml"]],
  "failure_policy": ["Continue_on_failure"],
  "parallel_limit": 4,
  "timeout": 300.0
}|}

let test_sample_parses () =
  match Par_code_flow.def_of_string sample with
  | Ok (def : Par.Types.workflow_def) ->
    Alcotest.(check string) "id" "digest" def.Par.Types.id;
    Alcotest.(check int) "parallel limit" 4 def.Par.Types.parallel_limit
  | Error msg -> Alcotest.failf "sample flow did not parse: %s" msg

let test_bad_json () =
  match Par_code_flow.def_of_string "not json" with
  | Ok _ -> Alcotest.fail "invalid JSON must be rejected"
  | Error _ -> ()

let test_missing_field () =
  match Par_code_flow.def_of_string {|{"id":"x"}|} with
  | Ok _ -> Alcotest.fail "a definition without steps must be rejected"
  | Error _ -> ()

let test_missing_file () =
  match Par_code_flow.load "definitely-not-a-flow" with
  | Ok _ -> Alcotest.fail "a missing file must be an error"
  | Error msg ->
    Alcotest.(check bool) "names the directory" true
      (let needle = ".par/flows" in
       let n = String.length needle and h = String.length msg in
       let rec go i = i + n <= h && (String.sub msg i n = needle || go (i + 1)) in
       go 0)

let test_builtin_seven_stage () =
  (* The built-in must exist without any file on disk: /flow run has to work for
     a user who installed the binary outside this repository. *)
  match Par_code_flow.builtin "compose-seven" with
  | Error e -> Alcotest.failf "builtin: %s" e
  | Ok (def : Par.Types.workflow_def) ->
    Alcotest.(check string) "id" "compose-seven" def.id;
    let steps =
      match def.steps with
      | Par.Types.Sequential steps -> steps
      | _ -> Alcotest.fail "expected Sequential"
    in
    Alcotest.(check int) "seven stages" 7 (List.length steps);
    (* plan, execute, review, tdd, debug, verify, merge: the writer stages are
       what make this a compose flow rather than a read-only one. *)
    let writers =
      List.filter
        (function
          | Par.Types.Agent_call { agent_id = "par"; _ } -> true
          | _ -> false)
        steps
    in
    Alcotest.(check int) "five writer stages" 5 (List.length writers)

let test_with_variable () =
  match Par_code_flow.builtin "compose-seven" with
  | Error e -> Alcotest.failf "builtin: %s" e
  | Ok def ->
    let def = Par_code_flow.with_variable def "spec" "add a flag" in
    let spec =
      List.assoc_opt "spec" def.Par.Types.variables
    in
    Alcotest.(check (option string)) "spec replaced"
      (Some "\"add a flag\"")
      (Option.map Yojson.Safe.to_string spec)

let () =
  Alcotest.run "par_code_flow"
    [ ( "parse"
      , [ Alcotest.test_case "sample" `Quick test_sample_parses
        ; Alcotest.test_case "bad json" `Quick test_bad_json
        ; Alcotest.test_case "missing field" `Quick test_missing_field
        ] )
    ; ( "builtin"
      , [ Alcotest.test_case "seven stages" `Quick test_builtin_seven_stage
        ; Alcotest.test_case "spec override" `Quick test_with_variable
        ] )
    ; ("disk", [ Alcotest.test_case "missing file" `Quick test_missing_file ])
    ]
