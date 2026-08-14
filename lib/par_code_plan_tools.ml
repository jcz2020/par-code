(* par_code_plan_tools.ml — LLM-facing plan mode tools for par-code v0.5.0.
 *
 * Two tool bindings that let the agent switch between plan and build modes:
 * - plan_enter: request switch TO plan mode (read-only)
 * - plan_exit:  request switch FROM plan TO build mode
 *
 * Each tool is a [Types.tool_binding] with descriptor + handler, compatible
 * with [Runtime.register_tool].
 *
 * plan_exit handler switches mode only — persistence requires conversation
 * access which the tool handler signature doesn't provide. The /build slash
 * command in par_code_repl.ml calls [persist_plan_file] with the REPL's
 * conversation ref. *)

open Par

(* -- Helpers -------------------------------------------------------------- *)

(* -- Tool schemas --------------------------------------------------------- *)

let plan_enter_input_schema : Yojson.Safe.t =
  `Assoc
    [ ("type", `String "object")
    ; ("properties", `Assoc [])
    ; ("required", `List [])
    ]

let plan_exit_input_schema : Yojson.Safe.t =
  `Assoc
    [ ("type", `String "object")
    ; ("properties", `Assoc [])
    ; ("required", `List [])
    ]

(* -- Tool bindings -------------------------------------------------------- *)

let plan_enter_handler : Yojson.Safe.t -> Types.cancellation_token -> Types.handler_result =
  fun _input _tok ->
    let prev = Par_code_mode.switch Plan in
    let prev_label = Par_code_mode.label prev in
    let response =
      `Assoc [("ok", `Bool true);
              ("mode", `String "plan");
              ("previous_mode", `String prev_label)]
    in
    Types.Success response

let plan_exit_handler : Yojson.Safe.t -> Types.cancellation_token -> Types.handler_result =
  fun _input _tok ->
    let prev = Par_code_mode.switch Build in
    let prev_label = Par_code_mode.label prev in
    let response =
      `Assoc [("ok", `Bool true);
              ("mode", `String "build");
              ("previous_mode", `String prev_label);
              ("plan_saved_to", `Null);
              ("note", `String "use /build to persist")]
    in
    Types.Success response

let plan_enter_tool : Types.tool_binding =
  let open Types in
  let descriptor =
    { name = "plan_enter"
    ; description =
        "Enter plan mode (read-only). Call this when you want to investigate \
         and plan before implementing."
    ; input_schema = plan_enter_input_schema
    ; output_schema = None
    ; permission = Allow
    ; timeout = Some 10.0
    ; concurrency_limit = None
    ; on_update = None
    ; cache_control = None
    }
  in
  { descriptor; handler = plan_enter_handler }

let plan_exit_tool : Types.tool_binding =
  let open Types in
  let descriptor =
    { name = "plan_exit"
    ; description =
        "Exit plan mode and switch to build mode. Call this when your plan \
         is complete."
    ; input_schema = plan_exit_input_schema
    ; output_schema = None
    ; permission = Allow
    ; timeout = Some 10.0
    ; concurrency_limit = None
    ; on_update = None
    ; cache_control = None
    }
  in
  { descriptor; handler = plan_exit_handler }

(* -- Plan persistence ----------------------------------------------------- *)

let extract_text_from_blocks (blocks : Types.content_block list) : string =
  let buf = Buffer.create 512 in
  List.iter (function
    | Types.Text_block { text; _ } ->
      if Buffer.length buf > 0 then Buffer.add_char buf '\n';
      Buffer.add_string buf text
    | _ -> ()
  ) blocks;
  Buffer.contents buf

let find_last_assistant_text (conv : Types.conversation) : string option =
  let rec walk = function
    | [] -> None
    | (m : Types.message) :: rest ->
      if m.Types.role = Types.Assistant then begin
        let text = extract_text_from_blocks m.Types.content_blocks in
        if text <> "" then Some text else walk rest
      end else walk rest
  in
  walk (List.rev conv.Types.messages)

