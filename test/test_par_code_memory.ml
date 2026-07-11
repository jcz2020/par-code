let failf fmt = Printf.ksprintf (fun s -> Alcotest.fail s) fmt

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
        let result = f ~tmpdir db in
        Par_code_memory.close db;
        result
      | Error (`Db_error msg) ->
        failf "open_db failed: %s" msg)

let with_history_db f =
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
      let par_dir = Filename.concat tmpdir ".par" in
      Unix.mkdir par_dir 0o755;
      let db_path = Filename.concat par_dir "par.db" in
      let raw = Sqlite3.db_open db_path in
      ignore (Sqlite3.exec raw
        "CREATE TABLE IF NOT EXISTS conversations (\
           session_id TEXT, messages_json TEXT, metadata_json TEXT, \
           updated_at REAL, turn_count INTEGER)");
      ignore (Sqlite3.db_close raw);
      match Par_code_memory.open_db () with
      | Ok db ->
        let result = f ~tmpdir db in
        Par_code_memory.close db;
        result
      | Error (`Db_error msg) ->
        failf "open_db failed: %s" msg)

let open_raw_db tmpdir =
  Sqlite3.db_open
    (Filename.concat (Filename.concat tmpdir ".par") "par.db")

let insert_raw_conversation raw ~session_id ~messages_json ~updated_at ~turn_count =
  let stmt = Sqlite3.prepare raw
    "INSERT INTO conversations (session_id, messages_json, metadata_json, updated_at, turn_count) \
     VALUES (?, ?, '{}', ?, ?)" in
  ignore (Sqlite3.bind_text stmt 1 session_id);
  ignore (Sqlite3.bind_text stmt 2 messages_json);
  ignore (Sqlite3.bind_double stmt 3 updated_at);
  ignore (Sqlite3.bind_int stmt 4 turn_count);
  ignore (Sqlite3.step stmt);
  ignore (Sqlite3.finalize stmt)

let add_mem db ~project_id ~kind ~content ~summary =
  match Par_code_memory.add db ~project_id ~kind ~content ~summary
          ~citations:[] ~source:`Manual with
  | Ok id -> id
  | Error (`Db_error msg) -> failf "add failed: %s" msg

let schema_idempotent () =
  with_temp_db (fun ~tmpdir:_ db ->
    (* Sqlite_memory.create is idempotent — open_db already called it.
       Verify the schema is usable by doing a round-trip add+list. *)
    let _id = add_mem db ~project_id:"test" ~kind:Convention
                ~content:"schema test" ~summary:"schema" in
    match Par_code_memory.list db ~project_id:"test" () with
    | Ok [_] -> ()
    | Ok _  -> Alcotest.fail "list returned wrong count"
    | Error (`Db_error msg) -> failf "list failed: %s" msg)

let fts5_trigger_insert () =
  with_temp_db (fun ~tmpdir:_ db ->
    let project_id = "test-project" in
    let _id = add_mem db ~project_id ~kind:Convention
                ~content:"OCaml uses 2-space indentation"
                ~summary:"indent convention" in
    match Par_code_memory.recall db ~project_id ~query:"indentation" () with
    | Ok [m] ->
      Alcotest.(check string) "summary" "indent convention" m.Par_code_memory.summary
    | Ok [] -> Alcotest.fail "recall returned empty after insert"
    | Ok _  -> Alcotest.fail "recall returned too many results"
    | Error (`Db_error msg) -> failf "recall failed: %s" msg)

