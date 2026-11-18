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
  think_buf : Buffer.t;
  mutable thinking_start : float option;
  (* v0.14.0 S1b: when set, rendered images go here instead of [out]. The
     screen owns the terminal, so the existing render_* call sites can stay
     untouched while their output lands inside the frame. *)
  sink : (image -> unit) option;
  (* v0.15.1: the half line being streamed. The markdown machine only emits a
     finished line, so without this the frame updated in whole-line bursts. *)
  mutable partial : (string -> unit) option;
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

(* v0.14.0 S1: structured view of an image for the Notty screen. The image
   already carries style per run, so this is a projection, not a re-parse. *)
let lines (img : image) : (string * style) list list =
  List.map
    (fun line -> List.map (fun (R { sty; txt }) -> (txt, sty)) line)
    img.lines

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

let create_backend_out oc =
  { out = oc; color = None; size = None;
    markdown_state = Par_code_ui_markdown.initial;
    think_buf = Buffer.create 256;
    thinking_start = None;
    sink = None;
    partial = None }

(* v0.14.0 S1b: a backend whose output lands in the screen instead of a file.
   Everything that takes [~backend] works unchanged. *)
let create_screen_backend ~sink =
  { out = stdout; color = Some true; size = None;
    markdown_state = Par_code_ui_markdown.initial;
    think_buf = Buffer.create 256;
    thinking_start = None;
    sink = Some sink;
    partial = None }

let create_backend () = create_backend_out stdout

let color_of b =
  match b.color with
  | Some v -> v
  | None -> let v = detect_color () in b.color <- Some v; v

let size_of b =
  match b.size with
  | Some s -> s
  | None -> let s = detect_size () in b.size <- Some s; s

let render b img =
  match b.sink with
  | Some f -> f img
  | None -> output_string b.out (flatten ~color:(color_of b) img)

let render_line b img =
  render b img;
  (match b.sink with
   | Some _ -> ()
   | None ->
     output_char b.out '\n';
     flush b.out)

let read_line b ~prompt =
  (* CLI flows outside the REPL (the config wizard, upgrade prompts) still ask
     one question on stdin; the interactive REPL itself runs inside the screen. *)
  render b prompt;
  flush stdout;
  try
    match input_line stdin with
    | line -> Some (String.trim line)
  with
  | End_of_file -> None
  | Sys.Break -> exit 130

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

(* v0.15.1: a turn stopped by the user is its own terminal state, not a plain
   notice - the same weight as success and failure. *)
let render_cancel backend msg =
  render_line backend (textf "⊘ %s" msg ~style:(style ~fg:Yellow ()))

(* v0.14.0 S2: when the full-screen UI is active, a modal that reads /dev/tty
   must first give the terminal back. The REPL installs these hooks; in line
   mode they stay empty and nothing changes. *)
let modal_hooks :
  (title:string -> body:string list -> options:(string * string) list -> string option)
    option
  ref =
  ref None

let set_modal_hook f = modal_hooks := f

(** Render + FLUSH + read one line from /dev/tty (stdin fallback), for the CLI
    flows that ask a question outside the frame.
    The flush is load-bearing: without it the prompt stays in stdout's
    block buffer while we block on input — the user never sees it. *)
let prompt_read ?(backend=create_backend ()) () =
  flush backend.out;
  let read_tty () =
    try
      let tty = open_in "/dev/tty" in
      Fun.protect ~finally:(fun () -> close_in tty) (fun () -> input_line tty)
    with Sys_error _ -> input_line stdin
  in
  match read_tty () with
  | line -> Some (String.lowercase_ascii (String.trim line))
  | exception _ -> None

(* v0.14.0 W1: the approval question as a small block instead of one long line,
   with the reason spelled out and the meaning of each key next to it. Pure, so
   the wording is unit-tested. *)
let permission_lines ~(command : string) ~(reason : string)
    ~(always_pattern : string) : string list =
  [ Printf.sprintf "⚠ bash wants to run: %s" command;
    Printf.sprintf "   because: %s" reason;
    Printf.sprintf "   [y] run once    [a] always (%s)    [Enter] deny"
      always_pattern ]

let render_permission backend lines =
  match lines with
  | [] -> ()
  | first :: rest ->
    render_line backend
      (text first ~style:(style ~fg:Yellow ~bold:true ()));
    List.iter (fun l -> render_line backend (text l)) rest