let format_timestamp () =
  let tm = Unix.gmtime (Unix.gettimeofday ()) in
  Printf.sprintf "%04d-%02d-%02dT%02d-%02d-%02dZ"
    (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1) tm.Unix.tm_mday
    tm.Unix.tm_hour tm.Unix.tm_min tm.Unix.tm_sec

let ensure_plans_dir () =
  let par_dir = ".par" in
  let plans_dir = Filename.concat par_dir "plans" in
  (try if not (Sys.file_exists par_dir) then Unix.mkdir par_dir 0o755
   with Sys_error _ -> ());
  (try if not (Sys.file_exists plans_dir) then Unix.mkdir plans_dir 0o755
   with Sys_error _ -> ());
  plans_dir

let persist_plan_file (conv : Types.conversation) : string option =
  match find_last_assistant_text conv with
  | None -> None
  | Some text ->
    let text = Json_extract.strip_think_tags text in
    try
      let plans_dir = ensure_plans_dir () in
      let filename = format_timestamp () ^ ".md" in
      let path = Filename.concat plans_dir filename in
      let oc = open_out path in
      Fun.protect ~finally:(fun () -> close_out oc)
        (fun () -> output_string oc text);
      Some path
    with Sys_error _ -> None

(* -- plan_submit tool ----------------------------------------------------- *)

let plan_submit_input_schema : Yojson.Safe.t =
  `Assoc
    [ ("type", `String "object")
    ; ("properties", `Assoc
        [ ("plan", `Assoc
            [ ("type", `String "string")
            ; ("description", `String
                "Your complete plan in markdown. Must include sections: \
                 ## Goal, ## Approach, ## Files to Touch, ## Risks, \
                 ## Open Questions, ## Steps")
            ])
        ])
    ; ("required", `List [ `String "plan" ])
    ]

let last_submitted_plan : string option ref = ref None

let consume_submitted_plan () =
  match !last_submitted_plan with
  | Some path -> last_submitted_plan := None; Some path
  | None -> None

