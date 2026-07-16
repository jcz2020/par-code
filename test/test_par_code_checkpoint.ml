(* test_par_code_checkpoint.ml — Tests for checkpoint DB logic, JSON parsing,
   session brief rendering, and FTS5 sync. *)

let failf fmt = Printf.ksprintf (fun s -> Alcotest.fail s) fmt

(* ── Helpers ─────────────────────────────────────────────────────────── *)

let string_contains s sub =
  let len_s = String.length s in
  let len_sub = String.length sub in
  let rec search i =
    if i + len_sub > len_s then false
    else if String.sub s i len_sub = sub then true
    else search (i + 1)
  in
  len_sub = 0 || search 0

let with_temp_db f =
  let tmpdir = Filename.temp_file "par_test_" "" in
  Sys.remove tmpdir;
  Unix.mkdir tmpdir 0o755;
  let old_home = (try Sys.getenv "HOME" with Not_found -> "") in
  Unix.putenv "HOME" tmpdir;
  Fun.protect
    ~finally:(fun () ->
      Unix.putenv "HOME" old_home;
      let rec rm_rf p =
        if Sys.file_exists p then
          if Sys.is_directory p then begin
            Array.iter (fun e -> rm_rf (Filename.concat p e)) (Sys.readdir p);
            Unix.rmdir p
          end else Sys.remove p
      in
      rm_rf tmpdir)
    (fun () ->
      match Par_code_memory.open_db () with
      | Ok db ->
        let raw = Par_code_memory.raw_db db in
        Par_code_checkpoint.create_schema raw;
        let result = f ~tmpdir db in
        Par_code_memory.close db;
        result
      | Error (`Db_error msg) ->
        failf "open_db failed: %s" msg)

let make_entry ?(task="test task") ?(decisions=[]) ?(files_changed=[])
    ?(interfaces=[]) ?(open_threads=[]) ?(turn_number=1) ?(timestamp=1000.0) () =
  Par_code_checkpoint.{ task; decisions; files_changed; interfaces;
                         open_threads; turn_number; timestamp }

let make_conv ~user_text ~assistant_text =
  Par.Types.
    { messages = [
        { role = User;
          content_blocks = [ Text_block { text = user_text; cache_control = None } ];
          tool_calls = None; tool_call_id = None; name = None };
        { role = Assistant;
          content_blocks = [ Text_block { text = assistant_text; cache_control = None } ];
          tool_calls = None; tool_call_id = None; name = None };
      ];
      metadata = [] }

(* ── Schema tests ─────────────────────────────────────────────────────── *)

let schema_idempotent () =
  with_temp_db (fun ~tmpdir:_ db ->
    let raw = Par_code_memory.raw_db db in
    Par_code_checkpoint.create_schema raw;
    (* Second call should not raise *)
    Par_code_checkpoint.create_schema raw)

let schema_creates_table () =
  with_temp_db (fun ~tmpdir:_ db ->
    let raw = Par_code_memory.raw_db db in
    (* Verify the checkpoints table exists *)
    let stmt = Sqlite3.prepare raw
      "SELECT name FROM sqlite_master WHERE type='table' AND name='checkpoints'" in
    let found = match Sqlite3.step stmt with
      | Sqlite3.Rc.ROW -> Sqlite3.column_text stmt 0 = "checkpoints"
      | _ -> false in
    ignore (Sqlite3.finalize stmt);
    Alcotest.(check bool) "checkpoints table exists" true found)

(* ── Storage CRUD ─────────────────────────────────────────────────────── *)

let store_and_load () =
  with_temp_db (fun ~tmpdir:_ db ->
    let entry = make_entry ~task:"implement feature X"
        ~decisions:["use async"; "OCaml 5"] ~turn_number:5 () in
    (match Par_code_checkpoint.store_checkpoint db
             ~session_id:"s1" ~project_id:"p1" entry with
     | Ok () -> ()
     | Error (`Db_error msg) -> failf "store: %s" msg);
    match Par_code_checkpoint.load_checkpoints db ~session_id:"s1" with
    | Ok [loaded] ->
      Alcotest.(check string) "task" "implement feature X" loaded.Par_code_checkpoint.task;
      Alcotest.(check (list string)) "decisions"
        ["use async"; "OCaml 5"] loaded.Par_code_checkpoint.decisions;
      Alcotest.(check int) "turn_number" 5 loaded.Par_code_checkpoint.turn_number
    | Ok [] -> Alcotest.fail "load returned empty"
    | Ok _ -> Alcotest.fail "load returned too many"
    | Error (`Db_error msg) -> failf "load: %s" msg)

let store_multiple () =
  with_temp_db (fun ~tmpdir:_ db ->
    List.iter (fun n ->
      let entry = make_entry ~task:(Printf.sprintf "turn %d" n) ~turn_number:n () in
      match Par_code_checkpoint.store_checkpoint db
              ~session_id:"s1" ~project_id:"p1" entry with
      | Ok () -> ()
      | Error (`Db_error msg) -> failf "store turn %d: %s" n msg)
      [10; 20; 30];
    match Par_code_checkpoint.load_checkpoints db ~session_id:"s1" with
    | Ok entries ->
      Alcotest.(check int) "count" 3 (List.length entries);
      let turns = List.map (fun e -> e.Par_code_checkpoint.turn_number) entries in
      Alcotest.(check (list int)) "order" [10; 20; 30] turns
    | Error (`Db_error msg) -> failf "load: %s" msg)

let most_recent () =
  with_temp_db (fun ~tmpdir:_ db ->
    List.iter (fun n ->
      let entry = make_entry ~task:(Printf.sprintf "turn %d" n) ~turn_number:n () in
      match Par_code_checkpoint.store_checkpoint db
              ~session_id:"s1" ~project_id:"p1" entry with
      | Ok () -> ()
      | Error (`Db_error msg) -> failf "store turn %d: %s" n msg)
      [10; 20; 30];
    match Par_code_checkpoint.most_recent_checkpoint db ~session_id:"s1" with
    | Ok (Some entry) ->
      Alcotest.(check int) "turn_number" 30 entry.Par_code_checkpoint.turn_number;
      Alcotest.(check string) "task" "turn 30" entry.Par_code_checkpoint.task
    | Ok None -> Alcotest.fail "most_recent returned None"
    | Error (`Db_error msg) -> failf "most_recent: %s" msg)

let project_scoping () =
  with_temp_db (fun ~tmpdir:_ db ->
    let e_a = make_entry ~task:"project A work" ~turn_number:1 () in
    let e_b = make_entry ~task:"project B work" ~turn_number:2 () in
    (match Par_code_checkpoint.store_checkpoint db
             ~session_id:"s1" ~project_id:"proj-A" e_a with
     | Ok () -> ()
     | Error (`Db_error msg) -> failf "store A: %s" msg);
    (match Par_code_checkpoint.store_checkpoint db
             ~session_id:"s1" ~project_id:"proj-B" e_b with
     | Ok () -> ()
     | Error (`Db_error msg) -> failf "store B: %s" msg);
    (* load_checkpoints filters by session_id, not project_id.
       Verify both entries are returned for session s1. *)
    match Par_code_checkpoint.load_checkpoints db ~session_id:"s1" with
    | Ok entries ->
      Alcotest.(check int) "session s1 count" 2 (List.length entries);
      let tasks = List.map (fun e -> e.Par_code_checkpoint.task) entries in
      Alcotest.(check bool) "has project A" true (List.mem "project A work" tasks);
      Alcotest.(check bool) "has project B" true (List.mem "project B work" tasks)
    | Error (`Db_error msg) -> failf "load: %s" msg)

