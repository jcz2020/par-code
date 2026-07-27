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

(** Build an [Error] handler result with the given category and message. *)
let tool_error ~category ~message () =
  let open Types in
  Error { category; message; retryable = false; metadata = [] }

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
      (match walk rest with
       | Some _ as result -> result
       | None ->
         if m.Types.role = Types.Assistant then
           let text = extract_text_from_blocks m.Types.content_blocks in
           if text = "" then None else Some text
         else None)
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
    try
      let plans_dir = ensure_plans_dir () in
      let filename = format_timestamp () ^ ".md" in
      let path = Filename.concat plans_dir filename in
      let oc = open_out path in
      Fun.protect ~finally:(fun () -> close_out oc)
        (fun () -> output_string oc text);
      Some path
    with Sys_error _ -> None
