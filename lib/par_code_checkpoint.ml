open Par

let ui_error msg = Par_code_ui.render_error (Par_code_ui.create_backend ()) msg
let ui_notice msg = Par_code_ui.render_notice (Par_code_ui.create_backend ()) msg

let checkpoint_writer_agent_id = "checkpoint-writer"

(* v0.4.1 Pillar B: keep the LAST n chars of a long transcript, not the first.
   Long sessions need the latest content for the checkpoint-writer LLM to
   capture current state — the opening greeting adds nothing. *)
let truncate_to_last_n (s : string) (n : int) : string =
  let len = String.length s in
  if len <= n then s
  else String.sub s (len - n) n

let checkpoint_writer_system_prompt = {|
You are a session checkpoint agent. Analyze the coding session transcript and
produce a structured checkpoint that captures the current state of work.

Return ONLY valid JSON with this exact schema:
{
  "task": "one-line description of what the user is working on",
  "decisions": ["key decisions or choices made so far"],
  "files_changed": ["file paths that were read, written, or edited"],
  "interfaces": ["function/type signatures that were added or modified"],
  "open_threads": ["things still TODO or unresolved"]
}

Rules:
- Each list item should be concise (one line).
- Omit fields you cannot determine (use empty arrays).
- For trivial conversations (greetings, simple questions), return:
  {"task":"","decisions":[],"files_changed":[],"interfaces":[],"open_threads":[]}
- Return ONLY the JSON object, no markdown fences, no prose.
|}

type checkpoint_entry = {
  task : string;
  decisions : string list;
  files_changed : string list;
  interfaces : string list;
  open_threads : string list;
  turn_number : int;
  timestamp : float;
}

let wrap_sqlite_error f =
  try Ok (f ())
  with
  | Sqlite3.Error msg -> Error (`Db_error msg)
  | Sqlite3.SqliteError msg -> Error (`Db_error msg)
  | Sqlite3.InternalError msg -> Error (`Db_error msg)
  | Failure msg -> Error (`Db_error msg)

let error_to_string (e : Types.error_category) =
  match e with
  | Types.Timeout -> "Timeout"
  | Types.Invalid_input s -> Printf.sprintf "Invalid input: %s" s
  | Types.External_failure s -> Printf.sprintf "External failure: %s" s
  | Types.Rate_limited -> "Rate limited"
  | Types.Permission_denied s -> Printf.sprintf "Permission denied: %s" s
  | Types.Internal s -> Printf.sprintf "Internal error: %s" s
  | Types.Embedding_unsupported -> "Embedding unsupported"

let create_schema db =
  let stmts = [
    "CREATE TABLE IF NOT EXISTS checkpoints (\
       id TEXT PRIMARY KEY, \
       session_id TEXT NOT NULL, \
       project_id TEXT NOT NULL, \
       turn_number INTEGER NOT NULL, \
       checkpoint_json TEXT NOT NULL, \
       created_at REAL NOT NULL)";
    "CREATE INDEX IF NOT EXISTS idx_ckpts_session \
       ON checkpoints(session_id, turn_number)";
    "CREATE VIRTUAL TABLE IF NOT EXISTS checkpoints_fts \
       USING fts5(checkpoint_json, content='checkpoints')";
    {|CREATE TRIGGER IF NOT EXISTS ckpt_ai AFTER INSERT ON checkpoints BEGIN
        INSERT INTO checkpoints_fts(rowid, checkpoint_json)
        VALUES (new.rowid, new.checkpoint_json);
    END|};
    {|CREATE TRIGGER IF NOT EXISTS ckpt_ad AFTER DELETE ON checkpoints BEGIN
        INSERT INTO checkpoints_fts(checkpoints_fts, rowid, checkpoint_json)
        VALUES ('delete', old.rowid, old.checkpoint_json);
    END|};
    {|CREATE TRIGGER IF NOT EXISTS ckpt_au AFTER UPDATE ON checkpoints BEGIN
        INSERT INTO checkpoints_fts(checkpoints_fts, rowid, checkpoint_json)
        VALUES ('delete', old.rowid, old.checkpoint_json);
        INSERT INTO checkpoints_fts(rowid, checkpoint_json)
        VALUES (new.rowid, new.checkpoint_json);
    END|};
    "INSERT INTO checkpoints_fts(checkpoints_fts) VALUES('rebuild')";
  ] in
  List.iter (fun sql ->
    try ignore (Sqlite3.exec db sql)
    with
    | Sqlite3.Error msg -> ui_error (Printf.sprintf "[checkpoint schema: %s]" msg)
    | Sqlite3.SqliteError msg -> ui_error (Printf.sprintf "[checkpoint schema: %s]" msg)
  ) stmts