let session_isolation () =
  with_temp_db (fun ~tmpdir:_ db ->
    let e1 = make_entry ~task:"session 1 work" ~turn_number:1 () in
    let e2 = make_entry ~task:"session 2 work" ~turn_number:2 () in
    (match Par_code_checkpoint.store_checkpoint db
             ~session_id:"s1" ~project_id:"p1" e1 with
     | Ok () -> ()
     | Error (`Db_error msg) -> failf "store s1: %s" msg);
    (match Par_code_checkpoint.store_checkpoint db
             ~session_id:"s2" ~project_id:"p1" e2 with
     | Ok () -> ()
     | Error (`Db_error msg) -> failf "store s2: %s" msg);
    match Par_code_checkpoint.load_checkpoints db ~session_id:"s1" with
    | Ok [loaded] ->
      Alcotest.(check string) "s1 task" "session 1 work" loaded.Par_code_checkpoint.task
    | Ok _ -> Alcotest.fail "s1 returned wrong count"
    | Error (`Db_error msg) -> failf "load: %s" msg)

(* ── JSON parsing ─────────────────────────────────────────────────────── *)

let parse_valid_json () =
  let json = {|{"task":"fix auth bug","decisions":["use mutex"],"files_changed":["auth.ml"],"interfaces":["val lock : unit -> unit"],"open_threads":["add tests"]}|} in
  match Par_code_checkpoint.parse_checkpoint_response json with
  | Some entry ->
    Alcotest.(check string) "task" "fix auth bug" entry.Par_code_checkpoint.task;
    Alcotest.(check (list string)) "decisions" ["use mutex"] entry.Par_code_checkpoint.decisions;
    Alcotest.(check (list string)) "files_changed" ["auth.ml"] entry.Par_code_checkpoint.files_changed;
    Alcotest.(check (list string)) "interfaces" ["val lock : unit -> unit"] entry.Par_code_checkpoint.interfaces;
    Alcotest.(check (list string)) "open_threads" ["add tests"] entry.Par_code_checkpoint.open_threads
  | None -> Alcotest.fail "parse returned None"

let parse_empty_lists () =
  let json = {|{"task":"","decisions":[],"files_changed":[],"interfaces":[],"open_threads":[]} |} in
  match Par_code_checkpoint.parse_checkpoint_response json with
  | Some entry ->
    Alcotest.(check string) "task" "" entry.Par_code_checkpoint.task;
    Alcotest.(check (list string)) "decisions" [] entry.Par_code_checkpoint.decisions;
    Alcotest.(check (list string)) "files" [] entry.Par_code_checkpoint.files_changed
  | None -> Alcotest.fail "parse returned None"

let parse_garbage () =
  match Par_code_checkpoint.parse_checkpoint_response "not json at all" with
  | None -> ()  (* expected *)
  | Some _ -> Alcotest.fail "parse returned Some for garbage"

let parse_missing_fields () =
  let json = {|{"task":"hello"}|} in
  match Par_code_checkpoint.parse_checkpoint_response json with
  | Some entry ->
    Alcotest.(check string) "task" "hello" entry.Par_code_checkpoint.task;
    Alcotest.(check (list string)) "decisions" [] entry.Par_code_checkpoint.decisions;
    Alcotest.(check (list string)) "files" [] entry.Par_code_checkpoint.files_changed;
    Alcotest.(check (list string)) "interfaces" [] entry.Par_code_checkpoint.interfaces;
    Alcotest.(check (list string)) "open_threads" [] entry.Par_code_checkpoint.open_threads
  | None -> Alcotest.fail "parse returned None"

(* ── Session brief rendering ──────────────────────────────────────────── *)

let brief_empty () =
  with_temp_db (fun ~tmpdir:_ db ->
    let brief = Par_code_checkpoint.render_session_brief db ~session_id:"empty" in
    Alcotest.(check string) "empty brief" "" brief)

let brief_with_data () =
  with_temp_db (fun ~tmpdir:_ db ->
    let entry = make_entry ~task:"refactor parser module"
        ~decisions:["split into phases"] ~turn_number:5 () in
    (match Par_code_checkpoint.store_checkpoint db
             ~session_id:"s1" ~project_id:"p1" entry with
     | Ok () -> ()
     | Error (`Db_error msg) -> failf "store: %s" msg);
    let brief = Par_code_checkpoint.render_session_brief db ~session_id:"s1" in
    Alcotest.(check bool) "contains task" true
      (string_contains brief "refactor parser module"))

