open Par.Types

let long_text = String.make 500 'x'

let user_msg () : message =
  { role = User;
    content_blocks = [ Text_block { text = long_text; cache_control = None } ];
    tool_calls = None; tool_call_id = None; name = None;
    reasoning_content = None }

let assistant_msg ?(tool_calls = []) () : message =
  { role = Assistant;
    content_blocks = [ Text_block { text = long_text; cache_control = None } ];
    tool_calls = (match tool_calls with [] -> None | l -> Some l);
    tool_call_id = None; name = None; reasoning_content = None }

let tool_msg ~tcid ~content () : message =
  { role = Tool;
    content_blocks = [ Text_block { text = content; cache_control = None } ];
    tool_calls = None; tool_call_id = Some tcid; name = None;
    reasoning_content = None }

let tc id = { id; name = "bash"; arguments = `Assoc [] }

let conv msgs = { messages = msgs; metadata = [] }

let summary = "test summary"

let assert_no_orphans msgs =
  let announced =
    List.fold_left (fun acc m ->
      match m.tool_calls with
      | Some tcs -> List.fold_left (fun s (c : tool_call) -> c.id :: s) acc tcs
      | None -> acc
    ) [] msgs
  in
  List.iter (fun m ->
    match m.role, m.tool_call_id with
    | Tool, Some id ->
      if not (List.mem id announced) then
        Alcotest.failf "orphaned tool_call_id %s (announced: [%s])"
          id (String.concat "; " announced)
    | _ -> ()
  ) msgs

let msgs_of result = result.messages

let test_straddling_pair_not_orphaned () =
  let msgs =
    [ user_msg ();                                    (* 0: first *)
      user_msg (); user_msg (); user_msg ();          (* 1-3 *)
      user_msg (); user_msg (); user_msg ();          (* 4-6 *)
      user_msg ();                                    (* 7 *)
      assistant_msg ~tool_calls:[ tc "X" ] ();        (* 8: DISCARDED *)
      tool_msg ~tcid:"X" ~content:"rX" ();            (* 9: recent[0], orphan *)
      user_msg ();                                    (* 10: recent[1] *)
      user_msg ();                                    (* 11: recent[2] *)
    ] in
  let result = Par_code_context.compact (conv msgs)
    ~budget_tokens:1000 ~summary ~keep_recent:3 () in
  let out = msgs_of result in
  assert_no_orphans out;
  let has_orphan = List.exists (fun m ->
    m.role = Tool && m.tool_call_id = Some "X"
  ) (List.filteri (fun i _ -> i > 1) out) in
  Alcotest.(check bool) "orphan tool result removed" false has_orphan

let test_clean_cut_unchanged () =
  let msgs =
    [ user_msg ();
      user_msg (); user_msg (); user_msg ();
      user_msg (); user_msg (); user_msg ();
      user_msg ();
      user_msg ();
      assistant_msg ~tool_calls:[ tc "a1" ] ();
      tool_msg ~tcid:"a1" ~content:"r1" ();
      user_msg ();
    ] in
  let result = Par_code_context.compact (conv msgs)
    ~budget_tokens:1000 ~summary ~keep_recent:4 () in
  let out = msgs_of result in
  assert_no_orphans out;
  Alcotest.(check int) "msg count" 6 (List.length out);
  Alcotest.(check bool) "tail starts at pos 9"
    ((List.nth out 2).role = User) true

let test_under_budget_noop () =
  let msgs = [ user_msg (); user_msg () ] in
  let input = conv msgs in
  let result = Par_code_context.compact input
    ~budget_tokens:999999 ~summary ~keep_recent:8 () in
  Alcotest.(check int) "unchanged count" 2 (List.length (msgs_of result));
  Alcotest.(check bool) "same object" true (result == input)

let test_parallel_batch_orphans_dropped () =
  let msgs =
    [ user_msg ();                                          (* 0: first *)
      user_msg (); user_msg (); user_msg ();                (* 1-3 *)
      user_msg (); user_msg (); user_msg ();                (* 4-6 *)
      user_msg ();                                          (* 7 *)
      assistant_msg ~tool_calls:[ tc "p1"; tc "p2" ] ();   (* 8: DISCARDED *)
      tool_msg ~tcid:"p1" ~content:"r1" ();                 (* 9: recent[0] *)
      tool_msg ~tcid:"p2" ~content:"r2" ();                 (* 10: recent[1] *)
      user_msg ();                                          (* 11: recent[2] *)
      user_msg ();                                          (* 12: recent[3] *)
    ] in
  let result = Par_code_context.compact (conv msgs)
    ~budget_tokens:1000 ~summary ~keep_recent:4 () in
  let out = msgs_of result in
  assert_no_orphans out;
  Alcotest.(check int) "msg count" 4 (List.length out);
  Alcotest.(check bool) "tail head is User"
    ((List.nth out 2).role = User) true

let test_in_tail_pairs_preserved () =
  let msgs =
    [ user_msg ();                                    (* 0: first *)
      user_msg (); user_msg (); user_msg ();          (* 1-3 *)
      user_msg (); user_msg (); user_msg ();          (* 4-6 *)
      user_msg (); user_msg ();                       (* 7-8 *)
      assistant_msg ~tool_calls:[ tc "t1" ] ();       (* 9: in tail *)
      tool_msg ~tcid:"t1" ~content:"r1" ();           (* 10: in tail, paired *)
      user_msg ();                                    (* 11: in tail *)
    ] in
  let result = Par_code_context.compact (conv msgs)
    ~budget_tokens:1000 ~summary ~keep_recent:3 () in
  let out = msgs_of result in
  assert_no_orphans out;
  Alcotest.(check int) "msg count" 5 (List.length out);
  let tail = List.filteri (fun i _ -> i > 1) out in
  Alcotest.(check bool) "tail starts with Assistant"
    ((List.hd tail).role = Assistant) true;
  Alcotest.(check bool) "tool result follows assistant"
    ((List.nth tail 1).role = Tool) true

let () =
  Alcotest.run "par_code_context"
    [ "compact_orphans", [
        Alcotest.test_case "straddling pair not orphaned"
          `Quick test_straddling_pair_not_orphaned;
        Alcotest.test_case "clean cut unchanged"
          `Quick test_clean_cut_unchanged;
        Alcotest.test_case "under budget no-op"
          `Quick test_under_budget_noop;
        Alcotest.test_case "parallel batch orphans dropped"
          `Quick test_parallel_batch_orphans_dropped;
        Alcotest.test_case "in-tail pairs preserved"
          `Quick test_in_tail_pairs_preserved;
      ] ]