(* v0.14.0 S3: a question goes to the in-frame modal when the TUI installed
   one; otherwise it falls back to rendered lines plus the /dev/tty read. *)
let prompt_permission ?(backend=create_backend ()) ~(command : string)
    ~(reason : string) ~(always_pattern : string) () : string option =
  let lines = permission_lines ~command ~reason ~always_pattern in
  match !modal_hooks with
  | Some ask ->
    ask ~title:"bash approval" ~body:lines
      ~options:
        [ ("y", "run once"); ("a", "always " ^ always_pattern);
          ("n", "deny") ]
  | None ->
    render_permission backend lines;
    prompt_read ~backend ()

let prompt_confirm ?(backend=create_backend ()) ?style msg =
  match !modal_hooks with
  | Some ask ->
    ask ~title:"confirm" ~body:[ String.trim msg ]
      ~options:[ ("y", "yes"); ("n", "no") ]
  | None ->
    (match style with
     | Some s -> render backend (text ~style:s msg)
     | None -> render backend (text msg));
    prompt_read ~backend ()

(* B. LLM chunk rendering *)

(* Streaming think-tag strip state machine.
   Buffers incoming chunks and strips [<think>...</think>] and
   [<reasoning>...</reasoning>] blocks incrementally.  Complete blocks
   are removed via [Par.Json_extract.strip_think_tags].  Partial tags
   at the end of the buffer (e.g. [<th] or an unclosed [<think>]) are
   held back until more text resolves them. *)
let strip_think_streaming buf chunk =
  Buffer.add_string buf chunk;
  let content = Buffer.contents buf in
  (* Strip complete closed tags *)
  let stripped = Par.Json_extract.strip_think_tags content in
  let len = String.length stripped in
  (* Check for unclosed opening tags (<think> or <reasoning> without closing) *)
  let rec find_unclosed pos =
    if pos >= len then None
    else if stripped.[pos] = '<' then begin
      let remaining = len - pos in
      if remaining >= 7 && String.sub stripped pos 7 = "<think>"
      then Some pos
      else if remaining >= 11 && String.sub stripped pos 11 = "<reasoning>"
      then Some pos
      else find_unclosed (pos + 1)
    end
    else find_unclosed (pos + 1)
  in
  let safe_len = match find_unclosed 0 with
    | Some pos -> pos
    | None ->
      (* Check if string ends with a partial prefix of an opening tag.
         Prefixes of "<think>" (len 7): 1..7 chars
         Prefixes of "<reasoning>" (len 11): 1..11 chars
         Check longest first to avoid false short matches. *)
      let rec check_prefix plen =
        if plen <= 0 then len
        else if plen > len then check_prefix (plen - 1)
        else begin
          let suffix = String.sub stripped (len - plen) plen in
          let is_think_prefix =
            plen <= 7 && suffix = String.sub "<think>" 0 plen
          in
          let is_reasoning_prefix =
            plen <= 11 && suffix = String.sub "<reasoning>" 0 plen
          in
          if is_think_prefix || is_reasoning_prefix then len - plen
          else check_prefix (plen - 1)
        end
      in
      check_prefix 11
  in
  let to_render = String.sub stripped 0 safe_len in
  let held = String.sub stripped safe_len (len - safe_len) in
  Buffer.clear buf;
  Buffer.add_string buf held;
  to_render

(* v0.14.0 S2 fix: streaming markdown hands back ANSI strings. With a sink
   installed the screen owns the terminal, so those bytes have to become an
   image; writing them to [out] stamped the answer onto the alt screen and the
   next frame erased it. This converts the SGR subset the markdown renderer
   emits (bold/dim/italic/underline/reverse, 8/256/RGB colours) into runs. *)
let ansi_color_of_code = function
  | 30 -> Some Black | 31 -> Some Red | 32 -> Some Green | 33 -> Some Yellow
  | 34 -> Some Blue | 35 -> Some Magenta | 36 -> Some Cyan | 37 -> Some White
  | 90 -> Some (Bright Black) | 91 -> Some (Bright Red)
  | 92 -> Some (Bright Green) | 93 -> Some (Bright Yellow)
  | 94 -> Some (Bright Blue) | 95 -> Some (Bright Magenta)
  | 96 -> Some (Bright Cyan) | 97 -> Some (Bright White)
  | _ -> None