let fts5_trigger_delete () =
  with_temp_db (fun ~tmpdir:_ db ->
    let project_id = "test-project" in
    let id = add_mem db ~project_id ~kind:Insight
               ~content:"auth module has a race condition"
               ~summary:"auth race" in
    (match Par_code_memory.forget db ~id with
     | Ok () -> ()
     | Error (`Db_error msg) -> failf "forget failed: %s" msg);
    match Par_code_memory.recall db ~project_id ~query:"auth" () with
    | Ok [] -> ()
    | Ok _  -> Alcotest.fail "recall found deleted memory"
    | Error (`Db_error msg) -> failf "recall after delete failed: %s" msg)

let recall_respects_limit () =
  with_temp_db (fun ~tmpdir:_ db ->
    let project_id = "test-project" in
    for i = 1 to 10 do
      ignore (add_mem db ~project_id ~kind:Insight
                ~content:(Printf.sprintf "memory entry number %d about testing" i)
                ~summary:(Printf.sprintf "entry %d" i))
    done;
    match Par_code_memory.recall db ~project_id ~query:"testing" ~limit:3 () with
    | Ok ms -> Alcotest.(check int) "recall limit" 3 (List.length ms)
    | Error (`Db_error msg) -> failf "recall failed: %s" msg)

let project_isolation () =
  with_temp_db (fun ~tmpdir:_ db ->
    let _ida = add_mem db ~project_id:"project-alpha"
                 ~kind:Convention ~content:"alpha uses tabs" ~summary:"alpha tabs" in
    let _idb = add_mem db ~project_id:"project-beta"
                 ~kind:Convention ~content:"beta uses spaces" ~summary:"beta spaces" in
    (match Par_code_memory.list db ~project_id:"project-alpha" () with
     | Ok [m] ->
       Alcotest.(check string) "alpha summary"
         "alpha tabs" m.Par_code_memory.summary
     | Ok _  -> Alcotest.fail "alpha list wrong count"
     | Error (`Db_error msg) -> failf "list alpha: %s" msg);
    match Par_code_memory.list db ~project_id:"project-beta" () with
    | Ok [m] ->
      Alcotest.(check string) "beta summary"
        "beta spaces" m.Par_code_memory.summary
    | Ok _  -> Alcotest.fail "beta list wrong count"
    | Error (`Db_error msg) -> failf "list beta: %s" msg)

let bump_usage_increments () =
  with_temp_db (fun ~tmpdir:_ db ->
    let project_id = "test-project" in
    let id = add_mem db ~project_id ~kind:Preference
               ~content:"prefer dark mode" ~summary:"dark mode" in
    Par_code_memory.bump_usage db ~id;
    Par_code_memory.bump_usage db ~id;
    match Par_code_memory.list db ~project_id () with
    | Ok [m] ->
      Alcotest.(check int) "usage_count = 2" 2 m.Par_code_memory.usage_count
    | Ok _  -> Alcotest.fail "list returned wrong count"
    | Error (`Db_error msg) -> failf "list failed: %s" msg)

