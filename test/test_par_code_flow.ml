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

let () =
  Alcotest.run "par_code_flow"
    [ ( "parse"
      , [ Alcotest.test_case "sample" `Quick test_sample_parses
        ; Alcotest.test_case "bad json" `Quick test_bad_json
        ; Alcotest.test_case "missing field" `Quick test_missing_field
        ] )
    ; ("disk", [ Alcotest.test_case "missing file" `Quick test_missing_file ])
    ]
