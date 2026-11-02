(* par_code_repl_io.ml — REPL support layer.
 *
 * Streaming callbacks, session resume, memory appendix, session cost
 * accounting, and payload debug dumps. Extracted from par_code_repl.ml
 * (v0.8.0) to keep the REPL loop file under the 800-line limit.
 * Pure move: no behavior change. *)

open Par

let string_contains_i ~haystack ~needle =
  let h = String.lowercase_ascii haystack in
  let n = String.lowercase_ascii needle in
  let lh = String.length h and ln = String.length n in
  let rec go i =
    if i + ln > lh then false
    else if String.sub h i ln = n then true
    else go (i + 1)
  in
  ln = 0 || go 0

let stream_print_chunk (ui : Par_code_ui.backend) (chunk : Types.llm_response_chunk) =
  Par_code_ui.render_llm_chunk ui chunk

exception Stream_cancel_requested

let make_stream_cb ?(cancelled = fun () -> false) ui =
  let streamed_text = ref false in
  let cb chunk =
    if cancelled () then raise Stream_cancel_requested;
    (match chunk with Types.Text_delta _ -> streamed_text := true | _ -> ());
    stream_print_chunk ui chunk
  in
  cb, streamed_text

let make_tool_event_callback (ui : Par_code_ui.backend) ?(doom = None)
    ?(on_doom_action : Par_code_doom_loop.action -> unit = fun _ -> ())
    ?(goal_active : unit -> bool = fun () -> false) () =
  let start_times : (string, float) Hashtbl.t = Hashtbl.create 8 in
  let tool_args_buf : (string, string) Hashtbl.t = Hashtbl.create 8 in
  fun (evt : Types.event) ->
    (match evt, doom with
     | Types.Bash_invoked { task_id; argv; _ }, Some _ ->
       Hashtbl.replace tool_args_buf (Types.Task_id.to_string task_id)
         (String.concat " " argv)
     | Types.Tool_invoked { task_id; _ }, Some _ ->
       Hashtbl.replace tool_args_buf (Types.Task_id.to_string task_id) ""
     | Types.Tool_completed { task_id; tool_name; result_preview; _ }, Some d ->
       let tid = Types.Task_id.to_string task_id in
       let args_str = Hashtbl.find_opt tool_args_buf tid |> Option.value ~default:"" in
       Hashtbl.remove tool_args_buf tid;
       let action = Par_code_doom_loop.record d {
         tool_name; args_json = `String args_str;
         output = result_preview; failed = false
       } in
       (match action with
        | Par_code_doom_loop.Nudge msg -> Par_code_ui.render_warning ui msg
        | Force_judge msg -> on_doom_action (Force_judge msg); Par_code_ui.render_warning ui msg
        | Abort msg ->
          on_doom_action (Abort msg);
           let label = if goal_active () then "goal aborted" else "turn aborted" in
           Par_code_ui.render_error ui
             (Printf.sprintf "\xe2\x9c\x97 %s (doom loop) \xe2\x80\x94 cancelling this turn: %s" label msg)
        | Continue -> ())
     | Types.Tool_failed { task_id; tool_name; _ }, Some d ->
       let tid = Types.Task_id.to_string task_id in
       let args_str = Hashtbl.find_opt tool_args_buf tid |> Option.value ~default:"" in
       Hashtbl.remove tool_args_buf tid;
       let action = Par_code_doom_loop.record d {
         tool_name; args_json = `String args_str;
         output = None; failed = true
       } in
       (match action with
        | Par_code_doom_loop.Nudge msg -> Par_code_ui.render_warning ui msg
        | Force_judge msg -> on_doom_action (Force_judge msg); Par_code_ui.render_warning ui msg
        | Abort msg ->
          on_doom_action (Abort msg);
           let label = if goal_active () then "goal aborted" else "turn aborted" in
           Par_code_ui.render_error ui
             (Printf.sprintf "\xe2\x9c\x97 %s (doom loop) \xe2\x80\x94 cancelling this turn: %s" label msg)
        | Continue -> ())
     | _ -> ());
    match evt with
    | Types.Tool_invoked { task_id; _ } ->
      Hashtbl.replace start_times (Types.Task_id.to_string task_id) (Unix.gettimeofday ());
      Par_code_ui.render_tool_event ui evt
    | Types.Tool_completed { task_id; _ } ->
      Hashtbl.remove start_times (Types.Task_id.to_string task_id);
      Par_code_ui.render_tool_event ui evt
    | Types.Tool_failed { task_id; tool_name; _ } ->
      let tid = Types.Task_id.to_string task_id in
      let elapsed = match Hashtbl.find_opt start_times tid with
        | Some t -> (Unix.gettimeofday () -. t) *. 1000.0
        | None -> 0.0
      in
      Hashtbl.remove start_times tid;
      Par_code_ui.render_line ui
        (Par_code_ui.textf ~style:(Par_code_ui.style ~fg:Red ~bold:true ())
           "  \xe2\x86\x92 %s \xe2\x9c\x97 (%.1fms)" tool_name elapsed)
    | _ -> Par_code_ui.render_tool_event ui evt