let prune_stale_semantics () =
  with_temp_db (fun ~tmpdir db ->
    let project_id = "test-project" in
    let id_a = add_mem db ~project_id ~kind:Gotcha
                 ~content:"old unused memory" ~summary:"old unused" in
    let id_b = add_mem db ~project_id ~kind:Gotcha
                 ~content:"old used memory" ~summary:"old used" in
    Par_code_memory.bump_usage db ~id:id_b;
    let _id_c = add_mem db ~project_id ~kind:Gotcha
                  ~content:"recent unused memory" ~summary:"recent unused" in
    let old_ts = Unix.gettimeofday () -. (10.0 *. 86400.0) in
    let db_path =
      Filename.concat (Filename.concat tmpdir ".par") "par.db" in
    let raw = Sqlite3.db_open db_path in
    List.iter (fun id ->
      let stmt = Sqlite3.prepare raw
        "UPDATE memory_entries SET updated_at = ? WHERE ext_id = ?" in
      ignore (Sqlite3.bind_double stmt 1 old_ts);
      ignore (Sqlite3.bind_text stmt 2 id);
      ignore (Sqlite3.step stmt);
      ignore (Sqlite3.finalize stmt))
      [id_a; id_b];
    ignore (Sqlite3.db_close raw);
    (match Par_code_memory.prune_stale db ~project_id ~older_than_days:1.0 with
     | Ok n -> Alcotest.(check int) "pruned count" 1 n
     | Error (`Db_error msg) -> failf "prune_stale: %s" msg);
    match Par_code_memory.list db ~project_id ~limit:100 () with
    | Ok ms ->
      let ids = List.map (fun m -> m.Par_code_memory.id) ms in
      Alcotest.(check bool) "id_a pruned" false (List.mem id_a ids);
      Alcotest.(check bool) "id_b survives" true (List.mem id_b ids)
    | Error (`Db_error msg) -> failf "list after prune: %s" msg)

let render_index_line_cap () =
  with_temp_db (fun ~tmpdir:_ db ->
    let project_id = "test-project" in
    for i = 1 to 250 do
      ignore (add_mem db ~project_id ~kind:Insight
                ~content:(Printf.sprintf "content %d" i)
                ~summary:(Printf.sprintf "summary %d" i))
    done;
    let output = Par_code_memory.render_index db ~project_id in
    let lines = String.split_on_char '\n' output in
    let non_empty = List.filter (fun s -> s <> "") lines in
    Alcotest.(check bool) "line cap ≤ 201" true (List.length non_empty <= 201))

let conversations_fts_insert_and_search () =
  with_history_db (fun ~tmpdir db ->
    let raw = open_raw_db tmpdir in
    insert_raw_conversation raw
      ~session_id:"test-1"
      ~messages_json:{|{"role":"user","content":"authentication bug in auth module"}|}
      ~updated_at:1000.0
      ~turn_count:1;
    ignore (Sqlite3.db_close raw);
    match Par_code_memory.search_history db ~query:"authentication" () with
    | Ok [h] ->
      Alcotest.(check string) "session_id" "test-1" h.Par_code_memory.session_id
    | Ok [] -> Alcotest.fail "search_history returned empty"
    | Ok _  -> Alcotest.fail "search_history returned too many results"
    | Error (`Db_error msg) -> failf "search_history: %s" msg)

let search_history_snippet_highlighting () =
  with_history_db (fun ~tmpdir db ->
    let raw = open_raw_db tmpdir in
    insert_raw_conversation raw
      ~session_id:"test-snippet"
      ~messages_json:{|{"role":"user","content":"The auth module has a race condition"}|}
      ~updated_at:2000.0
      ~turn_count:1;
    ignore (Sqlite3.db_close raw);
    match Par_code_memory.search_history db ~query:"auth" () with
    | Ok [h] ->
      Alcotest.(check bool) "snippet contains <<auth" true
        (string_contains h.Par_code_memory.snippet "<<auth")
    | Ok [] -> Alcotest.fail "search_history returned empty"
    | Ok _  -> Alcotest.fail "search_history returned too many results"
    | Error (`Db_error msg) -> failf "search_history: %s" msg)

let search_history_respects_limit () =
  with_history_db (fun ~tmpdir db ->
    let raw = open_raw_db tmpdir in
    for i = 1 to 10 do
      insert_raw_conversation raw
        ~session_id:(Printf.sprintf "test-limit-%d" i)
        ~messages_json:(Printf.sprintf
                          {|{"role":"user","content":"test conversation number %d"}|} i)
        ~updated_at:(float_of_int (1000 + i))
        ~turn_count:i
    done;
    ignore (Sqlite3.db_close raw);
    match Par_code_memory.search_history db ~query:"test" ~limit:3 () with
    | Ok hits ->
      Alcotest.(check int) "search_history limit" 3 (List.length hits)
    | Error (`Db_error msg) -> failf "search_history: %s" msg)

let conversations_fts_backfill () =
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
      let par_dir = Filename.concat tmpdir ".par" in
      Unix.mkdir par_dir 0o755;
      let db_path = Filename.concat par_dir "par.db" in
      let raw = Sqlite3.db_open db_path in
      ignore (Sqlite3.exec raw
        "CREATE TABLE IF NOT EXISTS conversations (\
           session_id TEXT, messages_json TEXT, metadata_json TEXT, \
           updated_at REAL, turn_count INTEGER)");
      for i = 1 to 3 do
        insert_raw_conversation raw
          ~session_id:(Printf.sprintf "backfill-%d" i)
          ~messages_json:(Printf.sprintf
                            {|{"role":"user","content":"test backfill conversation %d"}|} i)
          ~updated_at:(float_of_int (1000 + i))
          ~turn_count:1
      done;
      ignore (Sqlite3.db_close raw);
      match Par_code_memory.open_db () with
      | Ok db ->
        (match Par_code_memory.search_history db ~query:"backfill" () with
         | Ok hits ->
           Alcotest.(check int) "backfill count" 3 (List.length hits);
           Par_code_memory.close db
         | Error (`Db_error msg) ->
           Par_code_memory.close db;
           failf "search_history: %s" msg)
      | Error (`Db_error msg) ->
        failf "open_db failed: %s" msg)

let search_history_empty_db () =
  with_history_db (fun ~tmpdir:_ db ->
    match Par_code_memory.search_history db ~query:"anything" () with
    | Ok [] -> ()
    | Ok _  -> Alcotest.fail "search_history returned results on empty db"
    | Error (`Db_error msg) -> failf "search_history: %s" msg)

let () =
  Alcotest.run "par_memory"
    [ "schema", [ Alcotest.test_case "idempotent" `Quick schema_idempotent ];
      "fts5", [
        Alcotest.test_case "trigger_insert" `Quick fts5_trigger_insert;
        Alcotest.test_case "trigger_delete" `Quick fts5_trigger_delete;
        Alcotest.test_case "recall_limit"   `Quick recall_respects_limit;
      ];
      "isolation", [ Alcotest.test_case "project" `Quick project_isolation ];
      "usage",     [ Alcotest.test_case "bump"    `Quick bump_usage_increments ];
      "prune",     [ Alcotest.test_case "stale_semantics" `Quick prune_stale_semantics ];
      "render",    [ Alcotest.test_case "line_cap" `Quick render_index_line_cap ];
      "history", [
        Alcotest.test_case "fts_insert_and_search"  `Quick conversations_fts_insert_and_search;
        Alcotest.test_case "snippet_highlighting"    `Quick search_history_snippet_highlighting;
        Alcotest.test_case "respects_limit"          `Quick search_history_respects_limit;
        Alcotest.test_case "fts_backfill"            `Quick conversations_fts_backfill;
        Alcotest.test_case "empty_db"                `Quick search_history_empty_db;
      ];
    ]
