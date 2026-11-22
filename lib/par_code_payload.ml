(* par_code_payload.ml — conversation payload hygiene.

 * Two history shapes are rejected by strict providers but can be produced
   locally before a request is sent:
   - a Tool result whose announcing Assistant tool_call has been cut away by
     context truncation ("tool result's tool id ... not found", HTTP 400 2013);
   - a tool_call whose arguments are not a JSON object, typically `null`
     ("invalid params", HTTP 400 2013).

   Both were observed against a live provider on v0.8.0. Sanitizing on the way
   into an invoke (and on the way out of an error or a resumed session) keeps a
   single malformed message from poisoning every later turn. *)

open Par

let normalize_arguments (args : Yojson.Safe.t) : Yojson.Safe.t =
  match args with `Assoc _ -> args | _ -> `Assoc []

let normalize_tool_call (tc : Types.tool_call) : Types.tool_call =
  { tc with Types.arguments = normalize_arguments tc.Types.arguments }

let normalize_message (m : Types.message) : Types.message =
  match m.Types.tool_calls with
  | None -> m
  | Some calls ->
    { m with Types.tool_calls = Some (List.map normalize_tool_call calls) }

(* -------------------------------------------------------------------------- *)
(* Tool result size                                                    *)
(* -------------------------------------------------------------------------- *)

(* v0.15.7: a single grep line can be an entire minified file (or a binary
   blob), and the SDK stores tool results verbatim. One such result grew a
   session to 649 MB, made every retry a 136M-token request, and blocked the
   UI long enough that Esc was never read. The host caps what a tool may hand
   back, the way other terminal agents do. *)
let max_tool_result_chars = 32_768

(* Runtime-tunable copy: the config file can raise or lower the cap without a
   rebuild. [max_tool_result_chars] stays the documented default. *)
let max_chars = ref max_tool_result_chars
let retention_days = ref 7.0
let spill_dir : string option ref = ref None
let max_spill_files = 200
let rng = Random.State.make_self_init ()

let truncation_marker omitted =
  Printf.sprintf "\n… [truncated by par: %d chars omitted]" omitted

let spill_marker total path =
  Printf.sprintf "\n… [truncated by par: %d chars total; full output: %s]" total
    path

let rec mkdir_p dir =
  if dir = "" || dir = "." || dir = Filename.dirname dir then ()
  else if Sys.file_exists dir then ()
  else begin
    mkdir_p (Filename.dirname dir);
    try Unix.mkdir dir 0o700 with Unix.Unix_error (Unix.EEXIST, _, _) -> ()
  end

let prune_spill_dir () =
  match !spill_dir with
  | None -> ()
  | Some dir ->
    let full_dir =
      if Filename.is_relative dir then Filename.concat (Sys.getcwd ()) dir
      else dir
    in
    let is_dir = try Sys.is_directory full_dir with _ -> false in
    if Sys.file_exists full_dir && is_dir then begin
      let files =
        try
          Sys.readdir full_dir |> Array.to_list
          |> List.filter_map (fun name ->
                 let path = Filename.concat full_dir name in
                 try
                   let st = Unix.stat path in
                   if st.Unix.st_kind = Unix.S_REG then
                     Some (path, st.Unix.st_mtime)
                   else None
                 with _ -> None)
        with _ -> []
      in
      let sorted =
        List.sort (fun (_, a) (_, b) -> compare b a) files
      in
      let now = Unix.gettimeofday () in
      List.iteri
        (fun i (path, mtime) ->
          let too_old =
            !retention_days > 0.
            && now -. mtime > !retention_days *. 86400.
          in
          let too_many = !retention_days > 0. && i >= max_spill_files in
          if too_old || too_many then
            try Sys.remove path with _ -> ())
        sorted
    end

(* Writes the full result next to the workspace and returns the path the model
   should read. Failure is silent: the caller falls back to plain truncation. *)