let extract_text_from_blocks (blocks : Types.content_block list) : string =
  let buf = Buffer.create 512 in
  List.iter (function
    | Types.Text_block { text; _ } ->
      if Buffer.length buf > 0 then Buffer.add_char buf '\n';
      Buffer.add_string buf text
    | _ -> ()
  ) blocks;
  Buffer.contents buf

let serialize_for_checkpoint (conv : Types.conversation) ~turn_number =
  let user_assistant_msgs =
    List.filter (fun (m : Types.message) ->
      match m.Types.role with
      | Types.User | Types.Assistant -> true
      | Types.System | Types.Tool -> false
    ) conv.Types.messages
  in
  if List.length user_assistant_msgs < 2 then ""
  else
    let buf = Buffer.create 4096 in
    Buffer.add_string buf
      (Printf.sprintf "# Session checkpoint at turn %d\n\n" turn_number);
    List.iter (fun (m : Types.message) ->
      let role = match m.Types.role with
        | Types.User -> "User"
        | Types.Assistant -> "Assistant"
        | _ -> assert false
      in
      let text = extract_text_from_blocks m.Types.content_blocks in
      if text <> "" then
        Buffer.add_string buf (Printf.sprintf "## %s\n\n%s\n\n" role text)
    ) user_assistant_msgs;
    let full = Buffer.contents buf in
    truncate_to_last_n full 8000

let checkpoint_to_json (entry : checkpoint_entry) : string =
  let sl lst = `List (List.map (fun s -> `String s) lst) in
  Yojson.Safe.to_string (`Assoc [
    ("task", `String entry.task);
    ("decisions", sl entry.decisions);
    ("files_changed", sl entry.files_changed);
    ("interfaces", sl entry.interfaces);
    ("open_threads", sl entry.open_threads);
    ("turn_number", `Int entry.turn_number);
    ("timestamp", `Float entry.timestamp);
  ])

let checkpoint_of_json (json_str : string) : checkpoint_entry option =
  try
    let json = Yojson.Safe.from_string json_str in
    let open Yojson.Safe.Util in
    let get_s f =
      match json |> member f |> to_string_option with
      | Some s -> s | None -> ""
    in
    let get_sl f =
      match json |> member f with
      | `List items ->
        List.filter_map (fun x -> try Some (to_string x) with _ -> None) items
      | _ -> []
    in
    Some {
      task = get_s "task";
      decisions = get_sl "decisions";
      files_changed = get_sl "files_changed";
      interfaces = get_sl "interfaces";
      open_threads = get_sl "open_threads";
      turn_number = (try json |> member "turn_number" |> to_int with _ -> 0);
      timestamp = (try json |> member "timestamp" |> to_float with _ -> 0.0);
    }
  with _ -> None

let extract_json_object (text : string) : string option =
  let len = String.length text in
  let first = ref (-1) in
  let last = ref (-1) in
  let depth = ref 0 in
  let i = ref 0 in
  while !i < len do
    (match text.[!i] with
     | '{' -> if !first = -1 then first := !i; incr depth
     | '}' -> decr depth; if !depth = 0 && !first >= 0 then last := !i
     | _ -> ());
    incr i
  done;
  if !first >= 0 && !last >= 0 && !last > !first then
    Some (String.sub text !first (!last - !first + 1))
  else None

let parse_checkpoint_response (text : string) : checkpoint_entry option =
  let json_str = match extract_json_object text with
    | Some s -> s
    | None -> String.trim text
  in
  try
    let json = Yojson.Safe.from_string json_str in
    let open Yojson.Safe.Util in
    let get_s f =
      match json |> member f |> to_string_option with
      | Some s -> s | None -> ""
    in
    let get_sl f =
      match json |> member f with
      | `List items ->
        List.filter_map (fun x -> try Some (to_string x) with _ -> None) items
      | _ -> []
    in
    Some {
      task = get_s "task";
      decisions = get_sl "decisions";
      files_changed = get_sl "files_changed";
      interfaces = get_sl "interfaces";
      open_threads = get_sl "open_threads";
      turn_number = 0;
      timestamp = 0.0;
    }
  with _ -> None

let store_checkpoint mem_db ~session_id ~project_id (entry : checkpoint_entry) =
  let db = Par_code_memory.raw_db mem_db in
  let id = Uuidm.to_string (Uuidm.v4_gen (Random.State.make_self_init ()) ()) in
  let json = checkpoint_to_json entry in
  wrap_sqlite_error (fun () ->
    let stmt = Sqlite3.prepare db
      "INSERT INTO checkpoints \
       (id, session_id, project_id, turn_number, checkpoint_json, created_at) \
       VALUES (?, ?, ?, ?, ?, ?)" in
    let _ = Sqlite3.bind_text stmt 1 id in
    let _ = Sqlite3.bind_text stmt 2 session_id in
    let _ = Sqlite3.bind_text stmt 3 project_id in
    let _ = Sqlite3.bind_int stmt 4 entry.turn_number in
    let _ = Sqlite3.bind_text stmt 5 json in
    let _ = Sqlite3.bind_double stmt 6 entry.timestamp in
    let rc = Sqlite3.step stmt in
    let _ = Sqlite3.finalize stmt in
    match rc with
    | Sqlite3.Rc.DONE -> ()
    | _ -> raise (Sqlite3.Error (Sqlite3.Rc.to_string rc)))