let print_help (ui : Par_code_ui.backend) () =
  Par_code_ui.render_help ui

let format_health (ui : Par_code_ui.backend) (h : Types.health_status) =
  let runtime_label = if h.Types.runtime_alive then "alive" else "DEAD" in
  let persistence_label = if h.Types.persistence_ok then "ok" else "FAILING" in
  Par_code_ui.render_notice ui (Printf.sprintf "  Runtime:    %s" runtime_label);
  Par_code_ui.render_notice ui (Printf.sprintf "  Persistence: %s" persistence_label)

type resume_target =
  | No_prior
  | Resume_most_recent
  | Resume_of of string

let load_initial_conv (ui : Par_code_ui.backend) (rt : Runtime.runtime) (target : resume_target) : Types.conversation option =
  match target with
  | No_prior -> None
  | Resume_most_recent ->
    (match Par_code_session.load_most_recent_scoped () with
     | Ok (Some (sid, conv)) ->
       Par_code_ui.render_notice ui (Printf.sprintf "Resumed most recent session: %s" sid);
       Some (Par_code_payload.sanitize conv)
     | Ok None -> Par_code_ui.render_warning ui "No prior session found."; None
     | Error e -> Par_code_ui.render_error ui (Printf.sprintf "Failed to load session: %s" e); None)
  | Resume_of id_or_prefix ->
    (match Par_code_session.resolve_id id_or_prefix with
     | Error msg -> Par_code_ui.render_error ui msg; None
     | Ok sid ->
       (match Runtime.load_conversation rt sid with
        | Ok (Some conv) ->
          Par_code_ui.render_notice ui (Printf.sprintf "Resumed session: %s" sid);
          Some (Par_code_payload.sanitize conv)
        | Ok None -> Par_code_ui.render_error ui (Printf.sprintf "Session not found: %s" sid); None
        | Error e -> Par_code_ui.render_error ui (Printf.sprintf "Failed to load session %s: %s" sid (Par_code_setup.error_to_string e)); None))