let write_spill ~tool_name (content : string) : string option =
  match !spill_dir with
  | None -> None
  | Some dir ->
    (try
       let full_dir =
         if Filename.is_relative dir then Filename.concat (Sys.getcwd ()) dir
         else dir
       in
       mkdir_p full_dir;
       let safe =
         let b = Buffer.create 24 in
         String.iter
           (fun c ->
             if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
                || (c >= '0' && c <= '9') || c = '_' || c = '-'
             then Buffer.add_char b c
             else Buffer.add_char b '_')
           tool_name;
         let s = Buffer.contents b in
         if String.length s > 24 then String.sub s 0 24 else s
       in
       let name =
         Printf.sprintf "%d-%s-%06x.txt"
           (int_of_float (Unix.gettimeofday () *. 1000.)) safe
           (Random.State.bits rng land 0xffffff)
       in
       let path = Filename.concat full_dir name in
       let tmp = path ^ ".tmp" in
       let oc =
         open_out_gen [ Open_wronly; Open_creat; Open_trunc; Open_binary ] 0o600
           tmp
       in
       (try
          output_string oc content;
          close_out oc
        with e ->
          close_out_noerr oc;
          (try Sys.remove tmp with _ -> ());
          raise e);
       Unix.rename tmp path;
       prune_spill_dir ();
       Some (Filename.concat dir name)
     with _ -> None)

let configure ~max_chars:mc ~retention_days:rd ~spill_dir:dir =
  max_chars := Stdlib.max 1024 mc;
  retention_days := Stdlib.max 0. rd;
  spill_dir := dir;
  prune_spill_dir ()


(* Binary files and control sequences are not text a model or a terminal can
   use; keep only tab/newline/carriage return from C0. *)
let strip_control (s : string) : string =
  let b = Buffer.create (String.length s) in
  String.iter
    (fun c ->
      match c with
      | '\n' | '\r' | '\t' -> Buffer.add_char b c
      | c when Char.code c < 0x20 || Char.code c = 0x7f -> ()
      | c -> Buffer.add_char b c)
    s;
  Buffer.contents b

let cap_text budget (s : string) : string =
  let s = strip_control s in
  let len = String.length s in
  if len <= budget then s
  else begin
    let keep = Stdlib.max 0 (budget - 64) in
    String.sub s 0 keep ^ truncation_marker (len - keep)
  end

