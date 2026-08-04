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
  with_persistence (fun db ->
    let scope = Par_code_memory.resolve_project_id () in
    match Sqlite_persistence.load_sessions ~scope db limit with
    | Ok summaries ->
      Ok (List.map (fun s ->
        {
          id = s.Types.session_id;
          event_count = s.Types.event_count;
          first_event_at = s.Types.first_event_at;
          last_event_at = s.Types.last_event_at;
        }
      ) summaries)
    | Error e ->
      Error (Printf.sprintf "load_sessions failed: %s"
        (Par_code_setup.error_to_string e)))

let load (session_id : string) : (Types.conversation option, string) result =
  with_persistence (fun db ->
    match Sqlite_persistence.load_conversation db session_id with
    | Ok conv -> Ok conv
    | Error e ->
      Error (Printf.sprintf "load_conversation failed: %s"
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

