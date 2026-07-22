type color =
  | Default
  | Black | Red | Green | Yellow | Blue | Magenta | Cyan | White
  | Bright of color
  | Palette of int
  | Rgb of int * int * int

type style = {
  fg : color option;
  bg : color option;
  bold : bool;
  italic : bool;
  underline : bool;
  dim : bool;
  reverse : bool;
}

type run = R of { sty : style; txt : string }
type image = { lines : run list list; w : int; h : int }

type backend = {
  out : out_channel;
  mutable color : bool option;
  mutable size : (int * int) option;
  mutable markdown_state : Par_code_ui_markdown.state;
}

let no_style = {
  fg = None; bg = None;
  bold = false; italic = false; underline = false;
  dim = false; reverse = false;
}

let style ?fg ?bg ?(bold=false) ?(italic=false) ?(underline=false)
    ?(dim=false) ?(reverse=false) () =
  { fg; bg; bold; italic; underline; dim; reverse }

let empty = { lines = []; w = 0; h = 0 }

let run_width (R { txt; _ }) = String.length txt

let line_width (ln : run list) =
  List.fold_left (fun acc r -> acc + run_width r) 0 ln

let mk lines =
  let h = List.length lines in
  let w = List.fold_left (fun acc ln -> max acc (line_width ln)) 0 lines in
  { lines; w; h }

let text ?(style=no_style) s =
  if s = "" then empty
  else mk [[ R { sty = style; txt = s } ]]

let textf ?(style=no_style) fmt =
  Format.kasprintf (text ~style) fmt

let pad_run left right =
  let l = if left > 0 then [ R { sty = no_style; txt = String.make left ' ' }] else [] in
  let r = if right > 0 then [ R { sty = no_style; txt = String.make right ' ' }] else [] in
  fun ln -> l @ ln @ r

let pad_line w (ln : run list) =
  let lw = line_width ln in
  if lw >= w then ln
  else ln @ [ R { sty = no_style; txt = String.make (w - lw) ' ' } ]

let (<|>) a b =
  if a.h = 0 then b
  else if b.h = 0 then a
  else
    let h = max a.h b.h in
    let al = if a.h < h then a.lines @ List.init (h - a.h) (fun _ -> []) else a.lines in
    let bl = if b.h < h then b.lines @ List.init (h - b.h) (fun _ -> []) else b.lines in
    mk (List.map2 (fun la lb -> la @ lb) al bl)

let (<->) a b =
  if a.h = 0 then b
  else if b.h = 0 then a
  else
    let w = max a.w b.w in
    let al = List.map (pad_line w) a.lines in
    let bl = List.map (pad_line w) b.lines in
    { lines = al @ bl; w; h = a.h + b.h }

let hcat = List.fold_left (<|>) empty
let vcat = List.fold_left (<->) empty

let hpad left right img =
  if img.h = 0 then img
  else mk (List.map (pad_run left right) img.lines)

let vpad top bottom img =
  let blank = [] in
  let tops = List.init top (fun _ -> blank) in
  let bots = List.init bottom (fun _ -> blank) in
  mk (tops @ img.lines @ bots)