let load_checkpoints mem_db ~session_id =
  let db = Par_code_memory.raw_db mem_db in
  wrap_sqlite_error (fun () ->
    let stmt = Sqlite3.prepare db
      "SELECT checkpoint_json FROM checkpoints \
       WHERE session_id = ? ORDER BY turn_number" in
    let _ = Sqlite3.bind_text stmt 1 session_id in
    let results = ref [] in
    let rec collect () =
      match Sqlite3.step stmt with
      | Sqlite3.Rc.ROW ->
        let json_str = Sqlite3.column_text stmt 0 in
        (match checkpoint_of_json json_str with
         | Some entry -> results := entry :: !results
         | None -> ());
        collect ()
      | _ -> ()
    in
    collect ();
    ignore (Sqlite3.finalize stmt);
    List.rev !results)

let most_recent_checkpoint mem_db ~session_id =
  let db = Par_code_memory.raw_db mem_db in
  wrap_sqlite_error (fun () ->
    let stmt = Sqlite3.prepare db
      "SELECT checkpoint_json FROM checkpoints \
       WHERE session_id = ? ORDER BY turn_number DESC LIMIT 1" in
    let _ = Sqlite3.bind_text stmt 1 session_id in
    match Sqlite3.step stmt with
    | Sqlite3.Rc.ROW ->
      let json_str = Sqlite3.column_text stmt 0 in
      let _ = Sqlite3.finalize stmt in
      checkpoint_of_json json_str
    | _ ->
      let _ = Sqlite3.finalize stmt in
      None)

let load_recent_n mem_db ~session_id n =
  let db = Par_code_memory.raw_db mem_db in
  wrap_sqlite_error (fun () ->
    let stmt = Sqlite3.prepare db
      "SELECT checkpoint_json FROM checkpoints \
       WHERE session_id = ? ORDER BY turn_number DESC LIMIT ?" in
    let _ = Sqlite3.bind_text stmt 1 session_id in
    let _ = Sqlite3.bind_int stmt 2 n in
    let results = ref [] in
    let rec collect () =
      match Sqlite3.step stmt with
      | Sqlite3.Rc.ROW ->
        let json_str = Sqlite3.column_text stmt 0 in
        (match checkpoint_of_json json_str with
         | Some entry -> results := entry :: !results
         | None -> ());
        collect ()
      | _ -> ()
    in
    collect ();
    ignore (Sqlite3.finalize stmt);
    List.rev !results)

let render_session_brief mem_db ~session_id =
  match load_recent_n mem_db ~session_id 3 with
  | Error _ | Ok [] -> ""
  | Ok entries ->
    let buf = Buffer.create 512 in
    Buffer.add_string buf "## Session Checkpoints\n\n";
    List.iter (fun (entry : checkpoint_entry) ->
      if entry.task <> "" then begin
        Buffer.add_string buf
          (Printf.sprintf "**Turn %d** — %s\n" entry.turn_number entry.task);
        List.iter (fun d ->
          Buffer.add_string buf (Printf.sprintf "- Decision: %s\n" d)
        ) entry.decisions;
        if entry.files_changed <> [] then
          Buffer.add_string buf
            (Printf.sprintf "- Files: %s\n"
               (String.concat ", " entry.files_changed));
        List.iter (fun t ->
          Buffer.add_string buf (Printf.sprintf "- TODO: %s\n" t)
        ) entry.open_threads;
        Buffer.add_char buf '\n'
      end
    ) entries;
    Buffer.contents buf

let format_checkpoints (entries : checkpoint_entry list) : string =
  (* v0.4.1 Pillar C: multi-line per-entry rendering for the /checkpoints REPL
     command. Index + Turn + task headline; optional decisions/files/open
     sections indented underneath, omitted when empty. *)
  if entries = [] then ""
  else
    let buf = Buffer.create 256 in
    List.iteri (fun i (e : checkpoint_entry) ->
      Buffer.add_string buf
        (Printf.sprintf "[%d] Turn %d: %s\n"
           (i + 1) e.turn_number
           (if e.task = "" then "(no task)" else e.task));
      if e.decisions <> [] then begin
        Buffer.add_string buf "    decisions: ";
        Buffer.add_string buf (String.concat "; " e.decisions);
        Buffer.add_char buf '\n'
      end;
      if e.files_changed <> [] then begin
        Buffer.add_string buf "    files: ";
        Buffer.add_string buf (String.concat ", " e.files_changed);
        Buffer.add_char buf '\n'
      end;
      if e.open_threads <> [] then begin
        Buffer.add_string buf "    open: ";
        Buffer.add_string buf (String.concat "; " e.open_threads);
        Buffer.add_char buf '\n'
      end
    ) entries;
    Buffer.contents buf

