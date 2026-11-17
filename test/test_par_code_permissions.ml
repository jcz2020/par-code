(* test_par_code_permissions.ml — v0.13.0 W1 permission rules.

   Pure decisions only: parsing, matching order and subject extraction. The
   file loading path is exercised by hand (it reads $HOME), not here. *)

let ctx ?(input = `Null) tool_name : Par.Hook.tool_call_context =
  { Par.Hook.tool_name; tool_call_id = "t1"; input; has_ui = false }

let rule ?match_ tool action =
  { Par_code_permissions.tool; match_; action }

let test_parse_actions () =
  let parse json = Par_code_permissions.rule_of_json (Yojson.Safe.from_string json) in
  (match parse {|{"tool":"bash","action":"deny"}|} with
   | Some r ->
     Alcotest.(check string) "tool" "bash" r.Par_code_permissions.tool;
     Alcotest.(check bool) "deny" true
       (r.Par_code_permissions.action = Par_code_permissions.Deny)
   | None -> Alcotest.fail "rule not parsed");
  (match parse {|{"tool":"*","action":"block"}|} with
   | Some r ->
     Alcotest.(check bool) "block is deny" true
       (r.Par_code_permissions.action = Par_code_permissions.Deny)
   | None -> Alcotest.fail "alias not parsed");
  Alcotest.(check bool) "unknown action is dropped" true
    (parse {|{"tool":"bash","action":"maybe"}|} = None)

let test_first_match_wins () =
  let rules =
    [ rule ~match_:"git push" "bash" Par_code_permissions.Deny;
      rule ~match_:"git" "bash" Par_code_permissions.Allow ]
  in
  let got =
    Par_code_permissions.decide ~rules
      (ctx ~input:(`Assoc [ ("command", `String "git push origin main") ]) "bash")
  in
  Alcotest.(check bool) "deny wins" true
    (got = Some Par_code_permissions.Deny)

let test_case_insensitive_substring () =
  let rules = [ rule ~match_:"RM -RF" "bash" Par_code_permissions.Deny ] in
  let got =
    Par_code_permissions.decide ~rules
      (ctx ~input:(`Assoc [ ("command", `String "rm -rf /tmp/x") ]) "bash")
  in
  Alcotest.(check bool) "matched" true (got = Some Par_code_permissions.Deny)

let test_subject_per_tool () =
  (* write matches on the path, not on the JSON blob *)
  let rules = [ rule ~match_:".env" "write" Par_code_permissions.Deny ] in
  let hit =
    Par_code_permissions.decide ~rules
      (ctx ~input:(`Assoc [ ("path", `String "/app/.env") ]) "write")
  in
  let miss =
    Par_code_permissions.decide ~rules
      (ctx ~input:(`Assoc [ ("path", `String "/app/main.ml") ]) "write")
  in
  Alcotest.(check bool) "path matched" true (hit = Some Par_code_permissions.Deny);
  Alcotest.(check bool) "other path free" true (miss = None)

let test_wildcard_tool () =
  let rules = [ rule "*" Par_code_permissions.Allow ] in
  let got = Par_code_permissions.decide ~rules (ctx "anything") in
  Alcotest.(check bool) "wildcard" true (got = Some Par_code_permissions.Allow)

let test_block_hook () =
  let hook =
    Par_code_permissions.hook [ rule "*" Par_code_permissions.Deny ]
  in
  match hook (ctx "bash") with
  | Par.Hook.Block { reason } ->
    Alcotest.(check bool) "names the tool" true
      (try
         ignore (Str.search_forward (Str.regexp_string "bash") reason 0);
         true
       with Not_found -> false)
  | _ -> Alcotest.fail "expected Block"

let () =
  Alcotest.run "par_code_permissions"
    [ "rules", [
        Alcotest.test_case "parse actions" `Quick test_parse_actions;
        Alcotest.test_case "first match wins" `Quick test_first_match_wins;
        Alcotest.test_case "case insensitive" `Quick test_case_insensitive_substring;
        Alcotest.test_case "subject per tool" `Quick test_subject_per_tool;
        Alcotest.test_case "wildcard tool" `Quick test_wildcard_tool;
        Alcotest.test_case "block hook" `Quick test_block_hook;
      ];
    ]