let hsnap ?(align=`Left) target img =
  if img.w = target then img
  else if img.w > target then
    let crop_left = match align with
      | `Left -> 0 | `Center -> (img.w - target) / 2 | `Right -> img.w - target
    in
    let crop_line (ln : run list) =
      let rec go pos = function
        | [] -> []
        | (R { txt; _ } as r) :: rest ->
          let len = String.length txt in
          if pos + len <= crop_left then go (pos + len) rest
          else if pos >= crop_left + target then []
          else
            let start = max 0 (crop_left - pos) in
            let stop = min len (crop_left + target - pos) in
            let s' = String.sub txt start (stop - start) in
            if s' = "" then go (pos + len) rest
            else R { sty = (match r with R r -> r.sty); txt = s' } :: go (pos + len) rest
      in
      go 0 ln
    in
    mk (List.map crop_line img.lines)
  else
    let diff = target - img.w in
    let l, r = match align with
      | `Left -> (0, diff) | `Center -> (diff / 2, diff - diff / 2) | `Right -> (diff, 0)
    in
    hpad l r img

let vsnap ?(align=`Top) target img =
  if img.h = target then img
  else if img.h > target then
    let skip = match align with
      | `Top -> 0 | `Middle -> (img.h - target) / 2 | `Bottom -> img.h - target
    in
    let lines = img.lines |> List.to_seq |> Seq.drop skip |> Seq.take target |> List.of_seq in
    mk lines
  else
    let diff = target - img.h in
    let t, b = match align with
      | `Top -> (0, diff) | `Middle -> (diff / 2, diff - diff / 2) | `Bottom -> (diff, 0)
    in
    vpad t b img

let width img = img.w
let height img = img.h

let rec base_code = function
  | Default -> None
  | Black -> Some 0 | Red -> Some 1 | Green -> Some 2 | Yellow -> Some 3
  | Blue -> Some 4 | Magenta -> Some 5 | Cyan -> Some 6 | White -> Some 7
  | Bright c -> Option.map (fun n -> n + 8) (base_code c)
  | Palette n -> Some n
  | Rgb _ -> Some (-1)

let add_fg c buf =
  match base_code c with
  | None -> ()
  | Some (-1) ->
    let (r, g, b) = match c with Rgb (r, g, b) -> (r, g, b) | _ -> (0, 0, 0) in
    Buffer.add_string buf (Printf.sprintf "38;2;%d;%d;%d" r g b)
  | Some n when n <= 7 ->
    Buffer.add_string buf (string_of_int (30 + n))
  | Some n when n <= 15 ->
    Buffer.add_string buf (string_of_int (82 + n))
  | Some n ->
    Buffer.add_string buf (Printf.sprintf "38;5;%d" n)

let add_bg c buf =
  match base_code c with
  | None -> ()
  | Some (-1) ->
    let (r, g, b) = match c with Rgb (r, g, b) -> (r, g, b) | _ -> (0, 0, 0) in
    Buffer.add_string buf (Printf.sprintf "48;2;%d;%d;%d" r g b)
  | Some n when n <= 7 ->
    Buffer.add_string buf (string_of_int (40 + n))
  | Some n when n <= 15 ->
    Buffer.add_string buf (string_of_int (92 + n))
  | Some n ->
    Buffer.add_string buf (Printf.sprintf "48;5;%d" n)

let style_to_sgr s =
  let buf = Buffer.create 16 in
  let first = ref true in
  let add p =
    if !first then first := false else Buffer.add_char buf ';';
    Buffer.add_string buf p
  in
  (match s.fg with Some c -> add_fg c buf; first := false | None -> ());
  (match s.bg with
   | Some c ->
     if not !first then Buffer.add_char buf ';';
     add_bg c buf; first := false
   | None -> ());
  if s.bold then add "1";
  if s.dim then add "2";
  if s.italic then add "3";
  if s.underline then add "4";
  if s.reverse then add "7";
  Buffer.contents buf

let is_noop s =
  s.fg = None && s.bg = None && not s.bold && not s.italic
  && not s.underline && not s.dim && not s.reverse

let flatten ~color img =
  let buf = Buffer.create (img.w * img.h + 16) in
  let first_line = ref true in
  List.iter (fun ln ->
    if !first_line then first_line := false
    else Buffer.add_char buf '\n';
    let prev_s = ref no_style in
    let open_tag = ref false in
    List.iter (fun (R { sty; txt }) ->
      if color then begin
        if sty <> !prev_s then begin
          if !open_tag then Buffer.add_string buf "\027[0m";
          if is_noop sty then open_tag := false
          else begin
            Buffer.add_string buf "\027[";
            Buffer.add_string buf (style_to_sgr sty);
            Buffer.add_char buf 'm';
            open_tag := true
          end;
          prev_s := sty
        end;
        Buffer.add_string buf txt
      end else
        Buffer.add_string buf txt
    ) ln;
    if !open_tag then Buffer.add_string buf "\027[0m"
  ) img.lines;
  Buffer.contents buf

let detect_color () =
  try Unix.isatty Unix.stdout
    && Sys.getenv_opt "NO_COLOR" = None
    && Sys.getenv_opt "TERM" <> Some "dumb"
  with _ -> false

let detect_size () =
  let run cmd =
    try
      let ic = Unix.open_process_in cmd in
      let line = input_line ic in
      ignore (Unix.close_process_in ic);
      Some (String.trim line)
    with _ -> None
  in
  match run "tput cols 2>/dev/null", run "tput lines 2>/dev/null" with
  | Some c, Some r -> (try (int_of_string c, int_of_string r) with _ -> (80, 24))
  | _ -> (80, 24)

let create_backend () =
  { out = stdout; color = None; size = None;
    markdown_state = Par_code_ui_markdown.initial }

let color_of b =
  match b.color with
  | Some v -> v
  | None -> let v = detect_color () in b.color <- Some v; v

let size_of b =
  match b.size with
  | Some s -> s
  | None -> let s = detect_size () in b.size <- Some s; s

let render b img =
  output_string b.out (flatten ~color:(color_of b) img)

let render_line b img =
  render b img;
  output_char b.out '\n';
  flush b.out

let read_line b ~prompt =
  render b prompt;
  flush b.out;
  try Some (input_line stdin) with End_of_file -> None

let get_size b = size_of b
let supports_color b = color_of b
let close _ = ()

(* ── High-level render helpers ──────────────────────────────────────── *)

(* A. Error / Warning / Notice / Success *)

let render_error backend msg =
  render_line backend (textf "✗ %s" msg ~style:(style ~fg:Red ~bold:true ()))

let render_warning backend msg =
  render_line backend (textf "⚠ %s" msg ~style:(style ~fg:Yellow ()))

let render_notice backend msg =
  render_line backend (text msg)

let render_success backend msg =
  render_line backend (textf "✓ %s" msg ~style:(style ~fg:Green ()))

(* B. LLM chunk rendering *)

let flush_markdown backend =
  let final = Par_code_ui_markdown.flush backend.markdown_state in
  if final <> "" then begin
    output_string backend.out final;
    flush backend.out
  end;
  backend.markdown_state <- Par_code_ui_markdown.initial

let render_llm_chunk backend (chunk : Par.Types.llm_response_chunk) =
  match chunk with
  | Text_delta { text } ->
    let new_state, output =
      Par_code_ui_markdown.push backend.markdown_state text
    in
    backend.markdown_state <- new_state;
    if output <> "" then begin
      output_string backend.out output;
      flush backend.out
    end
  | Tool_call_start { tool_call_id = _; name } ->
    render backend (textf "→ %s..." name ~style:(style ~dim:true ()))
  | Tool_call_delta { tool_call_id = _; args_json = _ } ->
    (* Tool args streaming — no-op (could show spinner update) *)
    ()
  | Usage_update _ ->
    (* Token usage update — no-op (could update a live counter) *)
    ()
  | Done { finish_reason = _ } ->
    flush_markdown backend

(* C. Tool event rendering *)

let render_tool_event backend (evt : Par.Types.event) =
  match evt with
  | Tool_invoked _ ->
    (* Tool started — wait for completion to show summary *)
    ()
  | Tool_completed { tool_name; duration_ms; _ } ->
    render_line backend (textf "  → %s ✓ (%.1fms)" tool_name duration_ms
      ~style:(style ~fg:Green ()))
  | Tool_failed { tool_name; _ } ->
    render_line backend (textf "  → %s ✗" tool_name
      ~style:(style ~fg:Red ~bold:true ()))
  | Tool_progress { tool_name; message; _ } ->
    render_line backend (textf "  → %s: %s" tool_name message
      ~style:(style ~dim:true ()))
  | Bash_invoked { argv; risk; _ } ->
    let cmd = String.concat " " argv in
    let risk_style = match risk with
      | "high" | "critical" -> style ~fg:Red ~bold:true ()
      | "medium" -> style ~fg:Yellow ()
      | _ -> style ~fg:Cyan ()
    in
    render_line backend (textf "  $ %s" cmd ~style:risk_style)
  | Bash_completed { exit_code; duration; stdout_truncated; stderr_truncated; _ } ->
    let exit_style = if exit_code = 0
      then style ~fg:Green ()
      else style ~fg:Red ~bold:true ()
    in
    let truncation =
      if stdout_truncated || stderr_truncated then " [output truncated]"
      else ""
    in
    render_line backend
      (textf "  exit %d (%.1fs)%s" exit_code duration truncation ~style:exit_style)
  | Task_created _
  | Task_started _
  | Task_completed _
  | Task_failed _
  | Task_cancelled _
  | Task_suspended _
  | Task_resumed _
  | Llm_request_sent _
  | Llm_response_received _
  | Workflow_started _
  | Workflow_step_completed _
  | Workflow_completed _
  | Workflow_failed _
  | Approval_requested _
  | Approval_granted _
  | Approval_timeout
  | Shutdown_initiated
  | Shutdown_completed _
  | Mcp_server_started _
  | Mcp_server_failed _
  | Mcp_server_stopped _
  | Mcp_tool_invoked _
  | Mcp_tool_completed _
  | Mcp_resource_read _
  | Mcp_prompt_rendered _
  | Agent_handoff _
  | Structured_output_completed _
  | Embedding_request_sent _
  | Embedding_response_received _
  | Retrieval_completed _
  | Provider_fallback_attempted _
  | Llm_response_truncated _
  | Generate_continuation _
  | Context_compressed _
  | Context_compression_skipped _
  | Cache_write _
  | Cache_read _
  | Cache_strategy_skipped _
  | Cache_breakpoint_dropped _
  | Cache_invalidated_by_skill _
  | Deprecated_api_called _ ->
    (* Observability events — no rendering. Could add verbose mode later. *)
    ()

(* D. Cost / Session rendering *)

type cost_summary = {
  llm_calls : int;
  prompt_tokens : int;
  completion_tokens : int;
  total_tokens : int;
  context_tokens : int;
  turn_count : int;
  metrics : (string * int) list;
}

let render_cost backend summary =
  let line label value = textf "  %-20s %s\n" label value in
  let metrics_lines =
    List.map (fun (k, v) -> textf "  %-20s %d\n" k v) summary.metrics
  in
  let image =
    vcat [
      text "Session usage:\n" ~style:(style ~bold:true ());
      line "LLM calls:" (string_of_int summary.llm_calls);
      line "Prompt tokens:" (string_of_int summary.prompt_tokens);
      line "Output tokens:" (string_of_int summary.completion_tokens);
      line "Total tokens:" (string_of_int summary.total_tokens);
      line "Context size:"
        (Printf.sprintf "%d tokens (current)" summary.context_tokens);
      line "Turns completed:" (string_of_int summary.turn_count);
      text "\nOperational metrics:\n" ~style:(style ~bold:true ());
      vcat metrics_lines;
      text "\nNote: excludes async checkpoint/extraction calls.\n"
        ~style:(style ~dim:true ());
    ]
  in
  render backend image

let render_session_info backend ~agent_id ~session_id ~turn_count =
  let image =
    vcat [
      textf "Agent: %s\n" agent_id;
      textf "Session: %s\n" session_id;
      textf "Turns: %d\n" turn_count;
    ]
  in
  render backend image

(* E. Banner / Prompt / Help *)

let render_banner backend ~version =
  render_line backend
    (textf "par %s — type a message, /help for commands." version
       ~style:(style ~bold:true ()))

let render_prompt backend =
  render backend (text "par> " ~style:(style ~fg:Green ~bold:true ()))

let render_help backend =
  let item cmd desc = textf "  %-12s %s\n" cmd desc in
  let image =
    vcat [
      text "Commands:\n" ~style:(style ~bold:true ());
      item "/help" "Show this help";
      item "/session" "Show session info";
      item "/health" "Show runtime health";
      item "/cost" "Show session token usage";
      item "/reset" "Reset conversation";
      item "/checkpoint" "Force a session checkpoint";
      item "/checkpoints" "List session checkpoints";
      item "/quit" "Exit";
    ]
  in
  render backend image

(* F. Table builder *)

let render_table backend ~headers ~rows =
  let widths =
    List.mapi (fun i _ ->
      let cell_lens =
        List.map (fun row ->
          match List.nth_opt row i with
          | Some cell -> String.length cell
          | None -> 0
        ) rows
      in
      let header_len = String.length (List.nth headers i) in
      List.fold_left max header_len cell_lens
    ) headers
  in
  let format_row cells =
    let padded = List.mapi (fun i cell ->
      let w = List.nth widths i in
      let len = String.length cell in
      if len >= w then cell
      else cell ^ String.make (w - len) ' '
    ) cells in
    text (String.concat "  " padded ^ "\n")
  in
  let separator =
    text (String.concat "  "
            (List.map (fun w -> String.make w '-') widths) ^ "\n")
  in
  let header_row = format_row headers in
  let data_rows = List.map format_row rows in
  let image = vcat (header_row :: separator :: data_rows) in
  render backend image
