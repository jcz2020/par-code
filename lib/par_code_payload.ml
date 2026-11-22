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

let truncation_marker omitted =
  Printf.sprintf "\n… [truncated by par: %d chars omitted]" omitted

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
    let size = function `String s -> String.length s | _ -> 128 in
    let marker =
      Printf.sprintf "\n… [truncated by par: output exceeds %d chars]" budget
    in
    let rec go used acc = function
      | [] -> List.rev acc
      | x :: rest ->
        let left = Stdlib.max 0 (budget - used) in
        let x = if size x > left then cap_json left x else x in
        let used = used + size x + 1 in
        if used >= budget then List.rev (`String marker :: x :: acc)
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
      { text = cap_text max_tool_result_chars text; cache_control }
  | Types.Tool_result_block { tool_use_id; content; cache_control } ->
    Types.Tool_result_block
      { tool_use_id
      ; content = cap_text max_tool_result_chars content
      ; cache_control }
  | other -> other

let cap_handler_result (r : Types.handler_result) : Types.handler_result =
  match r with
  | Types.Success j -> Types.Success (cap_json max_tool_result_chars j)
  | Types.Success_content blocks -> Types.Success_content (List.map cap_block blocks)
  | Types.Error { category; message; retryable; metadata } ->
    Types.Error
      { category; message = cap_text 4096 message; retryable; metadata }
  | other -> other

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
