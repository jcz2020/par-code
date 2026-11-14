(* test_par_code_parallel.ml — v0.10.0: bounded fan-out executor.
   Pure in-process checks: no runtime, no LLM, no network. *)

let ok_values (out : (int, exn) result list) : int list =
  List.map
    (function
      | Ok v -> v
      | Error exn -> Alcotest.fail (Printexc.to_string exn))
    out

let test_empty () =
  let out = Par_code_parallel.map (fun x -> x) [] in
  Alcotest.(check int) "no results" 0 (List.length out)

let test_order_preserved () =
  Eio_main.run @@ fun _env ->
  let out =
    Par_code_parallel.map ~parallel_limit:3 (fun x -> x * 2) [ 1; 2; 3; 4; 5 ]
  in
  Alcotest.(check (list int)) "results follow input order" [ 2; 4; 6; 8; 10 ]
    (ok_values out)

let test_exception_isolated () =
  Eio_main.run @@ fun _env ->
  let out =
    Par_code_parallel.map
      (fun x -> if x = 3 then failwith "boom" else x)
      [ 1; 2; 3; 4 ]
  in
  match out with
  | [ Ok 1; Ok 2; Error _; Ok 4 ] -> ()
  | _ ->
    Alcotest.failf "one crashing item must not abort the batch: %s"
      (String.concat ","
         (List.map
            (function Ok v -> string_of_int v | Error _ -> "error")
            out))

let test_limit_respected () =
  Eio_main.run @@ fun _env ->
  let limit = 2 in
  let active = ref 0 and peak = ref 0 and finished = ref 0 in
  let f x =
    incr active;
    if !active > !peak then peak := !active;
    Eio.Fiber.yield ();
    decr active;
    incr finished;
    x
  in
  let out = Par_code_parallel.map ~parallel_limit:limit f [ 1; 2; 3; 4; 5; 6 ] in
  Alcotest.(check (list int)) "every item ran"
    [ 1; 2; 3; 4; 5; 6 ]
    (ok_values out);
  Alcotest.(check int) "every item finished" 6 !finished;
  Alcotest.(check bool) "never exceeds the limit" true (!peak <= limit);
  (* A pool that merely ran items one after another would satisfy the bound
     above while never overlapping; this rules that out. *)
  Alcotest.(check bool) "items actually overlap" true (!peak >= 2)

let task_json at task =
  `Assoc
    [ ("agent_type", `String at)
    ; ("task", `String task)
    ]

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
  | Error msg ->
    Alcotest.(check bool) "names the reason" true
      (String.length msg > 0
       && (let needle = "read-only" in
           let n = String.length needle and h = String.length msg in
           let rec go i = i + n <= h && (String.sub msg i n = needle || go (i + 1)) in
           go 0))

let test_batch_rejects_too_many () =
  let tasks = List.init 6 (fun i -> task_json "explore" (string_of_int i)) in
  match Par_code_delegate.parse_batch_input (batch_json tasks) with
  | Ok _ -> Alcotest.fail "six tasks must be rejected"
  | Error _ -> ()

let test_batch_rejects_malformed () =
  let json =
    batch_json
      [ `Assoc [ ("agent_type", `String "explore") ]
      ; task_json "explore" "read"
      ]
  in
  match Par_code_delegate.parse_batch_input json with
  | Ok _ -> Alcotest.fail "an entry without a task must be rejected"
  | Error _ -> ()

let () =
  Alcotest.run "par_code_parallel"
    [ ( "fan-out"
      , [ Alcotest.test_case "empty batch" `Quick test_empty
        ; Alcotest.test_case "input order" `Quick test_order_preserved
        ; Alcotest.test_case "exception isolation" `Quick test_exception_isolated
        ; Alcotest.test_case "concurrency limit" `Quick test_limit_respected
        ] )
    ; ( "delegate_batch input"
      , [ Alcotest.test_case "accepts explore" `Quick test_batch_accepts_explore
        ; Alcotest.test_case "rejects general" `Quick test_batch_rejects_general
        ; Alcotest.test_case "rejects too many" `Quick test_batch_rejects_too_many
        ; Alcotest.test_case "rejects malformed" `Quick test_batch_rejects_malformed
        ] )
    ]