(* ── Serialization ────────────────────────────────────────────────────── *)

let serialize_basic () =
  let conv = make_conv ~user_text:"fix the login bug"
      ~assistant_text:"I'll check auth.ml for issues" in
  let result = Par_code_checkpoint.serialize_for_checkpoint conv ~turn_number:3 in
  Alcotest.(check bool) "non-empty" true (result <> "");
  Alcotest.(check bool) "contains turn number" true
    (string_contains result "turn 3")

let serialize_too_few_messages () =
  let conv = Par.Types.
    { messages = [
        { role = User;
          content_blocks = [ Text_block { text = "hello"; cache_control = None } ];
          tool_calls = None; tool_call_id = None; name = None };
      ];
      metadata = [] } in
  let result = Par_code_checkpoint.serialize_for_checkpoint conv ~turn_number:1 in
  Alcotest.(check string) "single message returns empty" "" result

(* ── Context (token_estimate + compact) tests ────────────────────────── *)

let make_large_conv n =
  let mk_msg role text =
    Par.Types.{
      role; content_blocks = [Text_block { text; cache_control = None }];
      tool_calls = None; tool_call_id = None; name = None
    }
  in
  let msgs = List.init n (fun i ->
    if i mod 2 = 0 then mk_msg Par.Types.User (String.make 1000 'a')
    else mk_msg Par.Types.Assistant (String.make 1000 'b')
  ) in
  Par.Types.{ messages = msgs; metadata = [] }

