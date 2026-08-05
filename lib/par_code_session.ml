open Par

type session_info = {
  id : string;
  event_count : int;
  first_event_at : float;
  last_event_at : float;
}

let format_age ts =
  let now = Unix.gettimeofday () in
  let delta = now -. ts in
  if delta < 60.0 then Printf.sprintf "%ds ago" (int_of_float delta)
  else if delta < 3600.0 then Printf.sprintf "%dm ago" (int_of_float (delta /. 60.0))
  else if delta < 86400.0 then Printf.sprintf "%dh ago" (int_of_float (delta /. 3600.0))
  else Printf.sprintf "%dd ago" (int_of_float (delta /. 86400.0))

let with_persistence f =
  let path = Par_code_config.db_path () in
  let retention = 30.0 *. 24.0 *. 60.0 *. 60.0 in
  match Sqlite_persistence.create ~retention_ttl:retention path with
  | Error e ->
    Error (Printf.sprintf "DB error: %s"
      (Par_code_setup.error_to_string e))
  | Ok db ->
    Fun.protect ~finally:(fun () -> Sqlite_persistence.close db) (fun () -> f db)

let list_sessions ~limit : (session_info list, string) result =
  (* v0.5.5 P0 #2: PAR SDK's [Sqlite_persistence.load_sessions] filters by
     [events.scope], but events don't carry scope in our pipeline (only
     conversations do, via [Runtime.save_conversation ~scope ...]). JOIN
     events with conversations to filter on the column that IS populated.
     When PAR SDK plumbs scope through the event bus, this can revert to
     the simpler [Sqlite_persistence.load_sessions]. *)
  with_persistence (fun db ->
    let scope = Par_code_memory.resolve_project_id () in
    let raw_db = Sqlite_persistence.raw_sqlite3_db db in
    let stmt =
      Sqlite3.prepare raw_db
        "SELECT e.session_id, COUNT(*) AS cnt, MIN(e.timestamp), MAX(e.timestamp) \
         FROM events e \
         JOIN conversations c ON c.session_id = e.session_id \
         WHERE c.scope = ? \
         GROUP BY e.session_id \
         ORDER BY MAX(e.timestamp) DESC \
         LIMIT ?"
    in
    ignore (Sqlite3.bind_text stmt 1 scope);
    ignore (Sqlite3.bind_int stmt 2 limit);
    let results = ref [] in
    let rec fetch () =
      match Sqlite3.step stmt with
      | Sqlite3.Rc.ROW ->
        let sid = Sqlite3.column_text stmt 0 in
        let cnt = Sqlite3.column_int stmt 1 in
        let first_at = Sqlite3.column_double stmt 2 in
        let last_at = Sqlite3.column_double stmt 3 in
        results := { id = sid; event_count = cnt;
                     first_event_at = first_at; last_event_at = last_at } :: !results;
        fetch ()
      | Sqlite3.Rc.DONE -> ()
      | _ -> ()
    in
    fetch ();
    ignore (Sqlite3.finalize stmt);
    Ok (List.rev !results))

let load (session_id : string) : (Types.conversation option, string) result =
  with_persistence (fun db ->
    match Sqlite_persistence.load_conversation db session_id with
    | Ok conv -> Ok conv
    | Error e ->
      Error (Printf.sprintf "load_conversation failed: %s"
        (Par_code_setup.error_to_string e)))

let load_most_recent_scoped () : ((string * Types.conversation) option, string) result =
  with_persistence (fun db ->
    let scope = Par_code_memory.resolve_project_id () in
    match Sqlite_persistence.load_most_recent_conversation ~scope db with
    | Ok result -> Ok result
    | Error e ->
      Error (Printf.sprintf "load_most_recent_conversation failed: %s"
        (Par_code_setup.error_to_string e)))

let resolve_id (prefix : string) : (string, string) result =
  if String.length prefix >= 36 then
    Ok prefix
  else
    match list_sessions ~limit:200 with
    | Error e -> Error e
    | Ok summaries ->
      let matches =
        List.filter (fun s ->
          String.starts_with ~prefix s.id
        ) summaries
      in
      match matches with
      | [] -> Error (Printf.sprintf "No session matches prefix '%s'" prefix)
      | [s] -> Ok s.id
      | _ ->
        let count = List.length matches in
        Error (Printf.sprintf "Prefix '%s' matches %d sessions — be more specific"
                 prefix count)

let rec first_user_text messages =
  match messages with
  | [] -> "(no user message)"
  | m :: rest ->
    if m.Types.role = Types.User then
      let buf = Buffer.create 64 in
      List.iter (function
        | Types.Text_block { text; _ } -> Buffer.add_string buf text
        | _ -> ()) m.Types.content_blocks;
      let raw = Buffer.contents buf in
      let trimmed = String.trim raw in
      if trimmed = "" then "(empty)" else trimmed
    else first_user_text rest

let resolve_title (session_id : string) : string =
  match load session_id with
  | Ok (Some conv) ->
    let result = first_user_text conv.Types.messages in
    let max_len = 50 in
    if String.length result > max_len then
      String.sub result 0 max_len ^ "..."
    else result
  | _ -> "(unavailable)"

let generate_uuid () =
  let seed = int_of_float (Unix.gettimeofday () *. 1000.0) in
  let state = Random.State.make [| seed; seed lxor 0xdeadbeef; seed lxor 0xfeedface |] in
  let gen = Uuidm.v4_gen state in
  Uuidm.to_string (gen ())

let fork (source_id : string) : (string, string) result =
  match load source_id with
  | Error e -> Error e
  | Ok None -> Error (Printf.sprintf "Session not found: %s" source_id)
  | Ok (Some conv) ->
    let new_id = generate_uuid () in
    let scope = Par_code_memory.resolve_project_id () in
    with_persistence (fun db ->
      match Sqlite_persistence.save_conversation ~scope db new_id conv with
      | Ok () -> Ok new_id
      | Error e ->
        Error (Printf.sprintf "save_conversation failed: %s"
          (Par_code_setup.error_to_string e)))