(** Pure gate-response function — separated for testability. *)
let gate_response ~confirmed path =
  if confirmed then begin
    last_submitted_plan := Some path;
    ignore (Par_code_mode.switch Build);
    `Assoc [ ("plan_saved_to", `String path)
           ; ("mode", `String "build") ]
  end else
    `Assoc [ ("plan_saved_to", `String path)
           ; ("mode", `String "plan")
           ; ("reason", `String "switch_not_confirmed") ]

let make_plan_submit_tool ~(ui : Par_code_ui.backend Lazy.t) : Types.tool_binding =
  let open Types in
  let descriptor =
    { name = "plan_submit"
    ; description =
        "Submit your complete plan and switch to build mode. You MUST call \
         this tool to finish planning. The 'plan' argument must be your full \
         plan in markdown format with all required sections."
    ; input_schema = plan_submit_input_schema
    ; output_schema = None
    ; permission = Allow
    ; timeout = Some 30.0
    ; concurrency_limit = None
    ; on_update = None
    ; cache_control = None
    }
  in
  let handler json _tok =
    let open Yojson.Safe.Util in
    let plan =
      try json |> member "plan" |> to_string
      with Type_error _ -> ""
    in
    if plan = "" then
      Error
        { category = Invalid_input "plan_submit"
        ; message = "Missing or empty 'plan' field"
        ; retryable = false
        ; metadata = []
        }
    else begin
      let cleaned = Json_extract.strip_think_tags plan in
      let plans_dir = ensure_plans_dir () in
      let filename = format_timestamp () ^ ".md" in
      let path = Filename.concat plans_dir filename in
      (try
        let oc = open_out path in
        Fun.protect ~finally:(fun () -> close_out oc)
          (fun () -> output_string oc cleaned);
        let backend = Lazy.force ui in
        Par_code_ui.render_notice backend
          (Printf.sprintf "Plan saved to %s" path);
        let sty = Par_code_ui.style ~fg:Yellow ~bold:true () in
        let confirmed = match Par_code_ui.prompt_confirm
            ~backend ~style:sty "\nSwitch to build mode? [y/N] " with
          | Some "y" -> true
          | _ -> false
        in
        Success (gate_response ~confirmed path)
      with Sys_error _ ->
        Error
          { category = External_failure "plan_submit"
          ; message = "Failed to write plan file"
          ; retryable = false
          ; metadata = []
          })
    end
  in
  { descriptor; handler }

(* -- write_plan_file tool ------------------------------------------------- *)

let write_plan_file_input_schema : Yojson.Safe.t =
  `Assoc
    [ ("type", `String "object")
    ; ("properties", `Assoc
        [ ("filename", `Assoc
            [ ("type", `String "string")
            ; ("description", `String
                "Plan filename, e.g. 'add-auth.md' (only .md extension allowed)")
            ])
        ; ("content", `Assoc
            [ ("type", `String "string")
            ; ("description", `String "Full plan content in markdown")
            ])
        ])
    ; ("required", `List [ `String "filename"; `String "content" ])
    ]

let sanitize_plan_filename raw =
  let base = Filename.basename raw in
  let safe = String.map (fun c -> if c = '/' || c = '\\' then '_' else c) base in
  if Filename.check_suffix safe ".md" then safe else safe ^ ".md"

let write_plan_file_tool : Types.tool_binding =
  let open Types in
  let descriptor =
    { name = "write_plan_file"
    ; description =
        "Write or update your plan file in the .par/plans/ directory. \
         Use this to draft your plan incrementally before calling plan_submit."
    ; input_schema = write_plan_file_input_schema
    ; output_schema = None
    ; permission = Allow
    ; timeout = Some 10.0
    ; concurrency_limit = None
    ; on_update = None
    ; cache_control = None
    }
  in
  let handler json _tok =
    let open Yojson.Safe.Util in
    let filename =
      try sanitize_plan_filename (json |> member "filename" |> to_string)
      with Type_error _ -> ""
    in
    let content =
      try json |> member "content" |> to_string
      with Type_error _ -> ""
    in
    if filename = "" || content = "" then
      Error
        { category = Invalid_input "write_plan_file"
        ; message = "Missing 'filename' or 'content' field"
        ; retryable = false
        ; metadata = []
        }
    else begin
      let plans_dir = ensure_plans_dir () in
      let path = Filename.concat plans_dir filename in
      (try
        let cleaned = Json_extract.strip_think_tags content in
        let oc = open_out path in
        Fun.protect ~finally:(fun () -> close_out oc)
          (fun () -> output_string oc cleaned);
        Success
          (`Assoc [ ("written_to", `String path) ])
      with Sys_error _ ->
        Error
          { category = External_failure "write_plan_file"
          ; message = "Failed to write plan file"
          ; retryable = false
          ; metadata = []
          })
    end
  in
  { descriptor; handler }

(* -- W2: Force-synthesis helpers ------------------------------------------- *)

let string_contains_i ~(haystack : string) ~(needle : string) : bool =
  let h = String.lowercase_ascii haystack in
  let n = String.lowercase_ascii needle in
  let lh = String.length h and ln = String.length n in
  let rec go i =
    if i + ln > lh then false
    else if String.sub h i ln = n then true
    else go (i + 1)
  in
  ln = 0 || go 0

(** [has_six_sections text] returns [true] if [text] contains all six required
    plan section headings (case-insensitive). *)
let has_six_sections (text : string) : bool =
  let sections = [
    "## goal"; "## approach"; "## files to touch";
    "## risks"; "## open questions"; "## steps";
  ] in
  List.for_all (fun sec -> string_contains_i ~haystack:text ~needle:sec) sections

(** [plan_file_written_since ts] returns [true] if any file in [.par/plans/]
    has an mtime ≥ [ts]. *)
let plan_file_written_since (since : float) : bool =
  try
    let plans_dir = ".par/plans" in
    if not (Sys.file_exists plans_dir) then false
    else
      let files = Sys.readdir plans_dir in
      Array.exists (fun f ->
        let path = Filename.concat plans_dir f in
        try (Unix.stat path).Unix.st_mtime >= since
        with Unix.Unix_error _ -> false
      ) files
  with Sys_error _ -> false

(** [persist_text text] writes [text] directly to a new timestamped plan file.
    Returns [Some path] on success, [None] on error. *)
let persist_text (text : string) : string option =
  let text = Json_extract.strip_think_tags text in
  try
    let plans_dir = ensure_plans_dir () in
    let filename = format_timestamp () ^ ".md" in
    let path = Filename.concat plans_dir filename in
    let oc = open_out path in
    Fun.protect ~finally:(fun () -> close_out oc)
      (fun () -> output_string oc text);
    Some path
  with Sys_error _ -> None

(* -- Synthesis (W2 force-fallback) ----------------------------------------- *)

let synthesizer_agent_id = "plan-synthesizer"

let serialize_for_synthesis (conv : Types.conversation) : string =
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
    let len = String.length full in
    if len > 8000 then String.sub full (len - 8000) 8000 else full

let synthesis_prompt =
  "FINAL INSTRUCTION — this overrides everything above, including any pending \
   clarifying question. Do NOT ask questions. Do NOT investigate further. \
   Based on the investigation above, produce the COMPLETE plan NOW. It MUST \
   contain all six sections as markdown headings: ## Goal, ## Approach, ## Files \
   to Touch, ## Risks, ## Open Questions, ## Steps. Output ONLY the plan \
   markdown, nothing else."

(** [try_synthesize_plan rt conv] — single [invoke_generate] call to produce
    a complete plan from the planner's investigation context.
    Returns [Ok text] on success or [Error msg] on failure. *)
let try_synthesize_plan (rt : Runtime.runtime) (conv : Types.conversation)
    : (string, string) result =
  let transcript = serialize_for_synthesis conv in
  if transcript = "" then Error "no conversation context"
  else
    let message = transcript ^ "\n\n---\n\n" ^ synthesis_prompt in
    match Runtime.invoke_generate rt
            ~agent_id:synthesizer_agent_id
            ~save:false ~update_current:false ~message () with
    | Error (e, _) ->
      let msg = match e with
        | Types.Timeout -> "Timeout"
        | Types.Invalid_input s -> Printf.sprintf "Invalid input: %s" s
        | Types.External_failure s -> Printf.sprintf "External failure: %s" s
        | Types.Rate_limited -> "Rate limited"
        | Types.Permission_denied s -> Printf.sprintf "Permission denied: %s" s
        | Types.Internal s -> Printf.sprintf "Internal error: %s" s
        | Types.Embedding_unsupported -> "Embedding unsupported"
      in
      Error msg
    | Ok result ->
      Ok (Json_extract.strip_think_tags result.Types.text)

(* -- Plan file management -------------------------------------------------- *)

type plan_entry = { filename : string; size : int; timestamp : float option }

(** [parse_plan_timestamp filename] extracts a UTC Unix timestamp from a plan
    filename like ["2026-07-27T14-30-00Z.md"].  Returns [None] if the name
    doesn't match the expected format. *)
let parse_plan_timestamp (filename : string) : float option =
  let name =
    if Filename.check_suffix filename ".md" then
      Filename.chop_suffix filename ".md"
    else filename
  in
  try
    Scanf.sscanf name "%04d-%02d-%02dT%02d-%02d-%02dZ"
      (fun year mon day hour min sec ->
        (* Fliegel-Van Flandern algorithm: Gregorian date → Julian Day Number.
           See: https://aa.usno.navy.mil/faq/JD_formula *)
        let y, m =
          if mon <= 2 then (year - 1, mon + 12)
          else (year, mon)
        in
        let a = y / 100 in
        let b = 2 - a + (a / 4) in
        let jdn =
          truncate (365.25 *. float_of_int (y + 4716))
          + truncate (30.6001 *. float_of_int (m + 1))
          + day + b - 1524
        in
        let ts = (float_of_int jdn -. 2440588.0) *. 86400.0
                 +. float_of_int hour *. 3600.0
                 +. float_of_int min *. 60.0
                 +. float_of_int sec
        in
        ts)
    |> Option.some
  with _ -> None

(** [list_plans ~limit] returns up to [limit] plan entries from [.par/plans/],
    sorted newest-first by parsed timestamp.  Returns [Ok []] when the
    directory does not exist. *)
let list_plans ~(limit : int) : (plan_entry list, [> `Plan_error of string]) result =
  try
    let plans_dir = ".par/plans" in
    if not (Sys.file_exists plans_dir) then Ok []
    else
      let files = Sys.readdir plans_dir in
      let entries =
        Array.to_list files
        |> List.filter (fun f -> Filename.check_suffix f ".md")
        |> List.map (fun f ->
          let path = Filename.concat plans_dir f in
          let size = (Unix.stat path).Unix.st_size in
          let timestamp = parse_plan_timestamp f in
          { filename = f; size; timestamp })
        |> List.sort (fun a b ->
          match (a.timestamp, b.timestamp) with
          | Some ta, Some tb -> Float.compare tb ta  (* newest first *)
          | None, Some _ -> 1   (* undated files sort last *)
          | Some _, None -> -1
          | None, None -> 0)
      in
      let rec take n = function
        | [] -> []
        | _ when n <= 0 -> []
        | x :: xs -> x :: take (n - 1) xs
      in
      Ok (take limit entries)
  with
  | Sys_error msg -> Error (`Plan_error msg)
  | exn -> Error (`Plan_error (Printexc.to_string exn))

(** [show_plan filename] reads and returns the content of a plan file.
    Looks in [.par/plans/]; if the name has no [.md] suffix, tries appending it. *)
let show_plan (filename : string) : (string, [> `Plan_error of string]) result =
  try
    let plans_dir = ".par/plans" in
    let path0 = Filename.concat plans_dir filename in
    let path =
      if Sys.file_exists path0 then path0
      else if not (Filename.check_suffix filename ".md") then
        let with_ext = Filename.concat plans_dir (filename ^ ".md") in
        if Sys.file_exists with_ext then with_ext
        else path0  (* will trigger Sys_error below *)
      else path0
    in
    let ic = open_in path in
    Fun.protect ~finally:(fun () -> close_in ic)
      (fun () ->
        let len = in_channel_length ic in
        Ok (really_input_string ic len))
  with
  | Sys_error msg -> Error (`Plan_error msg)
  | exn -> Error (`Plan_error (Printexc.to_string exn))

(** [prune_plans ~older_than_days] deletes plan files whose parsed timestamp is
    more than [older_than_days] days in the past.  Returns the count of deleted
    files.  Files without a parseable timestamp are left untouched. *)
let prune_plans ~(older_than_days : int) : (int, [> `Plan_error of string]) result =
  try
    let plans_dir = ".par/plans" in
    if not (Sys.file_exists plans_dir) then Ok 0
    else
      let now = Unix.gettimeofday () in
      let cutoff = now -. (float_of_int older_than_days *. 86400.0) in
      let files = Sys.readdir plans_dir in
      let count = ref 0 in
      Array.iter (fun f ->
        if Filename.check_suffix f ".md" then
          match parse_plan_timestamp f with
          | Some ts when ts < cutoff ->
            let path = Filename.concat plans_dir f in
            Sys.remove path;
            incr count
          | _ -> ()
      ) files;
      Ok !count
  with
  | Sys_error msg -> Error (`Plan_error msg)
  | exn -> Error (`Plan_error (Printexc.to_string exn))
