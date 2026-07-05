type t = { db : Sqlite3.db }

type kind = Preference | Convention | Insight | Gotcha | Task_map

type memory = {
  id : int;
  project_id : string;
  kind : kind;
  content : string;
  summary : string;
  citations : string list;
  created_at : float;
  updated_at : float;
  last_used_at : float option;
  usage_count : int;
  source : [`Manual | `Agent | `Import];
}

let ( let* ) = Result.bind

let kind_to_string = function
  | Preference -> "preference"
  | Convention -> "convention"
  | Insight    -> "insight"
  | Gotcha     -> "gotcha"
  | Task_map   -> "task_map"

let kind_of_string = function
  | "preference" -> Some Preference
  | "convention" -> Some Convention
  | "insight"    -> Some Insight
  | "gotcha"     -> Some Gotcha
  | "task_map"   -> Some Task_map
  | _            -> None

let source_to_string = function
  | `Manual -> "manual"
  | `Agent  -> "agent"
  | `Import -> "import"

let source_of_string = function
  | "manual" -> Some `Manual
  | "agent"  -> Some `Agent
  | "import" -> Some `Import
  | _        -> None

let wrap_sqlite_error f =
  try Ok (f ())
  with
  | Sqlite3.Error msg -> Error (`Db_error msg)
  | Sqlite3.SqliteError msg -> Error (`Db_error msg)

let exec_sql db sql =
  match Sqlite3.exec db sql with
  | Sqlite3.Rc.OK -> Ok ()
  | rc -> Error (`Db_error (Sqlite3.Rc.to_string rc))

let ensure_schema t =
  wrap_sqlite_error (fun () ->
    let _ = exec_sql t.db "PRAGMA journal_mode=WAL;" in
    let stmts = [
      "CREATE TABLE IF NOT EXISTS memory_entries (
          id            INTEGER PRIMARY KEY AUTOINCREMENT,
          project_id    TEXT NOT NULL,
          kind          TEXT NOT NULL CHECK(kind IN
                          ('preference','convention','insight','gotcha','task_map')),
          content       TEXT NOT NULL,
          summary       TEXT NOT NULL,
          citations     TEXT NOT NULL DEFAULT '[]',
          created_at    REAL NOT NULL,
          updated_at    REAL NOT NULL,
          last_used_at  REAL,
          usage_count   INTEGER NOT NULL DEFAULT 0,
          source        TEXT NOT NULL DEFAULT 'manual'
      )";
      "CREATE INDEX IF NOT EXISTS idx_memory_project ON memory_entries(project_id, updated_at DESC)";
      "CREATE VIRTUAL TABLE IF NOT EXISTS memory_entries_fts USING fts5(
          content, summary, kind,
          content='memory_entries', content_rowid='id',
          tokenize='porter unicode61'
      )";
      {|CREATE TRIGGER IF NOT EXISTS memory_ai AFTER INSERT ON memory_entries BEGIN
          INSERT INTO memory_entries_fts(rowid, content, summary, kind)
          VALUES (new.id, new.content, new.summary, new.kind);
      END|};
      {|CREATE TRIGGER IF NOT EXISTS memory_ad AFTER DELETE ON memory_entries BEGIN
          INSERT INTO memory_entries_fts(memory_entries_fts, rowid, content, summary, kind)
          VALUES ('delete', old.id, old.content, old.summary, old.kind);
      END|};
      {|CREATE TRIGGER IF NOT EXISTS memory_au AFTER UPDATE ON memory_entries BEGIN
          INSERT INTO memory_entries_fts(memory_entries_fts, rowid, content, summary, kind)
          VALUES ('delete', old.id, old.content, old.summary, old.kind);
          INSERT INTO memory_entries_fts(rowid, content, summary, kind)
          VALUES (new.id, new.content, new.summary, new.kind);
      END|};
    ] in
    List.iter (fun s -> ignore (Sqlite3.exec t.db s)) stmts;
    ())