let of_ansi (s : string) : image =
  let lines = ref [] in
  let cur = ref [] in
  let buf = Buffer.create 64 in
  let sty = ref no_style in
  let flush_run () =
    if Buffer.length buf > 0 then begin
      cur := R { sty = !sty; txt = Buffer.contents buf } :: !cur;
      Buffer.clear buf
    end
  in
  let end_line () =
    flush_run ();
    lines := List.rev !cur :: !lines;
    cur := []
  in
  let apply params =
    flush_run ();
    let rec go = function
      | [] -> ()
      | 0 :: tl -> sty := no_style; go tl
      | 1 :: tl -> sty := { !sty with bold = true }; go tl
      | 2 :: tl -> sty := { !sty with dim = true }; go tl
      | 3 :: tl -> sty := { !sty with italic = true }; go tl
      | 4 :: tl -> sty := { !sty with underline = true }; go tl
      | 7 :: tl -> sty := { !sty with reverse = true }; go tl
      | 22 :: tl -> sty := { !sty with bold = false; dim = false }; go tl
      | 23 :: tl -> sty := { !sty with italic = false }; go tl
      | 24 :: tl -> sty := { !sty with underline = false }; go tl
      | 27 :: tl -> sty := { !sty with reverse = false }; go tl
      | 39 :: tl -> sty := { !sty with fg = None }; go tl
      | 49 :: tl -> sty := { !sty with bg = None }; go tl
      | 38 :: 5 :: n :: tl -> sty := { !sty with fg = Some (Palette n) }; go tl
      | 48 :: 5 :: n :: tl -> sty := { !sty with bg = Some (Palette n) }; go tl
      | 38 :: 2 :: r :: g :: b :: tl ->
        sty := { !sty with fg = Some (Rgb (r, g, b)) }; go tl
      | 48 :: 2 :: r :: g :: b :: tl ->
        sty := { !sty with bg = Some (Rgb (r, g, b)) }; go tl
      | c :: tl when c >= 30 && c <= 37 ->
        (match ansi_color_of_code c with
         | Some col -> sty := { !sty with fg = Some col }
         | None -> ());
        go tl
      | c :: tl when c >= 40 && c <= 47 ->
        (match ansi_color_of_code (c - 10) with
         | Some col -> sty := { !sty with bg = Some col }
         | None -> ());
        go tl
      | c :: tl when c >= 90 && c <= 97 ->
        (match ansi_color_of_code c with
         | Some col -> sty := { !sty with fg = Some col }
         | None -> ());
        go tl
      | c :: tl when c >= 100 && c <= 107 ->
        (match ansi_color_of_code (c - 60) with
         | Some col -> sty := { !sty with bg = Some col }
         | None -> ());
        go tl
      | _ :: tl -> go tl
    in
    go params
  in
  let n = String.length s in
  let i = ref 0 in
  while !i < n do
    let c = s.[!i] in
    if c = '\n' then begin end_line (); incr i end
    else if c = '\r' then incr i
    else if c = '\027' && !i + 1 < n && s.[!i + 1] = '[' then begin
      let j = ref (!i + 2) in
      while !j < n
            && not (let ch = s.[!j] in
                    (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z')) do
        incr j
      done;
      if !j >= n then i := n
      else begin
        if s.[!j] = 'm' then begin
          let body = String.sub s (!i + 2) (!j - !i - 2) in
          let params =
            if body = "" then [0]
            else
              String.split_on_char ';' body
              |> List.filter_map int_of_string_opt
          in
          apply params
        end;
        i := !j + 1
      end
    end
    else begin Buffer.add_char buf c; incr i end
  done;
  if Buffer.length buf > 0 || !cur <> [] then end_line ();
  mk (List.rev !lines)

(* Route renderer text to the sink when one exists, so the screen owns every
   byte that reaches the terminal. *)
(** v0.15.1: tell whoever draws the frame what the unfinished line looks like
    right now (empty string clears it). *)
let publish_partial backend =
  match backend.partial with
  | None -> ()
  | Some f -> f (Par_code_ui_markdown.pending_text backend.markdown_state)

let set_partial_sink backend f = backend.partial <- Some f

(* v0.15.1 visual pass 2: consecutive tool lines of one turn are collected by
   the screen and folded into a single block, so a 20-call turn does not push
   the answer off the frame. When no hook is installed (plain output) they are
   rendered one per line as before. *)
let tool_line_hook : (image -> unit) option ref = ref None
let tool_flush_hook : (unit -> unit) option ref = ref None

let set_tool_hooks ~line ~flush =
  tool_line_hook := Some line;
  tool_flush_hook := Some flush

let flush_tool_block () =
  match !tool_flush_hook with Some f -> f () | None -> ()

let emit_markdown backend s =
  if s <> "" then flush_tool_block ();
  if s <> "" then begin
    match backend.sink with
    | Some f -> f (of_ansi s)
    | None -> output_string backend.out s; flush backend.out
  end;
  publish_partial backend

let flush_markdown backend =
  (match backend.thinking_start with
   | Some _ -> backend.thinking_start <- None
   | None -> ());
  let leftover = Buffer.contents backend.think_buf in
  Buffer.clear backend.think_buf;
  if leftover <> "" then begin
    let stripped = Par.Json_extract.strip_think_tags leftover in
    let len = String.length stripped in
    let rec find_unclosed pos =
      if pos >= len then stripped
      else if stripped.[pos] = '<' then begin
        let r = len - pos in
        if (r >= 7 && String.sub stripped pos 7 = "<think>")
           || (r >= 11 && String.sub stripped pos 11 = "<reasoning>")
        then String.sub stripped 0 pos
        else find_unclosed (pos + 1)
      end
      else find_unclosed (pos + 1)
    in
    let safe = find_unclosed 0 in
    if safe <> "" then begin
      let new_state, output =
        Par_code_ui_markdown.push backend.markdown_state safe
      in
      backend.markdown_state <- new_state;
      emit_markdown backend output;
    end
  end;
  let final = Par_code_ui_markdown.flush backend.markdown_state in
  emit_markdown backend final;
  backend.markdown_state <- Par_code_ui_markdown.initial;
  (* v0.15.1: [flush] renders the leftover line without clearing it, so the
     frame would keep showing it under the committed copy. *)
  (match backend.partial with Some f -> f "" | None -> ())

(* A status/tool line must not be appended to a half-rendered markdown line.
   [push "\n"] renders the pending line and keeps the code-block context, so
   text that was streamed before the tool call appears before the tool line
   instead of being glued to the next chunk ("now.Now running"). *)
let flush_pending_line backend =
  if Par_code_ui_markdown.has_pending backend.markdown_state then begin
    let new_state, output =
      Par_code_ui_markdown.push backend.markdown_state "\n"
    in
    backend.markdown_state <- new_state;
    emit_markdown backend output
  end

let render_event_line backend img =
  flush_pending_line backend;
  match !tool_line_hook with
  | Some f -> f img
  | None -> render_line backend img

let render_llm_chunk backend (chunk : Par.Types.llm_response_chunk) =
  let close_thinking_window () =
    match backend.thinking_start with
    | Some t0 ->
      let elapsed = int_of_float (Unix.gettimeofday () -. t0) in
      backend.thinking_start <- None;
      render backend (textf "✻ thinking · %ds" elapsed ~style:(style ~dim:true ()));
      render backend (text "\n");
      flush backend.out
    | None -> ()
  in
  match chunk with
  | Reasoning_delta _ ->
    if backend.thinking_start = None then
      backend.thinking_start <- Some (Unix.gettimeofday ())
  | Reasoning_signature _ ->
    (* Anthropic sends the thinking signature as its own delta; nothing to
       render, and the caller's conversation keeps it verbatim. *)
    ()
  | Text_delta { text } ->
    close_thinking_window ();
    let safe_text = strip_think_streaming backend.think_buf text in
    if safe_text <> "" then begin
      let new_state, output =
        Par_code_ui_markdown.push backend.markdown_state safe_text
      in
      backend.markdown_state <- new_state;
      emit_markdown backend output;
    end
  | Tool_call_start { tool_call_id = _; name } ->
    close_thinking_window ();
    render_event_line backend
      (textf "  → %s" name ~style:(style ~dim:true ()))
  | Tool_call_delta _ ->
    close_thinking_window ()
  | Usage_update _ ->
    close_thinking_window ()
  | Done { finish_reason = _ } ->
    close_thinking_window ();
    flush_markdown backend

(* C. Tool event rendering *)

let render_tool_event backend (evt : Par.Types.event) =
  match evt with
  | Tool_invoked _ ->
    (* Tool started — wait for completion to show summary, but make sure any
       streamed text that preceded the tool call is not left buffered. *)
    flush_pending_line backend
  | Tool_completed { tool_name; duration_ms; _ } ->
    render_event_line backend (textf "  ✓ %s (%.1fms)" tool_name duration_ms
      ~style:(style ~fg:Green ~dim:true ()))
  | Tool_failed { tool_name; _ } ->
    render_event_line backend (textf "  ✗ %s" tool_name
      ~style:(style ~fg:Red ~bold:true ()))
  | Tool_progress { tool_name; message; _ } ->
    render_event_line backend (textf "  → %s: %s" tool_name message
      ~style:(style ~dim:true ()))
  | Bash_invoked { argv; risk; _ } ->
    let cmd = String.concat " " argv in
    let risk_style = match risk with
      | "high" | "critical" -> style ~fg:Red ~bold:true ()
      | "medium" -> style ~fg:Yellow ()
      | _ -> style ~fg:Cyan ()
    in
    render_event_line backend (textf "  $ %s" cmd ~style:risk_style)
  | Bash_completed { exit_code; duration; stdout_truncated; stderr_truncated; _ } ->
    let exit_style = if exit_code = 0
      then style ~fg:Green ()
      else style ~fg:Red ~bold:true ()
    in
    let truncation =
      if stdout_truncated || stderr_truncated then " [output truncated]"
      else ""
    in
    render_event_line backend
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
  | _ ->
    (* Observability / approval / MCP / workflow events — no rendering. New SDK
       events land here by default; add an explicit case when one deserves a
       line. *)
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
  let line label value = textf "  %-20s %s" label value in
  let metrics_lines =
    List.map (fun (k, v) -> textf "  %-20s %d" k v) summary.metrics
  in
  let image =
    vcat [
      text "Session usage:" ~style:(style ~bold:true ());
      line "LLM calls:" (string_of_int summary.llm_calls);
      line "Prompt tokens:" (string_of_int summary.prompt_tokens);
      line "Output tokens:" (string_of_int summary.completion_tokens);
      line "Total tokens:" (string_of_int summary.total_tokens);
      line "Context size:"
        (Printf.sprintf "%d tokens (current)" summary.context_tokens);
      line "Turns completed:" (string_of_int summary.turn_count);
      vpad 1 0 (text "Operational metrics:" ~style:(style ~bold:true ()));
      vcat metrics_lines;
      vpad 1 0 (text "Note: excludes async checkpoint/extraction calls."
        ~style:(style ~dim:true ()));
    ]
  in
  render_line backend image

let render_session_info backend ~agent_id ~session_id ~turn_count ~message_count =
  let image =
    vcat [
      textf "%-10s %s" "Agent:" agent_id;
      textf "%-10s %s" "Session:" session_id;
      textf "%-10s %d" "Turns:" turn_count;
      textf "%-10s %d" "Messages:" message_count;
    ]
  in
  render_line backend image

(* D2. Delegation rendering *)

let render_delegation_start backend ~agent_type ~task =
  let label = match agent_type with
    | "explore" -> "[delegate:explore]"
    | "general" -> "[delegate:general]"
    | other -> Printf.sprintf "[delegate:%s]" other
  in
  render backend (textf "%s %s\n" label task ~style:(style ~fg:Cyan ()))

let render_delegation_tool_event backend ~agent_type (evt : Par.Types.event) =
  let label = match agent_type with
    | "explore" -> "[explore]"
    | "general" -> "[general]"
    | other -> Printf.sprintf "[%s]" other
  in
   (match evt with
    | Tool_invoked { tool_name; _ } ->
      render backend (textf "  %s → %s...\n" label tool_name ~style:(style ~dim:true ()))
    | Tool_completed { tool_name; duration_ms; _ } ->
      render backend (textf "  %s ✓ %s (%.1fms)\n" label tool_name duration_ms
                        ~style:(style ~dim:true ()))
    | Tool_failed { tool_name; _ } ->
      render backend (textf "  %s ✗ %s\n" label tool_name
                        ~style:(style ~fg:Red ~dim:true ()))
    | Bash_invoked { argv; _ } ->
      let cmd = match argv with h :: _ -> h | [] -> "?" in
      render backend (textf "  %s $ %s...\n" label cmd ~style:(style ~fg:Yellow ~dim:true ()))
    | Bash_completed { exit_code; _ } ->
      let mark = if exit_code = 0 then "✓" else "✗" in
      render backend (textf "  %s %s bash (exit %d)\n" label mark exit_code
                        ~style:(style ~dim:true ()))
    | _ -> ())

let truncate_utf8 s max_bytes =
  let len = String.length s in
  if len <= max_bytes then s
  else begin
    let k = ref max_bytes in
    while !k > 0 && Char.code s.[!k] land 0xC0 = 0x80 do decr k done;
    let prefix_len =
      if !k = 0 then 0
      else if Char.code s.[!k] >= 0xC0 then !k
      else max_bytes
    in
    String.sub s 0 prefix_len
  end

let render_delegation_result backend ~agent_type ~text:txt =
  let label = match agent_type with
    | "explore" -> "[explore]"
    | "general" -> "[general]"
    | other -> Printf.sprintf "[%s]" other
  in
  let preview = if String.length txt > 500 then
    truncate_utf8 txt 500 ^ "\n... (truncated)"
  else txt in
  render backend (vcat [
    textf "  %s ✓ complete\n" label ~style:(style ~fg:Green ~dim:true ());
    text preview ~style:(style ~dim:true ());
  ])

let render_delegation_error backend ~agent_type ~error =
  let label = match agent_type with
    | "explore" -> "[explore]"
    | "general" -> "[general]"
    | other -> Printf.sprintf "[%s]" other
  in
  render backend (textf "  %s ✗ failed: %s\n" label error ~style:(style ~fg:Red ~dim:true ()))

(* E. Banner / Prompt / Help *)

let render_banner backend ~version =
  render_line backend
    (textf "par %s — type a message, /help for commands." version
       ~style:(style ~bold:true ()))

let render_prompt backend mode =
  let prefix = match mode with
    | Par_code_mode.Plan -> "(plan) "
    | Par_code_mode.Build -> "(build) "
  in
  render backend (text (prefix ^ "par> ") ~style:(style ~fg:Green ~bold:true ()));
  (* Flush so the prompt is visible before [input_line stdin] blocks.
     stdout is line-buffered on a pty; without this the prompt stays
     buffered until the next \n. See v0.5.4 audit P1 #8. *)
  flush backend.out

(* Colored prompt banner, used by CLI flows (the REPL draws its own input line
   in the frame). *)
let commands : (string * string) list =
  [ ("/help", "Show this help");
    ("/session", "Show session info");
    ("/health", "Show runtime health");
    ("/model", "Switch the model for this session");
    ("/sessions", "Pick a saved session to continue");
    ("/cost", "Show session token usage");
    ("/plan", "Switch to plan mode (read-only; produces a plan file)");
    ("/build", "Switch to build mode (full tool access; saves current plan)");
    ("/goal", "Set a goal for the agent (judge verifies completion)");
    ("/max", "Best-of-N: run N candidate answers, keep the best (on|off|2-5)");
    ("/skills", "List custom skills (reload: /skills reload)");
    ("/distill", "Turn a repeated workflow into a skill (--id/--user/--force)");
    ("/resume", "Continue an interrupted run (/resume <id> | /resume discard)");
    ("/flow", "Run a file-defined workflow (/flow run|status|cancel|resume)");
    ("/mcp", "List the MCP servers and the tools they expose");
    ("/undo", "Restore the workspace to an earlier snapshot (/undo [n])");
    ("/snapshots", "List recent workspace snapshots");
    ("/reset", "Reset conversation");
    ("/checkpoint", "Force a session checkpoint");
    ("/checkpoints", "List session checkpoints");
    ("/quit", "Exit") ]

let command_description cmd =
  match List.assoc_opt cmd commands with Some d -> Some d | None -> None

let render_help backend =
  let item cmd desc = textf "  %-14s %s" cmd desc in
  let image =
    vcat
      ((text "Commands:" ~style:(style ~bold:true ()))
       :: List.map (fun (cmd, desc) -> item cmd desc) commands
       @ [ empty;
           text "Keys:" ~style:(style ~bold:true ());
           item "Enter" "send the message";
           item "Alt+Enter" "add a line (or finish a line with \\)";
           item "Tab" "complete a command or flow id";
           item "Esc" "clear the line";
           item "Ctrl-C" "clear the line; press twice to exit";
           item "Ctrl-Left/Right" "move by word (Alt+Backspace deletes one)";
           item "Ctrl-R" "search the prompt history backwards";
           item "!command" "run a command directly (no model round-trip)";
           item "PgUp/PgDn" "scroll the transcript (wheel works too)" ])
  in
  render_line backend image

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
    text (String.concat "  " padded)
  in
  let separator =
    text (String.concat "  "
            (List.map (fun w -> String.make w '-') widths))
  in
  let header_row = format_row headers in
  let data_rows = List.map format_row rows in
  let image = vcat (header_row :: separator :: data_rows) in
  render_line backend image
