open Par_code_session

let test_format_age_seconds () =
  let now = Unix.gettimeofday () in
  Alcotest.(check string) "30 seconds" "30s ago" (format_age (now -. 30.0))

let test_format_age_minutes () =
  let now = Unix.gettimeofday () in
  Alcotest.(check string) "5 minutes" "5m ago" (format_age (now -. 300.0))

let test_format_age_hours () =
  let now = Unix.gettimeofday () in
  Alcotest.(check string) "2 hours" "2h ago" (format_age (now -. 7200.0))

let test_format_age_days () =
  let now = Unix.gettimeofday () in
  Alcotest.(check string) "3 days" "3d ago" (format_age (now -. 259200.0))

let test_resolve_id_full_uuid () =
  let full = "abcdef0123456789abcdef0123456789abcdef01" in
  Alcotest.(check (result string string)) "full UUID passes through"
    (Ok full) (resolve_id full)

let test_resolve_id_short_full_uuid () =
  let full_uuid = "12345678-1234-1234-1234-123456789abc" in
  Alcotest.(check (result string string)) "36 char UUID passes through"
    (Ok full_uuid) (resolve_id full_uuid)

let test_resolve_id_no_match () =
  Alcotest.(check (result string string)) "no match"
    (Error "No session matches prefix 'zzzzzznosession'")
    (resolve_id "zzzzzznosession")

let test_migrate_legacy_scopes () =
  let path = Filename.temp_file "test_session_migration" ".db" in
  Sys.remove path;
  let db = Sqlite3.db_open path in
  ignore (Sqlite3.exec db "CREATE TABLE conversations (session_id TEXT PRIMARY KEY, scope TEXT)");
  ignore (Sqlite3.exec db "CREATE TABLE checkpoints (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, project_id TEXT NOT NULL, turn_number INTEGER NOT NULL, checkpoint_json TEXT NOT NULL, created_at REAL NOT NULL)");
  ignore (Sqlite3.exec db
    "INSERT INTO conversations VALUES ('sess-aaa', '')");
  ignore (Sqlite3.exec db
    "INSERT INTO conversations VALUES ('sess-bbb', '')");
  ignore (Sqlite3.exec db
    "INSERT INTO conversations VALUES ('sess-ccc', 'already-set')");
  ignore (Sqlite3.exec db
    "INSERT INTO checkpoints VALUES ('ckpt-1', 'sess-aaa', '/home/user/project', 1, '{}', 1.0)");
  ignore (Sqlite3.exec db
    "INSERT INTO checkpoints VALUES ('ckpt-2', 'sess-bbb', '/home/user/project', 1, '{}', 1.0)");
  Par_code_session.migrate_legacy_scopes db;
  let get_scope sid =
    let stmt = Sqlite3.prepare db "SELECT scope FROM conversations WHERE session_id = ?" in
    ignore (Sqlite3.bind_text stmt 1 sid);
    ignore (Sqlite3.step stmt);
    let s = Sqlite3.column_text stmt 0 in
    ignore (Sqlite3.finalize stmt);
    s
  in
  Alcotest.(check string) "sess-aaa backfilled"
    "/home/user/project" (get_scope "sess-aaa");
  Alcotest.(check string) "sess-bbb backfilled"
    "/home/user/project" (get_scope "sess-bbb");
  Alcotest.(check string) "sess-ccc unchanged"
    "already-set" (get_scope "sess-ccc");
  Par_code_session.migrate_legacy_scopes db;
  Alcotest.(check string) "idempotent sess-aaa"
    "/home/user/project" (get_scope "sess-aaa");
  ignore (Sqlite3.db_close db);
  Sys.remove path

let test_migrate_no_checkpoints () =
  let path = Filename.temp_file "test_session_migration_nockpt" ".db" in
  Sys.remove path;
  let db = Sqlite3.db_open path in
  ignore (Sqlite3.exec db "CREATE TABLE conversations (session_id TEXT PRIMARY KEY, scope TEXT)");
  ignore (Sqlite3.exec db "CREATE TABLE checkpoints (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, project_id TEXT NOT NULL, turn_number INTEGER NOT NULL, checkpoint_json TEXT NOT NULL, created_at REAL NOT NULL)");
  ignore (Sqlite3.exec db
    "INSERT INTO conversations VALUES ('sess-orphan', '')");
  Par_code_session.migrate_legacy_scopes db;
  let get_scope sid =
    let stmt = Sqlite3.prepare db "SELECT scope FROM conversations WHERE session_id = ?" in
    ignore (Sqlite3.bind_text stmt 1 sid);
    ignore (Sqlite3.step stmt);
    let s = Sqlite3.column_text stmt 0 in
    ignore (Sqlite3.finalize stmt);
    s
  in
  Alcotest.(check string) "orphan left empty"
    "" (get_scope "sess-orphan");
  ignore (Sqlite3.db_close db);
  Sys.remove path

let test_migrate_multi_checkpoint_latest_wins () =
  let path = Filename.temp_file "test_session_migration_multi" ".db" in
  Sys.remove path;
  let db = Sqlite3.db_open path in
  ignore (Sqlite3.exec db "CREATE TABLE conversations (session_id TEXT PRIMARY KEY, scope TEXT)");
  ignore (Sqlite3.exec db "CREATE TABLE checkpoints (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, project_id TEXT NOT NULL, turn_number INTEGER NOT NULL, checkpoint_json TEXT NOT NULL, created_at REAL NOT NULL)");
  ignore (Sqlite3.exec db
    "INSERT INTO conversations VALUES ('sess-multi', '')");
  ignore (Sqlite3.exec db
    "INSERT INTO checkpoints VALUES ('ckpt-old', 'sess-multi', '/old/project', 1, '{}', 1000.0)");
  ignore (Sqlite3.exec db
    "INSERT INTO checkpoints VALUES ('ckpt-new', 'sess-multi', '/new/project', 5, '{}', 2000.0)");
  Par_code_session.migrate_legacy_scopes db;
  let stmt = Sqlite3.prepare db "SELECT scope FROM conversations WHERE session_id = ?" in
  ignore (Sqlite3.bind_text stmt 1 "sess-multi");
  ignore (Sqlite3.step stmt);
  let scope = Sqlite3.column_text stmt 0 in
  ignore (Sqlite3.finalize stmt);
  Alcotest.(check string) "latest checkpoint wins" "/new/project" scope;
  ignore (Sqlite3.db_close db);
  Sys.remove path

let () =
  Alcotest.run "par_session"
    [ "format_age", [
        Alcotest.test_case "seconds"  `Quick test_format_age_seconds;
        Alcotest.test_case "minutes"  `Quick test_format_age_minutes;
        Alcotest.test_case "hours"    `Quick test_format_age_hours;
        Alcotest.test_case "days"     `Quick test_format_age_days;
      ];
      "resolve_id", [
        Alcotest.test_case "full_uuid"       `Quick test_resolve_id_full_uuid;
        Alcotest.test_case "short_full_uuid" `Quick test_resolve_id_short_full_uuid;
        Alcotest.test_case "no_match"        `Quick test_resolve_id_no_match;
      ];
      "migrate_legacy_scopes", [
        Alcotest.test_case "backfill_from_checkpoints" `Quick test_migrate_legacy_scopes;
        Alcotest.test_case "no_checkpoints_leaves_empty" `Quick test_migrate_no_checkpoints;
        Alcotest.test_case "multi_checkpoint_latest_wins" `Quick test_migrate_multi_checkpoint_latest_wins;
      ];
    ]