let open_db () =
  let path = Par_code_config.db_path () in
  wrap_sqlite_error (fun () ->
    let db = Sqlite3.db_open path in
    let t = { db } in
    (match ensure_schema t with
     | Ok () -> ()
     | Error (`Db_error msg) ->
       Printf.eprintf "Warning: memory schema creation: %s\n%!" msg);
    t)

let close t =
  ignore (Sqlite3.db_close t.db)

let resolve_project_id () =
  let ic = Unix.open_process_in "git rev-parse --show-toplevel 2>/dev/null" in
  let line = try input_line ic with End_of_file -> "" in
  let _ = Unix.close_process_in ic in
  let root = String.trim line in
  if root <> "" then root
  else Sys.getcwd ()

let citations_to_json (citations : string list) : string =
  let items = List.map (fun s -> `String s) citations in
  Yojson.Safe.to_string (`List items)

let citations_of_json (s : string) : string list =
  match Yojson.Safe.from_string s with
  | `List items ->
    List.filter_map (function `String s -> Some s | _ -> None) items
  | _ -> []

let row_to_memory (stmt : Sqlite3.stmt) : memory =
  let id = Sqlite3.column_int stmt 0 in
  let project_id = Sqlite3.column_text stmt 1 in
  let kind_str = Sqlite3.column_text stmt 2 in
  let content = Sqlite3.column_text stmt 3 in
  let summary = Sqlite3.column_text stmt 4 in
  let citations_json = Sqlite3.column_text stmt 5 in
  let created_at = Sqlite3.column_double stmt 6 in
  let updated_at = Sqlite3.column_double stmt 7 in
  let last_used_at =
    if Sqlite3.column_is_null stmt 8 then None
    else Some (Sqlite3.column_double stmt 8)
  in
  let usage_count = Sqlite3.column_int stmt 9 in
  let source_str = Sqlite3.column_text stmt 10 in
  { id; project_id;
    kind = (match kind_of_string kind_str with Some k -> k | None -> Gotcha);
    content; summary;
    citations = citations_of_json citations_json;
    created_at; updated_at; last_used_at; usage_count;
    source = (match source_of_string source_str with Some s -> s | None -> `Manual);
  }

let collect_rows t sql bind_fn =
  wrap_sqlite_error (fun () ->
    let stmt = Sqlite3.prepare t.db sql in
    let _ = bind_fn stmt in
    let results = ref [] in
    let rec loop () =
      match Sqlite3.step stmt with
      | Sqlite3.Rc.ROW ->
        results := row_to_memory stmt :: !results;
        loop ()
      | Sqlite3.Rc.DONE -> ()
      | rc -> raise (Sqlite3.Error (Sqlite3.Rc.to_string rc))
    in
    loop ();
    let _ = Sqlite3.finalize stmt in
    List.rev !results)

let add t ~project_id ~kind ~content ~summary ~citations ~source =
  let now = Unix.gettimeofday () in
  let citations_json = citations_to_json citations in
  wrap_sqlite_error (fun () ->
    let stmt = Sqlite3.prepare t.db
      "INSERT INTO memory_entries \
       (project_id, kind, content, summary, citations, created_at, updated_at, source) \
       VALUES (?, ?, ?, ?, ?, ?, ?, ?)" in
    let _ = Sqlite3.bind_text stmt 1 project_id in
    let _ = Sqlite3.bind_text stmt 2 (kind_to_string kind) in
    let _ = Sqlite3.bind_text stmt 3 content in
    let _ = Sqlite3.bind_text stmt 4 summary in
    let _ = Sqlite3.bind_text stmt 5 citations_json in
    let _ = Sqlite3.bind_double stmt 6 now in
    let _ = Sqlite3.bind_double stmt 7 now in
    let _ = Sqlite3.bind_text stmt 8 (source_to_string source) in
    let rc = Sqlite3.step stmt in
    let _ = Sqlite3.finalize stmt in
    match rc with
    | Sqlite3.Rc.DONE ->
      Int64.to_int (Sqlite3.last_insert_rowid t.db)
    | _ -> raise (Sqlite3.Error (Sqlite3.Rc.to_string rc)))

let forget t ~id =
  wrap_sqlite_error (fun () ->
    let stmt = Sqlite3.prepare t.db
      "DELETE FROM memory_entries WHERE id = ?" in
    let _ = Sqlite3.bind_int stmt 1 id in
    let rc = Sqlite3.step stmt in
    let _ = Sqlite3.finalize stmt in
    match rc with
    | Sqlite3.Rc.DONE -> ()
    | _ -> raise (Sqlite3.Error (Sqlite3.Rc.to_string rc)))

let list t ~project_id ?(limit = 50) () =
  let sql =
    "SELECT id, project_id, kind, content, summary, citations, \
     created_at, updated_at, last_used_at, usage_count, source \
     FROM memory_entries WHERE project_id = ? \
     ORDER BY updated_at DESC LIMIT ?" in
  collect_rows t sql (fun stmt ->
    let _ = Sqlite3.bind_text stmt 1 project_id in
    let _ = Sqlite3.bind_int stmt 2 limit in
    ())

let sanitize_fts_query (query : string) : string =
  let buf = Buffer.create (String.length query + 2) in
  Buffer.add_char buf '"';
  String.iter (fun c ->
    if c = '"' then Buffer.add_string buf "\"\""
    else Buffer.add_char buf c
  ) query;
  Buffer.add_char buf '"';
  Buffer.contents buf

let bump_usage t ~id =
  try
    let stmt = Sqlite3.prepare t.db
      "UPDATE memory_entries SET usage_count = usage_count + 1, \
       last_used_at = ? WHERE id = ?" in
    let _ = Sqlite3.bind_double stmt 1 (Unix.gettimeofday ()) in
    let _ = Sqlite3.bind_int stmt 2 id in
    let _ = Sqlite3.step stmt in
    let _ = Sqlite3.finalize stmt in
    ()
  with _ -> ()

let recall t ~project_id ~query ?(limit = 5) () =
  let fts_query = sanitize_fts_query query in
  let sql =
    "SELECT me.id, me.project_id, me.kind, me.content, me.summary, \
     me.citations, me.created_at, me.updated_at, me.last_used_at, \
     me.usage_count, me.source \
     FROM memory_entries_fts \
     JOIN memory_entries me ON me.id = memory_entries_fts.rowid \
     WHERE memory_entries_fts MATCH ? AND me.project_id = ? \
     ORDER BY rank LIMIT ?" in
  let* results = collect_rows t sql (fun stmt ->
    let _ = Sqlite3.bind_text stmt 1 fts_query in
    let _ = Sqlite3.bind_text stmt 2 project_id in
    let _ = Sqlite3.bind_int stmt 3 limit in
    ())
  in
  List.iter (fun (m : memory) -> bump_usage t ~id:m.id) results;
  Ok results

let render_index t ~project_id =
  let recent = match list t ~project_id ~limit:50 () with
    | Ok l -> l | Error _ -> [] in
  let frequent_sql =
    "SELECT id, project_id, kind, content, summary, citations, \
     created_at, updated_at, last_used_at, usage_count, source \
     FROM memory_entries WHERE project_id = ? \
     ORDER BY usage_count DESC LIMIT ?" in
  let frequent = match collect_rows t frequent_sql (fun stmt ->
    let _ = Sqlite3.bind_text stmt 1 project_id in
    let _ = Sqlite3.bind_int stmt 2 20 in
    ()) with
    | Ok l -> l | Error _ -> [] in
  let seen = Hashtbl.create 64 in
  let merged = ref [] in
  List.iter (fun (m : memory) ->
    if not (Hashtbl.mem seen m.id) then begin
      Hashtbl.add seen m.id ();
      merged := m :: !merged
    end
  ) (recent @ frequent);
  let all = List.rev !merged in
  if all = [] then ""
  else
    let groups = Hashtbl.create 5 in
    List.iter (fun (m : memory) ->
      let key = kind_to_string m.kind in
      let existing = try Hashtbl.find groups key with Not_found -> [] in
      Hashtbl.replace groups key (m :: existing)
    ) all;
    let kind_order = ["convention"; "preference"; "insight"; "gotcha"; "task_map"] in
    let kind_headers = [
      ("convention", "Conventions"); ("preference", "Preferences");
      ("insight", "Insights"); ("gotcha", "Gotchas"); ("task_map", "Task Maps");
    ] in
    let buf = Buffer.create 2048 in
    let line_count = ref 0 in
    List.iter (fun kind_key ->
      match Hashtbl.find_opt groups kind_key with
      | None -> ()
      | Some mems ->
        let header = List.assoc kind_key kind_headers in
        if !line_count < 200 then begin
          Buffer.add_string buf (Printf.sprintf "## %s\n" header);
          incr line_count;
          List.iter (fun (m : memory) ->
            if !line_count < 200 then begin
              Buffer.add_string buf
                (Printf.sprintf "- #%d (%s) — %s\n" m.id (kind_to_string m.kind) m.summary);
              incr line_count
            end
          ) (List.rev mems)
        end
    ) kind_order;
    if !line_count >= 200 then
      Buffer.add_string buf
        (Printf.sprintf "... (%d more memories, use recall_memory to search)\n"
           (List.length all - !line_count));
    Buffer.contents buf

let export_markdown t ~project_id =
  let all = match list t ~project_id ~limit:10000 () with
    | Ok l -> l | Error _ -> [] in
  if all = [] then ""
  else
    let groups = Hashtbl.create 5 in
    List.iter (fun (m : memory) ->
      let key = kind_to_string m.kind in
      let existing = try Hashtbl.find groups key with Not_found -> [] in
      Hashtbl.replace groups key (m :: existing)
    ) all;
    let kind_order = ["convention"; "preference"; "insight"; "gotcha"; "task_map"] in
    let kind_headers = [
      ("convention", "Conventions"); ("preference", "Preferences");
      ("insight", "Insights"); ("gotcha", "Gotchas"); ("task_map", "Task Maps");
    ] in
    let buf = Buffer.create 4096 in
    let date_str =
      let tm = Unix.localtime (Unix.gettimeofday ()) in
      Printf.sprintf "%04d-%02d-%02d"
        (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1) tm.Unix.tm_mday
    in
    Buffer.add_string buf
      (Printf.sprintf "# Project Memory — %s\n\n" project_id);
    Buffer.add_string buf
      (Printf.sprintf "<!-- Auto-generated by `par memory export` on %s. -->\n" date_str);
    Buffer.add_string buf
      "<!-- Do not edit by hand; use `par memory add` / `par memory forget`. -->\n\n";
    List.iter (fun kind_key ->
      match Hashtbl.find_opt groups kind_key with
      | None -> ()
      | Some mems ->
        let header = List.assoc kind_key kind_headers in
        Buffer.add_string buf (Printf.sprintf "## %s\n\n" header);
        List.iter (fun (m : memory) ->
          let ts =
            let tm = Unix.localtime m.updated_at in
            Printf.sprintf "%04d-%02d-%02d"
              (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1) tm.Unix.tm_mday
          in
          Buffer.add_string buf
            (Printf.sprintf "- [%s #%d] %s (updated %s, used %dx)\n"
               (kind_to_string m.kind) m.id m.summary ts m.usage_count);
          Buffer.add_string buf "  ```\n";
          Buffer.add_string buf (Printf.sprintf "  %s\n" m.content);
          if m.citations <> [] then
            Buffer.add_string buf
              (Printf.sprintf "  citations: %s\n"
                 (String.concat ", " m.citations));
          Buffer.add_string buf "  ```\n\n"
        ) (List.rev mems)
    ) kind_order;
    Buffer.contents buf

let prune_stale t ~project_id ~older_than_days =
  let cutoff = Unix.gettimeofday () -. (older_than_days *. 86400.0) in
  wrap_sqlite_error (fun () ->
    let stmt = Sqlite3.prepare t.db
      "DELETE FROM memory_entries \
       WHERE project_id = ? AND usage_count = 0 AND updated_at < ?" in
    let _ = Sqlite3.bind_text stmt 1 project_id in
    let _ = Sqlite3.bind_double stmt 2 cutoff in
    let rc = Sqlite3.step stmt in
    let _ = Sqlite3.finalize stmt in
    match rc with
    | Sqlite3.Rc.DONE -> Sqlite3.changes t.db
    | _ -> raise (Sqlite3.Error (Sqlite3.Rc.to_string rc)))