let maybe_extract (ui : Par_code_ui.backend) (rt : Runtime.runtime) (conv : Types.conversation option) =
  let enabled =
    match Sys.getenv_opt "PAR_NO_AUTO_EXTRACT" with
    | Some "1" | Some "true" -> false
    | _ ->
      (match Par_code_config.load () with
       | Some cfg -> cfg.Par_code_config.auto_extract
       | None -> true)
  in
  if enabled then begin
    match conv with
    | None -> ()
    | Some c ->
      if List.length c.Types.messages <= 1 then ()
      else begin
        (try
           let project_id = Par_code_memory.resolve_project_id () in
           (match Par_code_memory.open_db () with
            | Error (`Db_error msg) ->
              Par_code_ui.render_warning ui (Printf.sprintf "[extraction skipped: %s]" msg)
            | Ok mem_db ->
              Par_code_extractor.run_extraction rt mem_db ~project_id c;
              Par_code_memory.close mem_db)
         with ex ->
           Par_code_ui.render_error ui (Printf.sprintf "[extraction failed: %s]" (Printexc.to_string ex)))
      end
  end

let build_memory_appendix (mem_db : Par_code_memory.t option) =
  match mem_db with
  | Some t ->
    let project_id = Par_code_memory.resolve_project_id () in
    let index = Par_code_memory.render_index t ~project_id in
    if index = "" then None else Some ("\n\n## Project Memory\n\n" ^ index)
  | None -> None

(* ── Session cost tracking ──────────────────────────────────────────────── *)

type cost_state = {
  llm_calls : int;
  prompt_tokens : int;
  completion_tokens : int;
  total_tokens : int;
}

let empty_cost = {
  llm_calls = 0;
  prompt_tokens = 0;
  completion_tokens = 0;
  total_tokens = 0;
}

let add_usage (state : cost_state) (usage : Types.usage_stats) : cost_state = {
  llm_calls = state.llm_calls + 1;
  prompt_tokens = state.prompt_tokens + usage.Types.prompt_tokens;
  completion_tokens = state.completion_tokens + usage.Types.completion_tokens;
  total_tokens = state.total_tokens + usage.Types.total_tokens;
}

let add_generate_usage (state : cost_state) (total_tokens : int option) : cost_state = {
  state with
  llm_calls = state.llm_calls + 1;
  total_tokens = state.total_tokens + Option.value total_tokens ~default:0;
}

let format_cost_output ~cost ~context_tokens ~turn_count ~metrics =
  let b = Buffer.create 256 in
  Buffer.add_string b "Session usage:\n";
  Buffer.add_string b (Printf.sprintf "  LLM calls:        %d\n" cost.llm_calls);
  Buffer.add_string b (Printf.sprintf "  Prompt tokens:    %d\n" cost.prompt_tokens);
  Buffer.add_string b (Printf.sprintf "  Output tokens:    %d\n" cost.completion_tokens);
  Buffer.add_string b (Printf.sprintf "  Total tokens:     %d\n" cost.total_tokens);
  Buffer.add_string b (Printf.sprintf "  Context size:     %d tokens (current)\n" context_tokens);
  Buffer.add_string b (Printf.sprintf "  Turns completed:  %d\n" turn_count);
  Buffer.add_string b "\nOperational metrics:\n";
  List.iter (fun (k, v) ->
    Buffer.add_string b (Printf.sprintf "  %s: %d\n" k v)) metrics;
  Buffer.add_string b "\nNote: excludes async checkpoint/extraction calls.\n";
  Buffer.contents b

(* --- Payload debug dump (v0.7.3+) ---------------------------------------- *)
(* When the provider rejects a replayed conversation (HTTP 400 / Invalid_input),
   dump the exact messages JSON to disk for byte-level root-cause analysis. *)

let max_payload_dump_files = 5
let max_payload_dump_bytes = 2 * 1024 * 1024

let debug_dir () =
  Filename.concat (Filename.concat (Sys.getenv_opt "HOME" |> Option.value ~default:"/tmp") ".par") "debug"

(** List payload-*.json in [dir], keep newest [keep] by mtime, delete the rest.
    Pure-ish: only touches [dir]; returns the kept paths sorted newest-first.
    Returns [[]] on any failure. *)
let prune_payload_files ~dir ~keep =
  (try
     let entries = Sys.readdir dir |> Array.to_list in
     let is_all_digits s =
       let rec go i = i >= String.length s || (s.[i] >= '0' && s.[i] <= '9' && go (i + 1)) in
       String.length s > 0 && go 0
     in
     let payload_files = List.filter (fun f ->
       String.length f > 13 &&
       String.sub f 0 8 = "payload-" &&
       String.ends_with ~suffix:".json" f &&
       is_all_digits (String.sub f 8 (String.length f - 13))
     ) entries in
     let with_mtime = List.filter_map (fun f ->
       let path = Filename.concat dir f in
       match (Unix.stat path).Unix.st_mtime with
       | mtime -> Some (path, mtime)
       | exception _ -> None
     ) payload_files in
     let sorted = List.sort (fun (_, a) (_, b) -> compare b a) with_mtime in
     let keep_list, delete_list =
       let rec split n acc = function
         | [] -> (List.rev acc, [])
         | rest when n <= 0 -> (List.rev acc, rest)
         | x :: xs -> split (n - 1) (x :: acc) xs
       in
       split keep [] sorted
     in
     List.iter (fun (path, _) ->
       (try Sys.remove path with Sys_error _ -> ())
     ) delete_list;
     List.map fst keep_list
   with _ -> [])

(* Two rejections inside the same second would collide on a seconds-resolution
   filename, and the later dump would overwrite the earlier evidence -- which is
   the one thing this diagnostic exists to prevent. The per-process counter keeps
   the name all-digits, which is exactly what [prune_payload_files] matches on. *)
let payload_dump_seq = ref 0

let dump_payload_debug (ui : Par_code_ui.backend) (conv : Types.conversation) =
  (try
     let dir = debug_dir () in
     (* mkdir -p: on a fresh HOME the parent may not exist yet, and a bare
        [mkdir] would turn the whole dump into a silent no-op. *)
     let rec mkdir_p d =
       if not (Sys.file_exists d) then begin
         mkdir_p (Filename.dirname d);
         (try Unix.mkdir d 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ())
       end
     in
     (try mkdir_p dir with _ -> ());
     let ts = int_of_float (Unix.gettimeofday ()) in
     incr payload_dump_seq;
     let path =
       Filename.concat dir
         (Printf.sprintf "payload-%d%03d.json" ts (!payload_dump_seq mod 1000))
     in
     let json = Yojson.Safe.to_string
       (`List (List.map Types.message_to_yojson conv.Types.messages)) in
     let len = String.length json in
     let content =
       if len > max_payload_dump_bytes then
         let truncated = String.sub json 0 max_payload_dump_bytes in
         truncated ^ ",{\"_truncated\":true,\"original_bytes\":" ^ string_of_int len ^ "}]"
       else json
     in
     let oc = open_out path in
     (try output_string oc content; close_out oc
      with exn -> (try close_out oc with _ -> ()); raise exn);
     ignore (prune_payload_files ~dir ~keep:max_payload_dump_files);
     Par_code_ui.render_notice ui (Printf.sprintf "[debug] payload dumped to %s" path)
   with _ -> ())