let rec cap_json budget (j : Yojson.Safe.t) : Yojson.Safe.t =
  match j with
  | `String s -> `String (cap_text budget s)
  | `List items ->
    let size = function
      | `String s -> String.length s
      | j -> String.length (Yojson.Safe.to_string j)
    in
    let marker =
      Printf.sprintf "\n… [truncated by par: output exceeds %d chars]" budget
    in
    let rec go used acc = function
      | [] -> List.rev acc
      | x :: rest ->
        let left = Stdlib.max 0 (budget - used) in
        (* Recurse even when the item's own size looks small: a JSON object may
           hide a multi-megabyte string inside it. *)
        let x = cap_json left x in
        let used = used + size x + 1 in
        if used >= budget then
          let acc = x :: acc in
          if rest = [] then List.rev acc
          else List.rev (`String marker :: acc)
        else go used (x :: acc) rest
    in
    `List (go 0 [] items)
  | `Assoc fields ->
    `Assoc (List.map (fun (k, v) -> (k, cap_json budget v)) fields)
  | other -> other

let cap_block (b : Types.content_block) : Types.content_block =
  match b with
  | Types.Text_block { text; cache_control } ->
    Types.Text_block
      { text = cap_text !max_chars text; cache_control }
  | Types.Tool_result_block { tool_use_id; content; cache_control } ->
    Types.Tool_result_block
      { tool_use_id
      ; content = cap_text !max_chars content
      ; cache_control }
  | other -> other

let append_json_marker marker (j : Yojson.Safe.t) : Yojson.Safe.t =
  match j with
  | `String s -> `String (s ^ marker)
  | `List items -> `List (items @ [ `String marker ])
  | `Assoc fields -> `Assoc (fields @ [ ("_truncated", `String marker) ])
  | _ -> `String marker

let block_text (b : Types.content_block) : string =
  match b with
  | Types.Text_block { text; _ } -> text
  | Types.Tool_result_block { content; _ } -> content
  | _ -> ""

let cap_handler_result ?(tool_name = "tool")
    (r : Types.handler_result) : Types.handler_result =
  let limit = !max_chars in
  match r with
  | Types.Success j ->
    let raw = Yojson.Safe.to_string j in
    let capped = cap_json limit j in
    if String.length raw > limit then begin
      let marker =
        match write_spill ~tool_name raw with
        | Some path -> Some (spill_marker (String.length raw) path)
        | None -> None
      in
      let appended =
        match marker with
        | Some m -> append_json_marker m capped
        | None -> capped
      in
      (* A structured result with several large fields can still exceed the
         limit even after per-field capping; flatten only in that case. *)
      if String.length (Yojson.Safe.to_string appended) > limit + 512 then
        let fallback =
          match marker with
          | Some m -> m
          | None -> truncation_marker (String.length raw - limit)
        in
        Types.Success (`String (cap_text limit raw ^ fallback))
      else Types.Success appended
    end else Types.Success capped
  | Types.Success_content blocks ->
    let raw =
      String.concat "\n" (List.filter (fun s -> s <> "") (List.map block_text blocks))
    in
    let capped = List.map cap_block blocks in
    if String.length raw > limit then begin
      let marker =
        match write_spill ~tool_name raw with
        | Some path -> spill_marker (String.length raw) path
        | None -> truncation_marker (String.length raw - limit)
      in
      let total =
        List.fold_left (fun n b -> n + String.length (block_text b)) 0 capped
      in
      if total > limit + 512 then
        Types.Success_content
          [ Types.Text_block
              { text = cap_text limit raw ^ marker; cache_control = None } ]
      else
        Types.Success_content
          (capped
           @ [ Types.Text_block { text = marker; cache_control = None } ])
    end else Types.Success_content capped
  | Types.Error { category; message; retryable; metadata } ->
    Types.Error
      { category
      ; message = cap_text 4096 message
      ; retryable
      ; metadata = List.map (fun (k, v) -> (k, cap_json 4096 v)) metadata }
  | (Types.Handoff _ | Types.Approval_required _) as other -> other

let sanitize (conv : Types.conversation) : Types.conversation =
  (* v0.15.3: providers require a tool result to sit immediately after the
     assistant message that announced its call. After an aborted turn the
     conversation can hold a result whose call was pruned or reordered, and the
     whole request is then rejected ("Tool result call_... has no matching
     call"). Pass 1 keeps only adjacent, single-use results; pass 2 drops calls
     that lost their result, so both directions stay consistent. *)
  let pending = ref [] in
  let kept =
    List.filter_map
      (fun (m : Types.message) ->
        match m.Types.role with
        | Types.Assistant ->
          pending :=
            (match m.Types.tool_calls with
             | Some calls ->
               List.filter_map
                 (fun (tc : Types.tool_call) ->
                   if tc.Types.id = "" then None else Some tc.Types.id)
                 calls
             | None -> []);
          Some (normalize_message m)
        | Types.Tool ->
          (match m.Types.tool_call_id with
           | Some id when List.mem id !pending ->
             pending := List.filter (fun x -> x <> id) !pending;
             Some
               { m with
                 Types.content_blocks = List.map cap_block m.Types.content_blocks }
           | _ -> None)
        | Types.System | Types.User ->
          pending := [];
          Some m)
      conv.Types.messages
  in
  let has_result id rest =
    List.exists
      (fun (n : Types.message) ->
        n.Types.role = Types.Tool && n.Types.tool_call_id = Some id)
      rest
  in
  let rec fix = function
    | [] -> []
    | (m : Types.message) :: rest ->
      (match m.Types.role, m.Types.tool_calls with
       | Types.Assistant, Some calls ->
         let live =
           List.filter (fun (tc : Types.tool_call) -> has_result tc.Types.id rest)
             calls
         in
         let m =
           { m with Types.tool_calls = (if live = [] then None else Some live) }
         in
         m :: fix rest
       | _ -> m :: fix rest)
  in
  { conv with Types.messages = fix kept }
