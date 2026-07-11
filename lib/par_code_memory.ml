(* par_code_memory.ml — v0.3.3: storage delegated to PAR SDK Sqlite_memory.
 *
 * Memory CRUD delegates to Par_memory.Sqlite_memory (FTS5 + vec0 + hybrid search).
 * par-code-specific features (kind grouping, render_index, export_markdown,
 * prune_stale, search_history via conversations_fts) are kept as thin wrappers
 * using raw SQL on the shared db handle.
 *
 * Old v0.3.0–v0.3.2 schema (integer id, kind column, citations column) is
 * auto-migrated on first open: data is read, old tables dropped, Sqlite_memory
 * creates new schema, data re-inserted preserving timestamps and usage stats. *)

open Par_memory

type t = {
  mem : Sqlite_memory.t;
  db : Sqlite3.db;
}

type kind = Preference | Convention | Insight | Gotcha | Task_map

type memory = {
  id : string;
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

type history_hit = {
  session_id : string;
  snippet : string;
  updated_at : float;
  turn_count : int;
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

let map_memory_error = function
  | Ok x -> Ok x
  | Error e -> Error (`Db_error (Memory_error.to_string e))

let citations_to_json (citations : string list) : string =
  Yojson.Safe.to_string (`List (List.map (fun s -> `String s) citations))

let citations_of_json (s : string) : string list =
  match Yojson.Safe.from_string s with
  | `List items -> List.filter_map (function `String s -> Some s | _ -> None) items
  | _ -> []

let sanitize_fts_query (query : string) : string =
  let buf = Buffer.create (String.length query + 2) in
  Buffer.add_char buf '"';
  String.iter (fun c ->
    if c = '"' then Buffer.add_string buf "\"\""
    else Buffer.add_char buf c
  ) query;
  Buffer.add_char buf '"';
  Buffer.contents buf

(* -- Migration from v0.3.0–v0.3.2 schema --------------------------------- *)

let table_exists db name =
  let stmt = Sqlite3.prepare db
    "SELECT name FROM sqlite_master WHERE type='table' AND name=?" in
  let _ = Sqlite3.bind_text stmt 1 name in
  let found = Sqlite3.step stmt = Sqlite3.Rc.ROW in
  let _ = Sqlite3.finalize stmt in
  found

let column_exists db table col =
  let stmt = Sqlite3.prepare db
    (Printf.sprintf "PRAGMA table_info(%s)" table) in
  let found = ref false in
  (try
     while Sqlite3.step stmt = Sqlite3.Rc.ROW do
       if Sqlite3.column_text stmt 1 = col then found := true
     done
   with _ -> ());
  let _ = Sqlite3.finalize stmt in
  !found

type old_memory = {
  o_kind : string;
  o_project_id : string;
  o_content : string;
  o_summary : string;
  o_citations : string list;
  o_created_at : float;
  o_updated_at : float;
  o_last_used_at : float option;
  o_usage_count : int;
  o_source : string;
}

let read_old_memories db =
  if not (table_exists db "memory_entries") then []
  else if not (column_exists db "memory_entries" "kind") then []
  else begin
    let stmt = Sqlite3.prepare db
      "SELECT project_id, kind, content, summary, citations, \
       created_at, updated_at, last_used_at, usage_count, source \
       FROM memory_entries" in
    let results = ref [] in
    (try
       while Sqlite3.step stmt = Sqlite3.Rc.ROW do
         let citations =
           try citations_of_json (Sqlite3.column_text stmt 4)
           with _ -> []
         in
         let last_used =
           if Sqlite3.column_is_null stmt 7 then None
           else Some (Sqlite3.column_double stmt 7)
         in
         results := {
           o_kind = Sqlite3.column_text stmt 1;
           o_project_id = Sqlite3.column_text stmt 0;
           o_content = Sqlite3.column_text stmt 2;
           o_summary = Sqlite3.column_text stmt 3;
           o_citations = citations;
           o_created_at = Sqlite3.column_double stmt 5;
           o_updated_at = Sqlite3.column_double stmt 6;
           o_last_used_at = last_used;
           o_usage_count = Sqlite3.column_int stmt 8;
           o_source = Sqlite3.column_text stmt 9;
         } :: !results
       done
     with _ -> ());
    let _ = Sqlite3.finalize stmt in
    List.rev !results
  end

let drop_old_memory_schema db =
  let cmds = [
    "DROP TRIGGER IF EXISTS memory_ai";
    "DROP TRIGGER IF EXISTS memory_ad";
    "DROP TRIGGER IF EXISTS memory_au";
    "DROP TABLE IF EXISTS memory_entries_fts";
    "DROP TABLE IF EXISTS memory_entries";
  ] in
  List.iter (fun sql -> ignore (Sqlite3.exec db sql)) cmds

let reinsert_migrated db memories =
  List.iter (fun old ->
    let ext_id = Uuidm.to_string (Uuidm.v4_gen (Random.State.make_self_init ()) ()) in
    let metadata = Printf.sprintf "{\"citations\":%s}" (citations_to_json old.o_citations) in
    let categories = Printf.sprintf "[\"%s\"]" old.o_kind in
    let stmt = Sqlite3.prepare db
      "INSERT INTO memory_entries \
       (ext_id, content, summary, scope, metadata, categories, \
        created_at, updated_at, last_used_at, usage_count, source) \
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)" in
    let _ = Sqlite3.bind_text stmt 1 ext_id in
    let _ = Sqlite3.bind_text stmt 2 old.o_content in
    let _ = Sqlite3.bind_text stmt 3 old.o_summary in
    let _ = Sqlite3.bind_text stmt 4 old.o_project_id in
    let _ = Sqlite3.bind_text stmt 5 metadata in
    let _ = Sqlite3.bind_text stmt 6 categories in
    let _ = Sqlite3.bind_double stmt 7 old.o_created_at in
    let _ = Sqlite3.bind_double stmt 8 old.o_updated_at in
    (match old.o_last_used_at with
     | Some t -> let _ = Sqlite3.bind_double stmt 9 t in ()
     | None -> let _ = Sqlite3.bind stmt 9 Sqlite3.Data.NULL in ());
    let _ = Sqlite3.bind_int stmt 10 old.o_usage_count in
    let _ = Sqlite3.bind_text stmt 11 old.o_source in
    let _ = Sqlite3.step stmt in
    let _ = Sqlite3.finalize stmt in
    ()
  ) memories

(* -- conversations_fts (par-code specific, not in Sqlite_memory) --------- *)

let create_conversations_fts db =
  let stmts = [
    "CREATE VIRTUAL TABLE IF NOT EXISTS conversations_fts USING fts5(messages_json, content='conversations')";
    {|CREATE TRIGGER IF NOT EXISTS conv_ai AFTER INSERT ON conversations BEGIN
        INSERT INTO conversations_fts(rowid, messages_json)
        VALUES (new.rowid, new.messages_json);
    END|};
    {|CREATE TRIGGER IF NOT EXISTS conv_ad AFTER DELETE ON conversations BEGIN
        INSERT INTO conversations_fts(conversations_fts, rowid, messages_json)
        VALUES ('delete', old.rowid, old.messages_json);
    END|};
    {|CREATE TRIGGER IF NOT EXISTS conv_au AFTER UPDATE ON conversations BEGIN
        INSERT INTO conversations_fts(conversations_fts, rowid, messages_json)
        VALUES ('delete', old.rowid, old.messages_json);
        INSERT INTO conversations_fts(rowid, messages_json)
        VALUES (new.rowid, new.messages_json);
    END|};
    "INSERT INTO conversations_fts(conversations_fts) VALUES('rebuild')";
  ] in
  List.iter (fun s -> ignore (Sqlite3.exec db s)) stmts

(* -- open/close ---------------------------------------------------------- *)

let open_db () =
  let path = Par_code_config.db_path () in
  let migration_db = Sqlite3.db_open path in
  let old_memories = read_old_memories migration_db in
  let needs_drop = old_memories <> [] in
  if needs_drop then begin
    drop_old_memory_schema migration_db;
    Printf.eprintf "[migration] %d memories to migrate from v0.3.x schema\n%!"
      (List.length old_memories)
  end;
  let _ = Sqlite3.db_close migration_db in
  match Sqlite_memory.create path with
  | Error e -> Error (`Db_error (Memory_error.to_string e))
  | Ok mem ->
    let db = mem.Sqlite_memory.db in
    let t = { mem; db } in
    create_conversations_fts db;
    if needs_drop then begin
      reinsert_migrated db old_memories;
      Printf.eprintf "[migration] %d memories migrated successfully\n%!"
        (List.length old_memories)
    end;
    Ok t

let close t =
  Sqlite_memory.close t.mem

let resolve_project_id () =
  let ic = Unix.open_process_in "git rev-parse --show-toplevel 2>/dev/null" in
  let line = try input_line ic with End_of_file -> "" in
  let _ = Unix.close_process_in ic in
  let root = String.trim line in
  if root <> "" then root
  else Sys.getcwd ()

(* -- memory_of_object: convert Sqlite_memory result to par-code type ----- *)

let memory_of_object (obj : Memory_object.memory_object) : memory =
  let kind_str = match obj.Memory_object.categories with
    | s :: _ -> s
    | [] -> "gotcha"
  in
  let kind = match kind_of_string kind_str with Some k -> k | None -> Gotcha in
  let citations =
    match List.assoc_opt "citations" obj.Memory_object.metadata with
    | Some (`List items) ->
      List.filter_map (function `String s -> Some s | _ -> None) items
    | _ -> []
  in
  let source = match source_of_string obj.Memory_object.source with
    | Some s -> s | None -> `Manual
  in
  {
    id = obj.Memory_object.id;
    project_id = Option.value obj.Memory_object.scope ~default:"";
    kind;
    content = obj.Memory_object.content;
    summary = Option.value obj.Memory_object.summary ~default:"";
    citations;
    created_at = obj.Memory_object.created_at;
    updated_at = obj.Memory_object.updated_at;
    last_used_at = None;
    usage_count = 0;
    source;
  }

(* -- row_to_memory: raw SQL row reader (for list/render/export) ---------- *)

let row_to_memory (stmt : Sqlite3.stmt) : memory =
  let ext_id = Sqlite3.column_text stmt 0 in
  let scope = Sqlite3.column_text stmt 1 in
  let categories_json = Sqlite3.column_text stmt 2 in
  let content = Sqlite3.column_text stmt 3 in
  let summary = Sqlite3.column_text stmt 4 in
  let metadata_json = Sqlite3.column_text stmt 5 in
  let created_at = Sqlite3.column_double stmt 6 in
  let updated_at = Sqlite3.column_double stmt 7 in
  let last_used_at =
    if Sqlite3.column_is_null stmt 8 then None
    else Some (Sqlite3.column_double stmt 8)
  in
  let usage_count = Sqlite3.column_int stmt 9 in
  let source_str = Sqlite3.column_text stmt 10 in
  let kind_str =
    try
      match Yojson.Safe.from_string categories_json with
      | `List (s :: _) -> Yojson.Safe.Util.to_string s
      | _ -> "gotcha"
    with _ -> "gotcha"
  in
  let kind = match kind_of_string kind_str with Some k -> k | None -> Gotcha in
  let citations =
    try
      match Yojson.Safe.from_string metadata_json with
      | `Assoc kv ->
        (match List.assoc_opt "citations" kv with
         | Some (`List items) ->
           List.filter_map (function `String s -> Some s | _ -> None) items
         | _ -> [])
      | _ -> []
    with _ -> []
  in
  let source = match source_of_string source_str with Some s -> s | None -> `Manual in
  { id = ext_id; project_id = scope; kind; content; summary;
    citations; created_at; updated_at; last_used_at; usage_count; source }

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

(* -- CRUD ---------------------------------------------------------------- *)

let add t ~project_id ~kind ~content ~summary ~citations ~source =
  let result = Sqlite_memory.add t.mem
    ~content
    ~summary
    ~scope:project_id
    ~metadata:[("citations", `List (List.map (fun s -> `String s) citations))]
    ~categories:[kind_to_string kind]
    ~source:(source_to_string source)
    ()
  in
  match result with
  | Ok obj -> Ok obj.Memory_object.id
  | Error e -> Error (`Db_error (Memory_error.to_string e))

let recall t ~project_id ~query ?(limit = 5) () =
  let* results =
    map_memory_error (Sqlite_memory.search t.mem
      ~scope:project_id ~limit query)
  in
  Ok (List.map memory_of_object results)

let forget t ~id =
  map_memory_error (Sqlite_memory.delete t.mem id)

let list t ~project_id ?(limit = 50) () =
  let sql =
    "SELECT ext_id, scope, categories, content, summary, metadata, \
     created_at, updated_at, last_used_at, usage_count, source \
     FROM memory_entries WHERE scope = ? \
     ORDER BY updated_at DESC LIMIT ?" in
  collect_rows t sql (fun stmt ->
    let _ = Sqlite3.bind_text stmt 1 project_id in
    let _ = Sqlite3.bind_int stmt 2 limit in
    ())

let bump_usage t ~id =
  try
    let stmt = Sqlite3.prepare t.db
      "UPDATE memory_entries SET usage_count = usage_count + 1, \
       last_used_at = ? WHERE ext_id = ?" in
    let _ = Sqlite3.bind_double stmt 1 (Unix.gettimeofday ()) in
    let _ = Sqlite3.bind_text stmt 2 id in
    let _ = Sqlite3.step stmt in
    let _ = Sqlite3.finalize stmt in
    ()
  with _ -> ()

(* -- render_index (kind-grouped, uses raw SQL for usage_count) ----------- *)

let render_index t ~project_id =
  let recent = match list t ~project_id ~limit:50 () with
    | Ok l -> l | Error _ -> [] in
  let frequent_sql =
    "SELECT ext_id, scope, categories, content, summary, metadata, \
     created_at, updated_at, last_used_at, usage_count, source \
     FROM memory_entries WHERE scope = ? \
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
              let short_id = String.sub m.id 0 (min 8 (String.length m.id)) in
              Buffer.add_string buf
                (Printf.sprintf "- #%s (%s) — %s\n" short_id (kind_to_string m.kind) m.summary);
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

(* -- export_markdown ----------------------------------------------------- *)

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
          let short_id = String.sub m.id 0 (min 8 (String.length m.id)) in
          Buffer.add_string buf
            (Printf.sprintf "- [%s #%s] %s (updated %s, used %dx)\n"
               (kind_to_string m.kind) short_id m.summary ts m.usage_count);
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

(* -- prune_stale --------------------------------------------------------- *)

let prune_stale t ~project_id ~older_than_days =
  let cutoff = Unix.gettimeofday () -. (older_than_days *. 86400.0) in
  wrap_sqlite_error (fun () ->
    let stmt = Sqlite3.prepare t.db
      "DELETE FROM memory_entries \
       WHERE scope = ? AND usage_count = 0 AND updated_at < ?" in
    let _ = Sqlite3.bind_text stmt 1 project_id in
    let _ = Sqlite3.bind_double stmt 2 cutoff in
    let rc = Sqlite3.step stmt in
    let _ = Sqlite3.finalize stmt in
    match rc with
    | Sqlite3.Rc.DONE -> Sqlite3.changes t.db
    | _ -> raise (Sqlite3.Error (Sqlite3.Rc.to_string rc)))

(* -- search_history (par-code specific, uses conversations_fts) ---------- *)

let search_history t ~query ?(limit = 10) () =
  let fts_query = sanitize_fts_query query in
  let sql =
    "SELECT c.session_id, \
     snippet(conversations_fts, 0, '<<', '>>', '...', 20), \
     c.updated_at, c.turn_count \
     FROM conversations_fts \
     JOIN conversations c ON c.rowid = conversations_fts.rowid \
     WHERE conversations_fts MATCH ? \
     ORDER BY rank LIMIT ?" in
  wrap_sqlite_error (fun () ->
    let stmt = Sqlite3.prepare t.db sql in
    let _ = Sqlite3.bind_text stmt 1 fts_query in
    let _ = Sqlite3.bind_int stmt 2 limit in
    let results = ref [] in
    let rec collect () =
      match Sqlite3.step stmt with
      | Sqlite3.Rc.ROW ->
        let hit = {
          session_id = Sqlite3.column_text stmt 0;
          snippet = Sqlite3.column_text stmt 1;
          updated_at = Sqlite3.column_double stmt 2;
          turn_count = Sqlite3.column_int stmt 3;
        } in
        results := hit :: !results;
        collect ()
      | _ -> ()
    in
    collect ();
    ignore (Sqlite3.finalize stmt);
    List.rev !results)