let token_estimate_basic () =
  let conv = make_conv
    ~user_text:(String.make 4000 'x')
    ~assistant_text:(String.make 4000 'y')
  in
  let est = Par_code_context.token_estimate conv in
  Alcotest.(check bool) "8000 chars ≈ 2000 tokens (±10%)"
    true (est >= 1800 && est <= 2200)

let token_estimate_empty () =
  let conv = Par.Types.{ messages = []; metadata = [] } in
  let est = Par_code_context.token_estimate conv in
  Alcotest.(check int) "empty = 0 tokens" 0 est

let compact_under_budget () =
  let conv = make_conv ~user_text:"hello" ~assistant_text:"hi" in
  let result = Par_code_context.compact conv ~budget_tokens:10000 ~summary:"S" () in
  Alcotest.(check int) "unchanged when under budget" 2 (List.length result.Par.Types.messages)

let compact_over_budget () =
  let conv = make_large_conv 20 in
  let est_before = Par_code_context.token_estimate conv in
  let result = Par_code_context.compact conv ~budget_tokens:100 ~summary:"COMPACTED" () in
  let msg_count = List.length result.Par.Types.messages in
  let est_after = Par_code_context.token_estimate result in
  Alcotest.(check bool) "messages reduced (≤10)" true (msg_count <= 10);
  Alcotest.(check bool) "tokens reduced" true (est_after < est_before);
  let first = List.hd result.Par.Types.messages in
  Alcotest.(check string) "first message preserved"
    (String.make 1000 'a')
    (match first.Par.Types.content_blocks with
     | Par.Types.Text_block { text; _ } :: _ -> text
     | _ -> "");
  let second = List.nth result.Par.Types.messages 1 in
  Alcotest.(check bool) "summary message present"
    true
    (match second.Par.Types.role, second.Par.Types.content_blocks with
     | Par.Types.System, [Par.Types.Text_block { text; _ }] ->
       string_contains text "COMPACTED"
     | _ -> false)

let compact_too_few () =
  let conv = make_large_conv 5 in
  let result = Par_code_context.compact conv ~budget_tokens:1 ~summary:"S" () in
  Alcotest.(check int) "too few messages → unchanged" 5
    (List.length result.Par.Types.messages)

(* ── Test runner ──────────────────────────────────────────────────────── *)

let () =
  Alcotest.run "par_checkpoint"
    [ "schema", [
        Alcotest.test_case "idempotent"      `Quick schema_idempotent;
        Alcotest.test_case "creates_table"   `Quick schema_creates_table;
      ];
      "crud", [
        Alcotest.test_case "store_and_load"  `Quick store_and_load;
        Alcotest.test_case "store_multiple"  `Quick store_multiple;
        Alcotest.test_case "most_recent"     `Quick most_recent;
        Alcotest.test_case "project_scoping" `Quick project_scoping;
        Alcotest.test_case "session_isolation" `Quick session_isolation;
      ];
      "json", [
        Alcotest.test_case "valid_json"      `Quick parse_valid_json;
        Alcotest.test_case "empty_lists"     `Quick parse_empty_lists;
        Alcotest.test_case "garbage"         `Quick parse_garbage;
        Alcotest.test_case "missing_fields"  `Quick parse_missing_fields;
      ];
      "brief", [
        Alcotest.test_case "empty"           `Quick brief_empty;
        Alcotest.test_case "with_data"       `Quick brief_with_data;
      ];
      "serialize", [
        Alcotest.test_case "basic"           `Quick serialize_basic;
        Alcotest.test_case "too_few_messages" `Quick serialize_too_few_messages;
      ];
      "context", [
        Alcotest.test_case "token_estimate_basic" `Quick token_estimate_basic;
        Alcotest.test_case "token_estimate_empty" `Quick token_estimate_empty;
        Alcotest.test_case "compact_under_budget" `Quick compact_under_budget;
        Alcotest.test_case "compact_over_budget" `Quick compact_over_budget;
        Alcotest.test_case "compact_too_few" `Quick compact_too_few;
      ];
    ]