let run_checkpoint ~rt mem_db ~session_id ~project_id conv ~turn_number =
  (* Synchronous checkpoint path. Used by:
     - Manual /checkpoint REPL command (user explicitly asked; willing to wait
       for verification)
     - maybe_checkpoint's async dispatcher (which wraps this in Eio.Fiber.fork
       for the periodic path)

     Preserves v0.4.0's ~save:false ~update_current:false isolation. *)
  let transcript = serialize_for_checkpoint conv ~turn_number in
  if transcript = "" then ()
  else
    match Runtime.invoke_generate rt
            ~agent_id:checkpoint_writer_agent_id
            ~save:false ~update_current:false
            ~message:transcript ()
    with
    | Error (err, _) ->
      ui_error (Printf.sprintf "[checkpoint failed: %s]" (error_to_string err))
    | Ok result ->
      (match parse_checkpoint_response result.Types.text with
       | None ->
          ui_error "[checkpoint failed: unparseable JSON]"
       | Some entry ->
         let entry =
           { entry with turn_number; timestamp = Unix.gettimeofday () }
         in
         (* v0.4.1 Pillar D: confirmed no-op. Both periodic maybe_checkpoint
            and the manual /checkpoint REPL command route through run_checkpoint,
            so both trigger extraction here. No separate wiring needed. *)
         (match store_checkpoint mem_db ~session_id ~project_id entry with
          | Ok () ->
            ui_notice (Printf.sprintf "[checkpoint stored at turn %d]" turn_number);
            Par_code_extractor.run_extraction rt mem_db
              ~project_id conv
          | Error (`Db_error e) ->
            ui_error (Printf.sprintf "[checkpoint store failed: %s]" e)))

let maybe_checkpoint ~rt mem_db ~in_flight ~session_id ~project_id conv
    ~turn_number ~enabled ~interval =
  if not enabled then ()
  else if turn_number mod interval <> 0 then ()
  else if !in_flight then ()  (* v0.4.1 Pillar A Caveat 4: throttle — don't
                                 stack background LLM calls *)
  else
    (* v0.4.1 Pillar A: async periodic checkpoint via Eio.Fiber.fork on the
       runtime's cancellation root. The synchronous 2-5s LLM call now runs
       in a background fiber; the user turn returns immediately.

       Only the PERIODIC path is async — the manual /checkpoint REPL command
       calls run_checkpoint directly (synchronous) because the user explicitly
       asked for a checkpoint and is willing to wait for verification.

       See DECISIONS.md [2026-07-19] Oracle verdict for fiber-safety analysis. *)
    (* Caveat 3: snapshot by value BEFORE forking. The REPL reassigns its conv
       ref on the next turn; the fiber must see the snapshot from its own
       turn. *)
    let conv_snapshot = conv in
    let session_id_snapshot = session_id in
    let project_id_snapshot = project_id in
    let turn_number_snapshot = turn_number in
    in_flight := true;
    (* Caveat 9: invoke_generate (runtime.ml:886) reads rt.user_activated_skills
       live, unlike invoke (runtime.ml:742) which snapshots. par-code never
       mutates this field after setup, so the race is dormant — but a future
       contributor adding mid-session skill toggling would re-activate it. *)
    let _ =
      Eio.Fiber.fork ~sw:(Par.Runtime.cancellation_root rt) (fun () ->
        (* Caveat 1: try/with guards against fiber death on unexpected exn.
           Caveat 4: in_flight reset on every exit path via Fun.protect. *)
        let body () =
          run_checkpoint ~rt mem_db
            ~session_id:session_id_snapshot
            ~project_id:project_id_snapshot
            conv_snapshot
            ~turn_number:turn_number_snapshot
        in
        try
          Fun.protect ~finally:(fun () -> in_flight := false) body
        with exn ->
          (* Body raised (network, cancellation, PAR SDK exn). in_flight was
             reset by finally; log and let the fiber die quietly. *)
          ui_error (Printf.sprintf "[checkpoint crashed: %s]" (Printexc.to_string exn)))
    in
    (* Caveat 5: do NOT await the fiber — fire-and-forget. Awaiting would
       re-introduce the synchronous stall v0.4.1 eliminates. The unit-typed
       result of Eio.Fiber.fork is discarded; the fiber writes its outcomes
       via stderr (existing pattern) and the memory db. *)
    ()
