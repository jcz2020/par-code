(* v0.14.0 S1 — the Notty screen: alt-screen frame, scrollback, status line.

   One thread owns the terminal. The loop polls the read fd (see S0: [pending]
   alone never sees raw bytes), renders a frame, and sleeps briefly; anything
   else — agent turns, streaming callbacks — only appends to the transcript and
   the next frame picks it up. *)

(* ------------------------------------------------------------------ *)
(* Style bridge                                                        *)
(* ------------------------------------------------------------------ *)

let rec color_of (c : Par_code_ui.color) : Notty.A.color option =
  let open Notty.A in
  match c with
  | Par_code_ui.Default -> None
  | Black -> Some black
  | Red -> Some red
  | Green -> Some green
  | Yellow -> Some yellow
  | Blue -> Some blue
  | Magenta -> Some magenta
  | Cyan -> Some cyan
  | White -> Some white
  | Bright Black -> Some lightblack
  | Bright Red -> Some lightred
  | Bright Green -> Some lightgreen
  | Bright Yellow -> Some lightyellow
  | Bright Blue -> Some lightblue
  | Bright Magenta -> Some lightmagenta
  | Bright Cyan -> Some lightcyan
  | Bright White -> Some lightwhite
  | Bright (Palette n) | Palette n -> Some (gray n)
  | Bright (Rgb _) | Rgb _ -> None
  | Bright c -> color_of c

let rgb_of (c : Par_code_ui.color) : (int * int * int) option =
  match c with
  | Par_code_ui.Rgb (r, g, b) | Par_code_ui.Bright (Rgb (r, g, b)) -> Some (r, g, b)
  | _ -> None

let attr_of_style (s : Par_code_ui.style) : Notty.A.t =
  let open Notty.A in
  let color_attr (mk : color -> t) (c : Par_code_ui.color) : t =
    match rgb_of c with
    | Some (r, g, b) -> mk (rgb_888 ~r ~g ~b)
    | None -> (match color_of c with Some c -> mk c | None -> empty)
  in
  let fg_attr =
    match s.Par_code_ui.fg with
    | Some c -> color_attr (fun c -> fg c) c
    | None -> empty
  in
  let bg_attr =
    match s.Par_code_ui.bg with
    | Some c -> color_attr (fun c -> bg c) c
    | None -> empty
  in
  let style_attr =
    let acc = empty in
    let acc = if s.Par_code_ui.bold then acc ++ st bold else acc in
    let acc = if s.Par_code_ui.italic then acc ++ st italic else acc in
    let acc = if s.Par_code_ui.underline then acc ++ st underline else acc in
    let acc = if s.Par_code_ui.reverse then acc ++ st reverse else acc in
    acc
  in
  (* v0.15.1: notty has no dim attribute, so a muted style used to render as
     ordinary text and tool lines lost their layer. Map it to a grey
     foreground instead: readable on light and dark terminals alike. *)
  let dim_attr =
    if s.Par_code_ui.dim && s.Par_code_ui.fg = None then fg lightblack else empty
  in
  fg_attr ++ bg_attr ++ dim_attr ++ style_attr

(* ------------------------------------------------------------------ *)
(* Screen state                                                        *)
(* ------------------------------------------------------------------ *)

type modal = {
  title : string;
  body : (string * Par_code_ui.style) list;
  options : (string * string) list;  (* key, label *)
}

(* v0.15.1: model picker — a list that scrolls, unlike a modal's one-key choice. *)
type picker = {
  p_title : string;
  p_items : string list;
  mutable p_index : int;
  mutable p_answer : string option;
}

type search = {
  mutable s_query : string;
  mutable s_index : int;
  s_saved : string;   (* input restored on Esc *)
  s_cursor : int;
}

(* v0.15.4: an entry keeps the SOURCE image and renders at the width in use,
   so changing the font size re-flows the transcript instead of clipping it.
   The rendered result is cached per column count. *)
type render_cache = {
  mutable rc_cols : int;
  (* v0.15.6: cache styled runs rather than images. The frame converts only
     the visible slice to notty images, and a mouse selection has to rewrite
     the runs of the selected cells before that. *)
  mutable rc_runs : (string * Par_code_ui.style) list list;
}

type entry =
  | Line of Par_code_ui.image * render_cache
  | Capped of Par_code_ui.image * render_cache
  | Tools of tool_block

and tool_block = {
  bx_imgs : Par_code_ui.image list;
  mutable bx_expanded : bool;
}

type t = {
  term : Notty_unix.Term.t;
  (* Oldest first. A turn's tool lines travel as one foldable entry so Ctrl-O
     can bring the hidden ones back without rebuilding the transcript. *)
  mutable transcript : entry list;
  mutable partial : string;               (* line being streamed *)
  (* v0.15.1: tool lines of the current turn, folded into one block when the
     answer arrives so a long tool sequence does not bury it. Each row carries
     the task id of the call that produced it (v0.15.4), so a parallel batch
     can replace its own row instead of the last one. *)
  mutable tool_block : (string * Par_code_ui.image) list;
  (* Name of the tool currently running, for the activity line. *)
  mutable activity : string;

  (* v0.15.3: the frame gains a title line and a composer that says which mode
     it is in. Both are set by the REPL; an empty string keeps the row out, so a
     tiny terminal loses no space. *)
  mutable header : string;
  mutable composer_label : string;
  mutable status : string;
  mutable scroll : int;                   (* lines up from the bottom *)
  (* v0.15.2: last pointer position while dragging, so a swipe scrolls.
     Termux reports a touch drag as a mouse drag once motion tracking is on,
     which notty enables with 1002/1006 in its mouse mode. *)
  mutable drag_y : int option;
  mutable running : bool;
  mutable last_key : string;
  (* v0.14.0 S2: the input line. *)
  mutable input : string;
  mutable cursor : int;                   (* byte offset into [input] *)
  mutable prompt : string;
  mutable history : string list;          (* newest first *)
  (* v0.15.1: where the history is persisted (set by [load_history]). *)
  mutable history_path : string option;
  mutable hist_pos : int option;
  mutable submitted : string option;
  mutable editing : bool;          (* keys go to the input line *)
  mutable last_ctrl_c : float option;
  (* A terminal can deliver an escape sequence in several writes; when notty
     has already turned the leading ESC into a key, the rest arrives as text
     ([<65;83;39M for a mouse wheel). These two fields let the key handler
     swallow that tail instead of typing it into the input line. *)
  mutable escape_at : float option;
  mutable csi_drop : bool;
  mutable modal : modal option;
  mutable modal_answer : string option;
  (* v0.15.7: a Ctrl-C inside a modal denies the tool and asks the turn's
     ticker to cancel the whole turn; the ticker consumes it. *)
  mutable cancel_requested : bool;
  (* v0.15.1: a scrollable list picker (model selection). *)
  mutable picker : picker option;
  (* v0.15: a live "working" line while the model runs; set from the REPL's
     ticker fiber so the frame keeps moving when no chunks arrive. *)
  mutable busy : string;
  (* v0.15.1: slash-command menu while the input starts with a command. *)
  mutable menu : (string * string) list;
  mutable menu_index : int;
  mutable files : string list option;
  (* Byte span of the @token the file menu is completing. *)
  mutable menu_token : (int * int) option;
  (* Set after accepting or dismissing the menu, so the refresh at the end of
     the same keypress does not reopen it. *)
  mutable menu_suppress : bool;
  (* v0.15.1: Ctrl-R reverse search over the prompt history. *)
  mutable search : search option;
  (* v0.15.6: mouse selection over the transcript. Points are (absolute
     transcript line, display column). [view] is the slice the last frame
     painted, so a mouse row can be turned into a transcript line. *)
  mutable sel :
    (Par_code_selection.point * Par_code_selection.point) option;
  mutable select_mode : bool;
  mutable selecting : bool;
  mutable view : (int * int * int) option;
  (* v0.15.6: a turn is running inside [invoke]. Typing is allowed then; Enter
     queues the line, which is shown above the composer and delivered to the
     runtime as soon as the next tool boundary (or the end of the turn) comes. *)
  mutable turn_active : bool;
  mutable queued : string list;
  (* v0.15.4: the last frame we actually painted. The idle loop wakes every
     50ms; repainting an unchanged frame made the TUI flicker on a phone, so a
     render only happens when this signature changes. *)
  mutable last_sig : string;
  (* v0.15.7: previous frame's line count and body height, used to keep a
     scrolled-up viewport on the same transcript line while a stream or a
     resize changes the frame around it. *)
  mutable last_total : int;
  mutable last_body_h : int;
  (* Terminal attributes as they were before notty took the tty. A signal
     handler cannot safely call into notty (it can deadlock on a lock the
     interrupted code holds), so the cleanup path restores from here. *)
  saved_tty : Unix.terminal_io option;
}

let create () : t =
  let saved_tty =
    try Some (Unix.tcgetattr Unix.stdin) with Unix.Unix_error _ -> None
  in
  { term = Notty_unix.Term.create ~mouse:true ~bpaste:true ();
    saved_tty;
    transcript = [];
    partial = "";
    tool_block = [];
    activity = "";
    header = "";
    composer_label = "";
    status = "";
    scroll = 0;
    drag_y = None;
    running = true;
    last_key = "";
    escape_at = None;
    csi_drop = false;
    input = "";
    cursor = 0;
    prompt = "> ";
    history = [];
    history_path = None;
    hist_pos = None;
    submitted = None;
    editing = false;
    last_ctrl_c = None;
    modal = None;
    modal_answer = None;
    cancel_requested = false;
    picker = None;
    busy = "";
    menu = [];
    menu_index = 0;
    files = None;
    menu_token = None;
    menu_suppress = false;
    search = None;
    sel = None;
    select_mode = false;
    selecting = false;
    view = None;
    turn_active = false;
    queued = [];
    last_sig = "";
    last_total = 0;
    last_body_h = 0 }

(* Notty rejects control characters inside [I.string] (it raises on "\n"),
   and model output is full of them. Split runs on newlines into separate lines
   and drop the rest, so a multi-line run can never take the frame down. *)
let sanitize_text (s : string) : string =
  let b = Buffer.create (String.length s) in
  String.iter
    (fun c ->
       match c with
       | '\t' -> Buffer.add_string b "    "
       | '\r' -> ()
       | c when Char.code c < 0x20 || Char.code c = 0x7f -> ()
       | c -> Buffer.add_char b c)
    s;
  Buffer.contents b

(** One-line preview of a queued prompt for the dock. *)
let preview_text (s : string) : string =
  let s =
    match String.index_opt s '\n' with
    | Some i -> String.sub s 0 i
    | None -> s
  in
  if String.length s > 48 then String.sub s 0 47 ^ "…" else s

let split_runs (runs : (string * Par_code_ui.style) list) :
    (string * Par_code_ui.style) list list =
  let lines = ref [] in
  let current = ref [] in
  let flush () =
    lines := List.rev !current :: !lines;
    current := []
  in
  List.iter
    (fun (text, sty) ->
       let parts = String.split_on_char '\n' text in
       List.iteri
         (fun i part ->
            if i > 0 then flush ();
            let part = sanitize_text part in
            if part <> "" then current := (part, sty) :: !current)
         parts)
    runs;
  flush ();
  List.rev !lines

(* v0.14.1: notty clips a string at the frame edge, which cut answers
   mid-sentence on narrow terminals (a phone is 40–60 columns). Wrap here, with
   CJK/emoji widths from uucp. Wrapping happens when text enters the transcript,
   so a resize does not re-flow what is already on screen. *)
(* Display width and string width live in one place so the selection and the
   wrapper cannot disagree about where a column is. *)
let display_width = Par_code_selection.width_of
let text_width = Par_code_selection.text_width

(** v0.15.7: the right edge of the status bar. A modal owns Esc, so the turn
    hint must not promise that Esc interrupts the run. *)
let status_right_hint ~modal_open ~busy ~turn_active ~has_input ~left_w ~width =
  let rec pick = function
    | [] -> ""
    | s :: tl -> if left_w + text_width s + 2 <= width then s else pick tl
  in
  if modal_open then pick [ "esc deny \xc2\xb7 ctrl-c cancel "; "esc deny " ]
  else if busy = "" then ""
  else
    let wanted =
      if turn_active && has_input then
        [ "enter queue \xc2\xb7 esc interrupt "; "esc interrupt " ]
      else [ "esc interrupt " ]
    in
    pick wanted

(* v0.15.5: wrap on word boundaries. The old folder broke at whichever
   codepoint crossed the limit, so an English word lost its tail to the next
   row, and a list item's continuation row started back at the gutter instead
   of under its text. Tokens are whitespace / non-whitespace runs; a row breaks
   before a token that does not fit, and a token longer than the row (a path, a
   URL, a run of CJK with no spaces) is hard-split as before. *)
let is_wrap_space c = c = ' ' || c = '\t'

(* A run that STARTS in CJK can break between any two characters, so it may
   fill the rest of the current row. A Latin word may not: it moves whole to
   the next row unless it is longer than a row by itself. Checking the first
   character (not "contains CJK") keeps mixed tokens like "x86_64/arm64"
   intact — they are words with a closing punctuation mark on the end. *)
let starts_with_cjk (s : string) : bool =
  if s = "" then false
  else
    let d = Uutf.decoder ~encoding:`UTF_8 (`String s) in
    match Uutf.decode d with
    | `Uchar u ->
      let c = Uchar.to_int u in
      (c >= 0x2E80 && c <= 0x9FFF) || (c >= 0xF900 && c <= 0xFAFF)
      || (c >= 0xFE30 && c <= 0xFE4F) || (c >= 0xFF00 && c <= 0xFFEF)
    | `Malformed _ | `End | `Await -> false

(* Closing punctuation that must not open a row (Chinese typesetting keeps it
   with the character before it; the ASCII set catches the same shape inside a
   long URL or path). *)
let is_no_start_char (u : Uchar.t) : bool =
  match Uchar.to_int u with
  | 0x3002 | 0xFF0C | 0x3001 | 0xFF1B | 0xFF1A | 0xFF1F | 0xFF01 | 0xFF09
  | 0x3011 | 0x300B | 0x300D | 0x300F | 0x201D | 0x2019 -> true
  | c -> c = 0x2C || c = 0x2E || c = 0x3B || c = 0x3A || c = 0x3F || c = 0x21
         || c = 0x29 || c = 0x5D || c = 0x7D || c = 0x25

let space_run (s : string) : bool =
  s <> "" && String.for_all is_wrap_space s

(* Where a list item's text starts ("  - ", "  1. "), so wrapped rows line up
   under it. Only a real list marker counts; tool and code rows keep a plain
   wrap. *)
let hanging_indent (line : string) : int =
  let n = String.length line in
  let i = ref 0 in
  while !i < n && is_wrap_space line.[!i] do incr i done;
  if !i >= n then 0
  else begin
    let j = ref !i in
    (if line.[!j] = '-' || line.[!j] = '*' || line.[!j] = '+' then incr j
     else begin
       while !j < n && line.[!j] >= '0' && line.[!j] <= '9' do incr j done;
       if !j < n && line.[!j] = '.' then incr j
     end);
    if !j > !i && !j < n && is_wrap_space line.[!j] then begin
      while !j < n && is_wrap_space line.[!j] do incr j done;
      text_width (String.sub line 0 !j)
    end else 0
  end

let tokenize_run ((txt, sty) : string * Par_code_ui.style) :
    (string * Par_code_ui.style) list =
  let out = ref [] in
  let buf = Buffer.create 16 in
  let state = ref None in
  let flush () =
    if Buffer.length buf > 0 then begin
      out := (Buffer.contents buf, sty) :: !out;
      Buffer.clear buf
    end
  in
  String.iter
    (fun c ->
       let sp = is_wrap_space c in
       (match !state with
        | Some prev when prev <> sp -> flush (); state := Some sp
        | None -> state := Some sp
        | Some _ -> ());
       Buffer.add_char buf c)
    txt;
  flush ();
  List.rev !out

let wrap_runs ~(cols : int) (runs : (string * Par_code_ui.style) list) :
    (string * Par_code_ui.style) list list =
  let cols = max 8 cols in
  let wrap_line (runs : (string * Par_code_ui.style) list) =
    let tokens = List.concat_map tokenize_run runs in
    let hang = hanging_indent (String.concat "" (List.map fst runs)) in
    let out = ref [] in
    let cur = ref [] in
    let used = ref 0 in
    let wrapped = ref false in
    let trim_row (runs : (string * Par_code_ui.style) list) =
      (* Only the LAST run can carry the break space; trimming every run ate
         the space between a list marker and the bold text that followed it
         ("1. **product**"). *)
      let rec go = function
        | [] -> []
        | (s, sty) :: tl ->
          let n = ref (String.length s) in
          while !n > 0 && is_wrap_space s.[!n - 1] do decr n done;
          if !n = 0 then go tl
          else
            let s' = if !n = String.length s then s else String.sub s 0 !n in
            (s', sty) :: tl
      in
      List.rev (go (List.rev runs))
    in
    let add ((s, sty) as tok) =
      (match !cur with
       | (prev, psty) :: tl when psty = sty -> cur := (prev ^ s, psty) :: tl
       | _ -> cur := tok :: !cur);
      used := !used + text_width s
    in
    let flush_wrapped () =
      out := trim_row (List.rev !cur) :: !out;
      cur := [];
      used := 0;
      wrapped := true
    in
    let start_row () =
      if !used = 0 && !wrapped && hang > 0 then
        add (String.make hang ' ', Par_code_ui.no_style)
    in
    let hard_split (s, sty) =
      let piece = Buffer.create (String.length s) in
      let pw = ref 0 in
      let last_cp = ref "" and last_w = ref 0 in
      let utf8_of u =
        let b = Buffer.create 4 in
        Uutf.Buffer.add_utf_8 b u;
        Buffer.contents b
      in
      let flush_piece () =
        if Buffer.length piece > 0 then begin
          cur := (Buffer.contents piece, sty) :: !cur;
          used := !used + !pw;
          Buffer.clear piece;
          pw := 0;
          last_cp := "";
          last_w := 0;
          flush_wrapped ();
          start_row ()
        end
      in
      start_row ();
      ignore
        (Uutf.String.fold_utf_8
           (fun () _ v ->
              match v with
              | `Malformed _ ->
                (* v0.15.4: bytes that are not valid UTF-8 used to be copied
                   through to [I.string], where notty reads a stray 0x80–0x9F
                   byte as a control character and raises — taking the whole
                   session down. Drop them, as [sanitize_text] drops C0. *)
                ()
              | `Uchar u ->
                let w = display_width u in
                if !pw > 0 && !used + !pw + w > cols then begin
                  if is_no_start_char u && !last_cp <> "" then begin
                    (* Move the last character down with the punctuation so
                       the new row does not open with "。" / "：" / ")". *)
                    let carry = !last_cp and cw = !last_w in
                    Buffer.truncate piece
                      (Buffer.length piece - String.length carry);
                    pw := !pw - cw;
                    flush_piece ();
                    Buffer.add_string piece carry;
                    pw := cw;
                    last_cp := carry;
                    last_w := cw
                  end else flush_piece ()
                end;
                Uutf.Buffer.add_utf_8 piece u;
                pw := !pw + w;
                last_cp := utf8_of u;
                last_w := w)
           () s);
      if Buffer.length piece > 0 then begin
        cur := (Buffer.contents piece, sty) :: !cur;
        used := !used + !pw
      end
    in
    List.iter
      (fun ((s, _) as tok) ->
         let w = text_width s in
         if space_run s then begin
           if !used = 0 then begin
             (* Leading spaces are the first row's own layout; a continuation
                row gets [hang] instead below. *)
             if not !wrapped then add tok
           end else if !used + w > cols then flush_wrapped ()
           else add tok
         end else begin
           let fits = !used + w <= cols in
           if fits then begin
             start_row ();
             add tok
           end else if w > cols || (starts_with_cjk s && !used > 0) then begin
             (* A token that cannot start a row of its own (a URL, a path) or a
                CJK run fills the rest of the current row instead of leaving
                it half empty and starting over. *)
             start_row ();
             hard_split tok
           end else begin
             flush_wrapped ();
             start_row ();
             add tok
           end
         end)
      tokens;
    if !cur <> [] || !out = [] then begin
      out := trim_row (List.rev !cur) :: !out;
      cur := [];
      used := 0
    end;
    List.rev !out
  in
  List.concat_map wrap_line (split_runs runs)

(* vcat pads every line to the image's width with a run of spaces; when such a
   line is wrapped to the frame width the padding spills onto a second line and
   shows up as a blank row (v0.15.1: /help was double-spaced). Trailing blanks
   are invisible in a terminal, so drop them. *)
let trim_trailing_spaces (runs : (string * Par_code_ui.style) list) =
  let trim_right s =
    let n = ref (String.length s) in
    while !n > 0 && s.[!n - 1] = ' ' do
      decr n
    done;
    String.sub s 0 !n
  in
  let rec go = function
    | [] -> []
    | (txt, sty) :: tl ->
      let stripped = trim_right txt in
      if stripped = "" then go tl
      else (stripped, sty) :: tl
  in
  go (List.rev runs) |> List.rev

let to_notty_runs ~(cols : int) (img : Par_code_ui.image) :
    (string * Par_code_ui.style) list list =
  List.concat_map
    (fun runs ->
       List.concat_map (wrap_runs ~cols) (split_runs runs)
       |> List.map trim_trailing_spaces)
    (Par_code_ui.lines img)

let runs_to_image (runs : (string * Par_code_ui.style) list) : Notty.image =
  let open Notty in
  match runs with
  | [] -> I.empty
  | _ ->
    I.hcat
      (List.map
         (fun (txt, sty) ->
            (* v0.15.4: last line of defence — every string that reaches notty
               is clean, or a control character takes the frame down. *)
            I.string (attr_of_style sty) (sanitize_text txt))
         runs)

let wrap_text ~cols (s : string) : string list =
  wrap_runs ~cols [ (s, Par_code_ui.no_style) ]
  |> List.map (fun runs -> String.concat "" (List.map fst runs))

(* v0.15.1 phase 4: the spacing scale. A device-specific calibration should
   be a change here, not a hunt through the frame builder. [gutter] is the left
   margin of the transcript; [turn_gap] is the blank line that separates one
   turn from the next. *)
let gutter = 1
let turn_gap = 1

let width (t : t) = fst (Notty_unix.Term.size t.term)

(* v0.15.2: a 200-column tablet-wide terminal turns prose into unreadable long
   lines, so the transcript is capped at a comfortable measure and centred. On
   a phone the cap never applies. *)
(* v0.15.4: no readable-measure cap. Prose wants short lines, but this is a
   coding terminal: code, logs, diffs and tables were being wrapped and the
   transcript sat in a narrow column in the middle of a wide screen while the
   composer and status bar spanned the full width. The body now uses the whole
   window minus the gutter and the scroll-bar column. *)
let content_cols (t : t) = max 8 (width t - 2)

(* v0.15.4: entries keep the SOURCE image plus a render cache keyed by column
   count, so changing the font size re-flows the transcript instead of
   clipping it. *)
let fresh_cache () : render_cache = { rc_cols = -1; rc_runs = [] }

let append_raw (t : t) (img : Par_code_ui.image) =
  t.transcript <- t.transcript @ [ Line (img, fresh_cache ()) ]

let commit_tools (t : t) =
  if t.tool_block <> [] then begin
    let imgs = List.map snd t.tool_block in
    t.tool_block <- [];
    t.activity <- "";
    t.transcript <-
      t.transcript @ [ Tools { bx_imgs = imgs; bx_expanded = false } ]
  end

(* v0.15.4: anything appended to the transcript (a notice, a warning, an
   error, the user's own line) must land after what is already on screen. The
   streamed half line and the pending tool block render *after* the
   transcript, so they are committed first — otherwise a message sent during
   or right after a turn appeared above the answer it followed. *)
let commit_pending (t : t) =
  if t.partial <> "" then begin
    let p = t.partial in
    t.partial <- "";
    append_raw t (Par_code_ui.text p)
  end;
  commit_tools t

let append (t : t) (img : Par_code_ui.image) =
  commit_pending t;
  append_raw t img

(* v0.14.0 S1b: a frame is not a scroll buffer — one huge tool output must not
   push everything else out. Cap the lines taken from a single image and mark
   the cut. *)
let max_lines_per_image = 60

let append_truncated (t : t) (img : Par_code_ui.image) =
  (* The cap is applied when the entry is drawn: line count depends on the
     width in use, so trimming here would bake in one width. *)
  t.transcript <- t.transcript @ [ Capped (img, fresh_cache ()) ]

let append_text (t : t) (s : string) =
  append t (Par_code_ui.text s)

(* v0.15.1: collect this turn's tool lines, then fold them on release. Up to
   eight lines survive intact; beyond that the head and tail stay and the
   middle collapses into a count, so the block keeps a size ceiling. *)
let append_tool_line (t : t) ~(name : string) ~(key : string)
    (img : Par_code_ui.image) =
  t.activity <- name;
  t.tool_block <- t.tool_block @ [ (key, img) ]

(* The result of a tool call replaces the row of that same call. Without the
   key a parallel batch (four invocations, four results) overwrote the last row
   each time and left stale start lines behind. *)
let replace_tool_line (t : t) ~(key : string) (img : Par_code_ui.image) =
  if key <> "" && List.exists (fun (k, _) -> k = key) t.tool_block then
    t.tool_block <-
      List.map (fun (k, old) -> if k = key then (k, img) else (k, old))
        t.tool_block
  else
    match List.rev t.tool_block with
    | [] -> t.tool_block <- [ (key, img) ]
    | (k, _) :: rest -> t.tool_block <- List.rev ((k, img) :: rest)

let flush_tools (t : t) = commit_tools t

(* v0.15.1: the fold. Up to eight lines show as they are; longer runs keep the
   head and the tail with a count in the middle. Ctrl-O flips [bx_expanded] on
   the most recent block, which is what brings the hidden lines back. *)
let max_block_lines = 8

(* How many lines of a block of [n] survive the fold: head, hidden, tail. Kept
   pure and exported so the arithmetic is testable without a terminal. *)
let fold_plan (n : int) : int * int * int =
  if n <= max_block_lines then (n, 0, 0) else (4, n - 7, 3)

let block_runs ~cols (b : tool_block) :
    (string * Par_code_ui.style) list list =
  let lines = List.concat_map (fun img -> to_notty_runs ~cols img) b.bx_imgs in
  let n = List.length lines in
  if b.bx_expanded then lines
  else begin
    let head, hidden, tail = fold_plan n in
    let rec take k l =
      if k <= 0 then [] else match l with [] -> [] | h :: tl -> h :: take (k - 1) tl
    in
    let rec drop k l =
      if k <= 0 then l else match l with [] -> [] | _ :: tl -> drop (k - 1) tl
    in
    let head_lines = take head lines in
    if hidden <= 0 then head_lines
    else
      head_lines
      @ to_notty_runs ~cols
          (Par_code_ui.textf "  … %d more tool lines (Ctrl-O)" hidden)
      @ drop (n - tail) lines
  end

let toggle_last_block (t : t) =
  match
    List.find_opt (function Tools _ -> true | Line _ | Capped _ -> false)
      (List.rev t.transcript)
  with
  | Some (Tools b) -> b.bx_expanded <- not b.bx_expanded
  | _ -> ()

(* v0.15.1: the streamed half line, replaced wholesale by the REPL on every
   chunk so the frame shows text as it arrives. *)
let set_partial (t : t) (s : string) = t.partial <- s

(* Streaming: [feed] extends the partial line, [end_line] commits it. *)
let feed (t : t) (s : string) = t.partial <- t.partial ^ s

let end_line (t : t) =
  if t.partial <> "" then begin
    let p = t.partial in
    t.partial <- "";
    append_raw t (Par_code_ui.text p)
  end

let set_status (t : t) (s : string) = t.status <- s

(** v0.15.6: while a turn runs, the input line stays editable and Enter
    steers instead of submitting to the (idle) REPL reader. *)
let set_turn_active (t : t) (on : bool) = t.turn_active <- on

(* v0.15.6: prompts typed during a turn wait here until the REPL hands them to
   the runtime. Keeping them in the screen is what makes them visible and
   withdrawable before they are delivered. *)
let queue_prompt (t : t) (line : string) =
  if String.trim line <> "" then t.queued <- t.queued @ [ line ]

let take_queued (t : t) : string list =
  let q = t.queued in
  t.queued <- [];
  q

let withdraw_queued (t : t) : string option =
  match List.rev t.queued with
  | [] -> None
  | last :: rest ->
    t.queued <- List.rev rest;
    Some last

let queued_count (t : t) = List.length t.queued

let set_header (t : t) (s : string) = t.header <- s
let set_composer_label (t : t) (s : string) = t.composer_label <- s

(** A transient line shown before the status text while a turn runs. *)
let set_busy (t : t) (s : string) = t.busy <- s

(** v0.15.7: Ctrl-C inside a modal asks the running turn to stop after
    denying the modal's step. The REPL ticker consumes the flag. *)
let take_cancel_request (t : t) : bool =
  let v = t.cancel_requested in
  t.cancel_requested <- false;
  v

let clear_cancel_request (t : t) = t.cancel_requested <- false

let activity (t : t) = t.activity

let entry_runs ~cols (e : entry) :
    (string * Par_code_ui.style) list list =
  let rec take k l =
    if k <= 0 then [] else match l with [] -> [] | h :: tl -> h :: take (k - 1) tl
  in
  match e with
  | Line (img, cache) ->
    if cache.rc_cols <> cols then begin
      cache.rc_runs <- to_notty_runs ~cols img;
      cache.rc_cols <- cols
    end;
    cache.rc_runs
  | Capped (img, cache) ->
    if cache.rc_cols <> cols then begin
      let lines = to_notty_runs ~cols img in
      let n = List.length lines in
      let kept =
        if n <= max_lines_per_image then lines
        else
          take max_lines_per_image lines
          @ to_notty_runs ~cols
              (Par_code_ui.textf "… (%d more lines)"
                 (n - max_lines_per_image))
      in
      cache.rc_runs <- kept;
      cache.rc_cols <- cols
    end;
    cache.rc_runs
  | Tools b -> block_runs ~cols b

(* v0.15.7: the streamed half line is part of what the viewport draws.
   Leaving it out of [line_count] made the scroll ceiling too small whenever a
   chunk carried more than one line: scrolling to the top stopped in the
   middle of the transcript, and the frame then reflowed as the chunk grew. *)
let partial_runs (t : t) ~(cols : int) :
    (string * Par_code_ui.style) list list =
  if t.partial = "" then []
  else to_notty_runs ~cols (Par_code_ui.text t.partial)

let line_count (t : t) =
  let cols = content_cols t in
  List.fold_left (fun acc e -> acc + List.length (entry_runs ~cols e)) 0
    t.transcript
  + List.fold_left
      (fun acc (_, img) -> acc + List.length (to_notty_runs ~cols img))
      0 t.tool_block
  + List.length (partial_runs t ~cols)

(* v0.15.7: when the frame gains or loses lines, a viewport that is scrolled
   up must stay on the same content. [scroll] is measured from the bottom, so
   keep the top index fixed by moving the offset with the layout; at the
   bottom (scroll = 0) new output keeps following the tail. *)
let scroll_after_layout ~(scroll : int) ~(total : int) ~(body : int)
    ~(prev_total : int) ~(prev_body : int) : int =
  if scroll <= 0 then 0
  else begin
    let next = scroll + (total - prev_total) - (body - prev_body) in
    let next = max 0 next in
    min next (max 0 (total - body))
  end

(* ------------------------------------------------------------------ *)
(* Input line                                                          *)
(* ------------------------------------------------------------------ *)

let set_prompt (t : t) (p : string) = t.prompt <- p

(* v0.15.4: a terminal can deliver a mouse report split across writes. When
   the leading ESC is lost (or the drag arrives while the app is not yet in
   mouse mode) the tail "<35;12;4M" used to be typed into the input line —
   the garbage that showed up in the bottom-left corner on a touch drag. *)
let mouse_tail_re =
  Str.regexp
    "\\(\x1b\\[<\\|\x1b\\[M\\)?\\(\\[\\)?\\(<\\)?[0-9]+;[0-9]+;[0-9]+[Mm]"

let drop_mouse_tail (s : string) : string =
  let n = String.length s in
  if n = 0 || (s.[n - 1] <> 'M' && s.[n - 1] <> 'm') then s
  else begin
    let rec scan i =
      if i >= n then s
      else if Str.string_match mouse_tail_re s i && Str.match_end () = n then
        String.sub s 0 i
      else scan (i + 1)
    in
    scan 0
  end

let put_back (t : t) (s : string) =
  let before = String.sub t.input 0 t.cursor in
  let after = String.sub t.input t.cursor (String.length t.input - t.cursor) in
  let merged = before ^ s ^ after in
  let cleaned = drop_mouse_tail merged in
  let removed = String.length merged - String.length cleaned in
  t.input <- cleaned;
  t.cursor <- t.cursor + String.length s - removed

let delete_back (t : t) =
  if t.cursor > 0 then begin
    (* step back one UTF-8 codepoint, not one byte *)
    let i = ref (t.cursor - 1) in
    while !i > 0 && Char.code t.input.[!i] land 0xC0 = 0x80 do decr i done;
    t.input <- String.sub t.input 0 !i
               ^ String.sub t.input t.cursor (String.length t.input - t.cursor);
    t.cursor <- !i
  end

(* v0.15.1: word-wise motion/editing, the Ctrl-Left / Alt-Backspace habits a
   shell gives. A run of non-spaces counts as one word (paths are one word). *)
let prev_word_start (s : string) (i : int) : int =
  let i = ref (min i (String.length s)) in
  while !i > 0 && s.[!i - 1] = ' ' do
    decr i
  done;
  while !i > 0 && s.[!i - 1] <> ' ' do
    decr i
  done;
  !i

let next_word_end (s : string) (i : int) : int =
  let n = String.length s in
  let i = ref (min i n) in
  while !i < n && s.[!i] = ' ' do
    incr i
  done;
  while !i < n && s.[!i] <> ' ' do
    incr i
  done;
  !i

let delete_word_back (t : t) =
  let i = prev_word_start t.input t.cursor in
  t.input <-
    String.sub t.input 0 i
    ^ String.sub t.input t.cursor (String.length t.input - t.cursor);
  t.cursor <- i

let delete_word_forward (t : t) =
  let j = next_word_end t.input t.cursor in
  t.input <-
    String.sub t.input 0 t.cursor
    ^ String.sub t.input j (String.length t.input - j)

let delete_forward (t : t) =
  if t.cursor < String.length t.input then begin
    let j = ref (t.cursor + 1) in
    while !j < String.length t.input && Char.code t.input.[!j] land 0xC0 = 0x80 do
      incr j
    done;
    t.input <- String.sub t.input 0 t.cursor
               ^ String.sub t.input !j (String.length t.input - !j)
  end

let move_left (t : t) =
  if t.cursor > 0 then begin
    let i = ref (t.cursor - 1) in
    while !i > 0 && Char.code t.input.[!i] land 0xC0 = 0x80 do decr i done;
    t.cursor <- !i
  end

let move_right (t : t) =
  if t.cursor < String.length t.input then begin
    let j = ref (t.cursor + 1) in
    while !j < String.length t.input && Char.code t.input.[!j] land 0xC0 = 0x80 do
      incr j
    done;
    t.cursor <- !j
  end

let kill_to_start (t : t) =
  t.input <- String.sub t.input t.cursor (String.length t.input - t.cursor);
  t.cursor <- 0

let kill_to_end (t : t) = t.input <- String.sub t.input 0 t.cursor

let kill_word (t : t) =
  let i = ref t.cursor in
  while !i > 0 && t.input.[!i - 1] = ' ' do decr i done;
  while !i > 0 && t.input.[!i - 1] <> ' ' do decr i done;
  t.input <- String.sub t.input 0 !i
             ^ String.sub t.input t.cursor (String.length t.input - t.cursor);
  t.cursor <- !i

(* Completion candidates: slash commands, skill ids, and flow ids after
   "/flow run ". Shared with the REPL so the list cannot drift. *)
let all_commands () =
  List.map fst Par_code_ui.commands
  @ List.map
      (fun (e : Par_code_skills.entry) -> "/" ^ e.descriptor.id)
      (Par_code_skills.list_custom ())

let starts_with ~prefix s =
  String.length s >= String.length prefix
  && String.sub s 0 (String.length prefix) = prefix

(* v0.15.1: the menu opencode shows while a command is being typed. It lists
   commands and custom skills, is driven by Up/Down, and Enter completes the
   highlighted one unless the typed text already is it. *)
(* v0.15.1: @file references. The workspace is walked once per session (skipping
   the usual build/vendor directories) and the paths are fuzzy-matched against
   the token being typed, the way opencode does. *)
let index_files () : string list =
  let skip =
    [ ".git"; "_build"; ".par"; "node_modules"; ".omo"; ".opencode"; "_opam";
      ".cache" ]
  in
  let out = ref [] in
  let count = ref 0 in
  let rec walk dir depth =
    if depth > 8 || !count > 4000 then ()
    else
      match Sys.readdir dir with
      | exception Sys_error _ -> ()
      | entries ->
        Array.iter
          (fun name ->
             if !count > 4000 then ()
             else if name = "" || name.[0] = '.' then ()
             else if List.mem name skip then ()
             else
               let path = Filename.concat dir name in
               match (try Some (Sys.is_directory path) with Sys_error _ -> None) with
               | Some true -> walk path (depth + 1)
               | Some false ->
                 incr count;
                 let rel =
                   if String.length path > 2 && String.sub path 0 2 = "./" then
                     String.sub path 2 (String.length path - 2)
                   else path
                 in
                 out := rel :: !out
               | None -> ())
          entries
  in
  walk "." 0;
  List.rev !out

let fuzzy_match ~(needle : string) (hay : string) : bool =
  let needle = String.lowercase_ascii needle in
  let hay = String.lowercase_ascii hay in
  let n = ref 0 in
  let ok = ref true in
  String.iter
    (fun c ->
       if !n < String.length needle && c = needle.[!n] then incr n)
    hay;
  if !n < String.length needle then ok := false;
  !ok

let refresh_menu (t : t) =
  if t.menu_suppress then begin
    t.menu <- [];
    t.menu_token <- None;
    t.menu_suppress <- false
  end else
  let file_items () =
    (* opencode matches the @token under the cursor; take the last @word so a
       reference can sit anywhere in the sentence. *)
    let words =
      let out = ref [] in
      let start = ref 0 in
      String.iteri
        (fun i c ->
           if c = ' ' then begin
             out := (String.sub t.input !start (i - !start), !start) :: !out;
             start := i + 1
           end)
        t.input;
      out := (String.sub t.input !start (String.length t.input - !start), !start) :: !out;
      List.rev !out
    in
    match
      List.fold_left
        (fun acc (w, pos) ->
           if String.length w > 0 && w.[0] = '@' then Some (w, pos) else acc)
        None words
    with
    | None ->
      t.menu_token <- None;
      []
    | Some (token, pos) ->
      let needle = String.sub token 1 (String.length token - 1) in
      t.menu_token <- Some (pos, String.length token);
      let files =
        match t.files with
        | Some f -> f
        | None ->
          let f = index_files () in
          t.files <- Some f;
          f
      in
      files
      |> List.filter (fun p -> fuzzy_match ~needle p)
      |> List.filteri (fun i _ -> i < 50)
      |> List.map (fun p -> ("@" ^ p, ""))
  in
  let items =
    match String.split_on_char ' ' t.input with
    | [ partial ] when partial <> "" && partial.[0] = '/' ->
      let all =
        Par_code_ui.commands
        @ List.map
            (fun (e : Par_code_skills.entry) ->
               ("/" ^ e.descriptor.id, "custom skill"))
            (Par_code_skills.list_custom ())
      in
      List.filter (fun (cmd, _) -> starts_with ~prefix:partial cmd) all
    | _ -> file_items ()
  in
  t.menu <- items;
  t.menu_index <- min t.menu_index (max 0 (List.length items - 1))

(* [value] is either a slash command or an "@path" reference; for the latter
   replace only the trailing token so earlier words survive. *)
let accept_menu (t : t) (value : string) =
  (if value <> "" && value.[0] = '@' then
     match t.menu_token with
     | Some (pos, len) when pos + len <= String.length t.input ->
       t.input <-
         String.sub t.input 0 pos ^ value
         ^ String.sub t.input (pos + len) (String.length t.input - pos - len)
     | _ -> t.input <- value
   else t.input <- value);
  t.cursor <- String.length t.input;
  t.menu <- [];
  t.menu_token <- None;
  t.menu_suppress <- true

let complete (t : t) =  let text = t.input in
  let starts_with ~prefix s =
    String.length s >= String.length prefix
    && String.sub s 0 (String.length prefix) = prefix
  in
  let candidates =
    match String.split_on_char ' ' text with
    | [ partial ] when partial <> "" && partial.[0] = '/' ->
      List.filter (starts_with ~prefix:partial) (all_commands ())
    | [ "/flow"; "run"; partial ] ->
      List.filter (starts_with ~prefix:partial) (Par_code_flow.available ())
    | _ -> []
  in
  (* Several candidates: complete to their longest common prefix, the same
     behaviour a shell gives, instead of dumping a list over the frame. *)
  let common_prefix xs =
    match xs with
    | [] -> ""
    | first :: rest ->
      let rec lcp a b i =
        if i >= String.length a || i >= String.length b || a.[i] <> b.[i]
        then String.sub a 0 i
        else lcp a b (i + 1)
      in
      List.fold_left (fun acc s -> lcp acc s 0) first rest
  in
  match candidates with
  | [ one ] ->
    t.input <- one;
    t.cursor <- String.length one
  | [] -> ()
  | many ->
    let prefix = common_prefix many in
    if String.length prefix > String.length t.input then begin
      t.input <- prefix;
      t.cursor <- String.length prefix
    end

(* v0.15.1: prompt history survives restarts again (dropping the line
   interface took the old ~/.par/history loader with it). Newest first in
   memory, oldest first on disk. *)
let save_history (t : t) =
  match t.history_path with
  | None -> ()
  | Some path ->
    (try
       let tmp = path ^ ".tmp" in
       let oc = open_out tmp in
       List.iter
         (fun l -> output_string oc l; output_char oc '\n')
         (List.rev (List.filteri (fun i _ -> i < 200) t.history));
       close_out oc;
       Sys.rename tmp path
     with _ -> ())

let load_history (t : t) ~(path : string) =
  t.history_path <- Some path;
  try
    let ic = open_in path in
    Fun.protect
      ~finally:(fun () -> close_in_noerr ic)
      (fun () ->
         try
           while true do
             let l = input_line ic in
             if String.trim l <> "" then t.history <- l :: t.history
           done
         with End_of_file -> ())
  with Sys_error _ -> ()

let search_matches (t : t) (q : string) : string list =
  if q = "" then t.history
  else begin
    let q = String.lowercase_ascii q in
    let n = String.length q in
    List.filter
      (fun h ->
         let h = String.lowercase_ascii h in
         let m = String.length h in
         let rec go i = i + n <= m && (String.sub h i n = q || go (i + 1)) in
         go 0)
      t.history
  end

let search_current (t : t) : string =
  match t.search with
  | None -> ""
  | Some s ->
    (match List.nth_opt (search_matches t s.s_query) (max 0 s.s_index) with
     | Some m -> m
     | None -> "")

let search_begin (t : t) =
  t.search <-
    Some { s_query = ""; s_index = 0; s_saved = t.input; s_cursor = t.cursor }

let search_cancel (t : t) =
  (match t.search with
   | Some s ->
     t.input <- s.s_saved;
     t.cursor <- s.s_cursor
   | None -> ());
  t.search <- None

let search_accept (t : t) =
  let m = search_current t in
  if m <> "" then begin
    t.input <- m;
    t.cursor <- String.length m
  end;
  t.search <- None

let search_handle (t : t) (k : _) ~(ctrl : bool) =
  match t.search with
  | None -> ()
  | Some s ->
    (match k with
     | `ASCII c when not ctrl ->
       let c = if c >= 'A' && c <= 'Z' then Char.lowercase_ascii c else c in
       s.s_query <- s.s_query ^ String.make 1 c;
       s.s_index <- 0
     | `Backspace ->
       if s.s_query <> "" then
         s.s_query <- String.sub s.s_query 0 (String.length s.s_query - 1);
       s.s_index <- 0
     | `ASCII c when ctrl && (c = 'r' || c = 'R') ->
       s.s_index <- s.s_index + 1
     | `Arrow `Up -> s.s_index <- s.s_index + 1
     | `Arrow `Down -> s.s_index <- max 0 (s.s_index - 1)
     | `Enter -> search_accept t
     | `Escape -> search_cancel t
     | _ -> ())

let history_push (t : t) (line : string) =
  if String.trim line <> "" then begin
    t.history <- line :: List.filter (fun h -> h <> line) t.history;
    t.history <- List.filteri (fun i _ -> i < 200) t.history;
    save_history t
  end;
  t.hist_pos <- None

let history_move (t : t) (delta : int) =
  let n = List.length t.history in
  if n > 0 then begin
    let pos =
      match t.hist_pos with Some p -> p | None -> if delta > 0 then -1 else 0
    in
    let pos = max 0 (min (n - 1) (pos + delta)) in
    t.hist_pos <- Some pos;
    t.input <- List.nth t.history pos;
    t.cursor <- String.length t.input
  end

(* ------------------------------------------------------------------ *)
(* Frame                                                               *)
(* ------------------------------------------------------------------ *)

let all_runs (t : t) ~(cols : int) :
    (string * Par_code_ui.style) list list =
  List.concat_map (entry_runs ~cols) t.transcript
  @ List.concat_map (fun (_, img) -> to_notty_runs ~cols img) t.tool_block
  @ partial_runs t ~cols

let visible_runs (t : t) ~(height : int) :
    int * (int * (string * Par_code_ui.style) list) list =
  let all = all_runs t ~cols:(content_cols t) in
  let n = List.length all in
  let start = max 0 (n - height - t.scroll) in
  let start = min start n in
  let rec drop k l = if k <= 0 then l else match l with [] -> [] | _ :: tl -> drop (k - 1) tl in
  let rec take k l = if k <= 0 then [] else match l with [] -> [] | h :: tl -> h :: take (k - 1) tl in
  let taken = take height (drop start all) in
  (start, List.mapi (fun i runs -> (start + i, runs)) taken)

(* v0.15.6: a selected line renders in reverse video; the selection is stored
   in transcript coordinates so it survives scrolling and re-wrapping. *)
let selection_runs (t : t) (line : int)
    (runs : (string * Par_code_ui.style) list) =
  match t.sel with
  | None -> runs
  | Some (a, b) ->
    (match Par_code_selection.line_span a b line with
     | None -> runs
     | Some (from, to_) -> Par_code_selection.select_runs runs ~from ~to_)

let frame (t : t) : Notty.image =
  let open Notty in
  let open Notty.I in
  let w, h = Notty_unix.Term.size t.term in
  let status_h = 1 in
  (* Multi-line input (Alt+Enter inserts a newline): show at most six rows and
     keep the cursor's row in view. *)
  let input_lines =
    match String.split_on_char '\n' t.input with [] -> [ "" ] | ls -> ls
  in
  let n_lines = List.length input_lines in
  let cursor_line, cursor_col =
    let before = String.sub t.input 0 t.cursor in
    let ls = String.split_on_char '\n' before in
    let n = List.length ls in
    (n - 1, String.length (List.nth ls (n - 1)))
  in
  let max_input_h = 6 in
  (* v0.15.4: a six-row composer must not squeeze the status bar off a short
     terminal — keep at least one body row plus the status line and the rule. *)
  let input_h =
    max 1 (min (min max_input_h n_lines) (max 1 (h - 4)))
  in
  let first_line = max 0 (min (cursor_line - input_h + 1) (n_lines - input_h)) in
  (* v0.15.4: the frame must fit the window. On a short terminal (a phone with a
     large font, a small split) the fixed rows used to push the input line and
     the status bar off the bottom, so you could not see what you typed. Room
     is handed out in order: input and status always, then header, composer,
     menu, and whatever is left is the body. *)
  let room = max 1 (h - input_h - status_h - 1) in
  let header_h = if t.header = "" || room < 6 then 0 else 2 in
  let composer_h =
    if t.composer_label = "" || room - header_h < 4 then 0 else 1
  in
  let menu_cap = max 0 (room - header_h - composer_h - 1) in
  let menu_rows =
    let n = List.length t.menu in
    let visible = min 6 (min n menu_cap) in
    if visible <= 0 then []
    else begin
      let first = max 0 (min (t.menu_index - visible + 1) (n - visible)) in
      List.filteri (fun i _ -> i >= first && i < first + visible) t.menu
      |> List.mapi (fun j (cmd, desc) ->
           let i = first + j in
           let selected = i = t.menu_index in
           let sty =
             if selected then
               Par_code_ui.style ~fg:Par_code_ui.Green ~bold:true ()
             else Par_code_ui.no_style
           in
           I.hsnap ~align:`Left w
             (I.string (attr_of_style sty)
                (sanitize_text
                   ((if selected then " \xe2\x96\xb8 " else "   ")
                    ^ cmd
                    ^ String.make (max 1 (16 - String.length cmd)) ' '
                    ^ desc))))
    end
  in
  let menu_h = List.length menu_rows in
  (* v0.15.6: prompts queued during a turn get a dock of their own above the
     composer. Two are shown in full, the rest as a count; Ctrl-U withdraws the
     newest before it is delivered. *)
  let queue_rows =
    match t.queued with
    | [] -> []
    | msgs ->
      let shown =
        List.filteri (fun i _ -> i < 2) msgs
        |> List.map (fun msg ->
               I.hsnap ~align:`Left w
                 (I.string A.(fg lightblack)
                    (sanitize_text (" \xe2\x8f\xb3 queued \xc2\xb7 " ^ preview_text msg))))
      in
      let more = List.length msgs - 2 in
      if more > 0 then
        shown
        @ [ I.hsnap ~align:`Left w
              (I.string A.(fg lightblack)
                 (sanitize_text (Printf.sprintf " \xe2\x8f\xb3 … %d more queued \xc2\xb7 Ctrl-U withdraw" more))) ]
      else
        shown
        @ [ I.hsnap ~align:`Left w
              (I.string A.(fg lightblack)
                 (sanitize_text "   Ctrl-U withdraws the newest")) ]
  in
  let queue_h = List.length queue_rows in
  let body_h = max 1 (room - header_h - composer_h - menu_h - queue_h) in
  (* v0.15.4: a drag keeps adding to [scroll]; without a ceiling, scrolling
     past the top left a large value behind and the next drag down appeared
     stuck. Clamp before drawing. *)
  let total = line_count t in
  t.scroll <-
    scroll_after_layout ~scroll:t.scroll ~total ~body:body_h
      ~prev_total:t.last_total ~prev_body:t.last_body_h;
  t.last_total <- total;
  t.last_body_h <- body_h;
  let max_top = max 0 (total - body_h) in
  if t.scroll > max_top then t.scroll <- max_top;
  let body =
    let start, lines = visible_runs t ~height:body_h in
    (* v0.15.6: remember which transcript lines this frame shows, so a mouse
       row maps back to the line the pointer is over. *)
    t.view <- Some (start, header_h, body_h);
    I.vcat
      (List.map
         (fun (idx, runs) -> runs_to_image (selection_runs t idx runs))
         lines)
    |> fun img ->
    I.vsnap ~align:`Top body_h
      (I.pad ~l:gutter ~r:0 img)
    (* The bar is pinned to the last column: without the snap its position
       followed the widest line of whatever was on screen, which made it drift
       left as new content arrived. *)
    |> fun img -> I.hsnap ~align:`Left (max 1 (w - 1)) img
  in
  (* v0.15.1 visual pass 2: a one-column scroll indicator on the right edge.
     It only appears when the transcript is taller than the view, so the frame
     stays quiet in the common case. *)
  let body =
    if total <= body_h then body
    else begin
      let thumb = max 1 (body_h * body_h / total) in
      let top =
        ((max_top - min t.scroll max_top) * (body_h - thumb)) / max 1 max_top
      in
      let bar =
        I.vcat
          (List.init body_h (fun i ->
               I.string
                 A.(fg (if i >= top && i < top + thumb then lightwhite else lightblack))
                 (if i >= top && i < top + thumb then "█" else "│")))
      in
      I.hcat [ body; bar ]
    end
  in
  let input_line =
    match t.search with
    | Some s ->
      I.vsnap ~align:`Bottom input_h
        (I.hsnap ~align:`Left w
           (I.string A.(fg cyan)
              (sanitize_text
                 (Printf.sprintf " (reverse-i-search) `%s': %s" s.s_query
                    (search_current t)))))
    | None ->
    let indent = " " ^ t.prompt in
    let cont_indent = String.make (String.length indent) ' ' in
    (* v0.15.1: an empty composer says what it is for instead of showing a bare
       prompt; the hint disappears the moment a key arrives. *)
    let placeholder =
      t.input = "" && t.editing && t.modal = None && t.picker = None
    in
    if placeholder then
      I.hsnap ~align:`Left w
        (I.hcat
           [ I.string A.(fg green ++ st bold) (sanitize_text indent)
             ; I.string A.(fg lightblack)
                 (sanitize_text "Ask anything · /help for commands") ])
    else
    let rows =
      List.filteri
        (fun i _ -> i >= first_line && i < first_line + input_h)
        input_lines
      |> List.mapi (fun j line ->
             let i = first_line + j in
             let lead = if i = 0 then indent else cont_indent in
             if i = cursor_line then begin
               let before = String.sub line 0 (min cursor_col (String.length line)) in
               let after =
                 String.sub line (min cursor_col (String.length line))
                   (String.length line - min cursor_col (String.length line))
               in
               I.hsnap ~align:`Left w
                 (I.hcat
                    [ I.string A.(st bold) (sanitize_text (lead ^ before))
                      ; I.string A.(st reverse)
                          (if after = "" then " "
                           else sanitize_text (String.sub after 0 1))
                      ; I.string A.empty
                          (sanitize_text
                             (if String.length after > 1 then
                                String.sub after 1 (String.length after - 1)
                              else "")) ])
             end else
               I.hsnap ~align:`Left w
                 (I.string A.empty (sanitize_text (lead ^ line))))
    in
    I.vcat rows
  in
  let status =
    let hint =
      if t.last_key = "" then "" else Printf.sprintf "  [%s]" t.last_key
    in
    (* The scroll position goes first: a long bar would otherwise clip it, and
       it is the one field that explains why the transcript is not at the end. *)
    let scroll_hint =
      if t.scroll = 0 then "" else Printf.sprintf "↑%d · " t.scroll
    in
    let text =
      match t.busy, t.status with
      | "", s -> s
      | b, "" -> b
      | b, s -> b ^ " · " ^ s
    in
    (* v0.15.6: while the pointer is selecting, the bar says what the drag
       does instead of the usual facts. *)
    let text =
      if t.select_mode then "select · drag to copy · Ctrl-X/Esc exit"
      else text
    in
    let left = " " ^ scroll_hint ^ text ^ hint in
    (* v0.15.1: while a turn runs, the right edge says how to stop it. *)
    let left_w = text_width left in
    (* A long bar wins: the hint is dropped rather than clipping the facts. *)
    let right =
      status_right_hint ~modal_open:(t.modal <> None) ~busy:t.busy
        ~turn_active:t.turn_active ~has_input:(String.trim t.input <> "")
        ~left_w ~width:w
    in
    let gap = max 1 (w - left_w - text_width right) in
    I.hsnap ~align:`Left w
      (I.hcat
         [ I.string A.(fg lightblack) (sanitize_text left)
           ; I.string A.empty (String.make gap ' ')
           ; I.string A.(fg lightblack) (sanitize_text right) ])
  in
  let rule =
    I.string A.(fg lightblack) (String.concat "" (List.init w (fun _ -> "─")))
  in
  let body =
    let box ~title ~rows ~footer =
      let inner_w = min (max 32 (w - 12)) 84 in
      let border l r =
        I.string A.(fg lightblack)
          (l ^ String.concat "" (List.init inner_w (fun _ -> "─")) ^ r)
      in
      (* v0.15.1: one visual language for every box — the title carries the
         accent and the weight, body rows are plain, the key legend is dim.
         v0.15.6: rows carry their own style so a diff can be red/green. *)
      let row0 (sty : Par_code_ui.style) s =
        I.hcat
          [ I.string A.(fg lightblack) "│"
            ; I.hsnap ~align:`Left inner_w
                (I.string (attr_of_style sty) (sanitize_text s))
            ; I.string A.(fg lightblack) "│" ]
      in
      let styled_row (s, sty) = row0 sty s in
      (* A body taller than the window would be clipped mid-line by vsnap;
         keep the head and say how much is left. *)
      let rows =
        let cap = max 3 (body_h - 8) in
        let n = List.length rows in
        if n <= cap then rows
        else begin
          let rec take k l =
            if k <= 0 then []
            else match l with [] -> [] | h :: tl -> h :: take (k - 1) tl
          in
          take (cap - 1) rows
          @ [ ( Printf.sprintf "  … (%d more lines)" (n - cap + 1),
                Par_code_ui.style ~dim:true () ) ]
        end
      in
      let content =
        I.vcat
          (border "┌" "┐"
           :: List.map styled_row title
           @ [ border "├" "┤" ]
           @ List.map styled_row rows
           @ List.map styled_row footer
           @ [ border "└" "┘" ])
      in
      I.vsnap ~align:`Middle body_h (I.hsnap ~align:`Middle w content)
    in
    match t.modal, t.picker with
    | None, None -> body
    | None, Some p ->
      let total = List.length p.p_items in
      let visible = min 12 total in
      let first = max 0 (min (p.p_index - visible + 1) (total - visible)) in
      let items =
        List.filteri (fun i _ -> i >= first && i < first + visible) p.p_items
        |> List.mapi (fun j s ->
               let i = first + j in
               ( (if i = p.p_index then " ▸ " else "   ") ^ s,
                 Par_code_ui.style ~bold:true () ))
      in
      box
        ~title:[ (" " ^ p.p_title, Par_code_ui.style ~fg:Par_code_ui.Cyan ~bold:true ()) ]
        ~rows:items
        ~footer:
          [ ("  ↑/↓ move · Enter select · Esc close",
             Par_code_ui.style ~dim:true ()) ]
    | Some m, _ ->
      let inner_w = min (max 32 (w - 12)) 84 in
      let leading_spaces s =
        let n = ref 0 in
        while !n < String.length s && s.[!n] = ' ' do incr n done;
        !n
      in
      let wrapped_with (s, sty) =
        let lead = leading_spaces s in
        let body = String.sub s lead (String.length s - lead) in
        let indent = " " ^ String.make lead ' ' in
        wrap_text ~cols:(max 8 (inner_w - 1 - lead)) body
        |> List.map (fun l -> (indent ^ l, sty))
      in
      let title_sty = Par_code_ui.style ~fg:Par_code_ui.Cyan ~bold:true () in
      let legend =
        String.concat "   " (List.map (fun (k, label) -> k ^ ": " ^ label) m.options)
      in
      box
        ~title:(wrapped_with (m.title, title_sty))
        ~rows:(List.concat_map wrapped_with m.body)
        ~footer:
          (wrapped_with (legend, Par_code_ui.style ~dim:true ()))
  in
  let header =
    if header_h = 0 then I.empty
    else
      I.vcat
        [ I.hsnap ~align:`Left w
            (I.string A.(fg lightblack) (sanitize_text (" " ^ t.header)))
        ; rule ]
  in
  let composer =
    if composer_h = 0 then I.empty
    else
      let top = "╭─ " ^ t.composer_label ^ " " in
      let pad = Stdlib.max 0 (w - text_width top) in
      I.hsnap ~align:`Left w
        (I.string A.(fg lightblack)
           (sanitize_text (top ^ String.concat "" (List.init pad (fun _ -> "─")))))
  in
  (* The composer's top border opens the box; the rule below the input closes
     it, so the input sits inside the frame instead of floating under a rule. *)
  let bottom_rule =
    if composer_h = 0 then rule
    else
      I.hsnap ~align:`Left w
        (I.string A.(fg lightblack)
           ("\xe2\x95\xb0" ^ String.concat "" (List.init w (fun _ -> "\xe2\x94\x80"))))
  in
  header <-> I.vsnap ~align:`Top body_h body <-> composer <-> I.vcat menu_rows
  <-> I.vcat queue_rows
  <-> input_line <-> bottom_rule <-> status

(** v0.14.0 S2: Ctrl-C follows Claude Code — with input it clears the line, with
    an empty line a second press within two seconds exits. Ctrl-D exits from an
    empty line, Esc clears the line. *)
let ctrl_c (t : t) =
  let now = Unix.gettimeofday () in
  if t.input <> "" then begin
    t.input <- "";
    t.cursor <- 0;
    t.last_ctrl_c <- Some now;
    t.status <- "input cleared — Ctrl-C again to exit"
  end else
    match t.last_ctrl_c with
    | Some at when now -. at < 2.0 ->
      t.running <- false;
      t.submitted <- None
    | _ ->
      t.last_ctrl_c <- Some now;
      t.status <- "press Ctrl-C again to exit"

(* v0.15.7: a Ctrl-C that interrupts a turn also prepares the idle exit
   ladder. Without this the next press only cleared the input and a second
   one was needed, so a user pressing Ctrl-C to stop a stuck turn saw the
   session "not exiting" for several presses. *)
let note_turn_interrupt (t : t) =
  t.input <- "";
  t.cursor <- 0;
  t.last_ctrl_c <- Some (Unix.gettimeofday ())

(* v0.15.6: selection mode for a terminal without a Shift key (a phone):
   Ctrl-X turns a plain drag into a text selection. *)
let toggle_select_mode (t : t) =
  t.select_mode <- not t.select_mode;
  if not t.select_mode then begin
    t.sel <- None;
    t.selecting <- false
  end;
  t.last_key <- ""

(* v0.15.6: the echo a sent message leaves in the transcript, shared by the
   normal submit path and a steer sent during a turn. *)
let echo_user_line (t : t) (line : string) =
  (if t.partial <> "" then end_line t);
  (if t.tool_block <> [] then flush_tools t);
  if String.trim line <> "" then begin
    for _ = 1 to turn_gap do
      append t (Par_code_ui.text "")
    done;
    append t
      (Par_code_ui.textf "\xe2\x80\xba %s" line
         ~style:(Par_code_ui.style ~fg:Par_code_ui.Green ~bold:true ()))
  end

let handle_key (t : t) ~(page : int) ((k, mods) : Notty.Unescape.key) =
  let ctrl = List.mem `Ctrl mods in
  match t.modal, t.search with
  | Some modal, _ ->
    (* A modal owns the keyboard: only its keys, Esc, and Ctrl-C matter. *)
    (match k, mods with
     | `ASCII c, mods
       when List.mem `Ctrl mods
            && (c = 'c' || c = 'C' || c = '\003') ->
       (* Ctrl-C denies this step and cancels the active run (a turn, or a
          command like /distill that raised the modal). *)
       if t.turn_active || t.busy <> "" then begin
         t.cancel_requested <- true;
         note_turn_interrupt t
       end;
       t.modal_answer <- None;
       t.modal <- None
     | _ ->
       let key =
         match k with
         | `Escape -> Some ""
         | `ASCII c ->
           let c = if c >= 'A' && c <= 'Z' then Char.lowercase_ascii c else c in
           Some (String.make 1 c)
         | _ -> None
       in
       (match key with
        | Some "" ->
          t.modal_answer <- None;
          t.modal <- None
        | Some k when List.mem_assoc k modal.options ->
          t.modal_answer <- Some k;
          t.modal <- None
        | _ -> ignore ctrl))
  | None, Some _ -> search_handle t k ~ctrl
  | None, None ->
  let ascii = match k with `ASCII c -> Some c | _ -> None in
  if t.csi_drop then begin
    (* Dropping the tail of a split escape sequence (a mouse report arrives as
       ESC + "[<65;83;39M" when the terminal writes it in pieces). *)
    (match ascii with
     | Some c when (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || c = '~' ->
       t.csi_drop <- false;
       (* The '[' of "ESC[<" can be delivered as text when the report is split
          inside that first fragment: take it back so a drag never leaves a
          stray bracket in the input line. *)
       let n = String.length t.input in
       if n > 0 && t.input.[n - 1] = '[' && t.cursor = n then begin
         t.input <- String.sub t.input 0 (n - 1);
         t.cursor <- n - 1
       end
     | _ -> ())
  end else begin
    (* ESC followed by "[" or "O" belongs to an escape sequence; ESC followed
       by anything else was a real Escape press. *)
    (match t.escape_at, ascii with
     | Some _, Some ('[' | 'O') ->
       t.escape_at <- None;
       t.csi_drop <- true
     | Some _, _ ->
       t.escape_at <- None;
       if t.editing then begin
         t.input <- "";
         t.cursor <- 0
       end
     | None, _ -> ());
  if not t.csi_drop then
  if t.editing || t.turn_active then
    match k with
    | `Arrow `Up when t.menu <> [] ->
      t.menu_index <- max 0 (t.menu_index - 1)
    | `Arrow `Down when t.menu <> [] ->
      t.menu_index <- min (List.length t.menu - 1) (t.menu_index + 1)
    | `Tab when t.menu <> [] ->
      (match List.nth_opt t.menu t.menu_index with
       | Some (value, _) -> accept_menu t value
       | None -> complete t)
    | `Enter when t.menu <> []
                   && (match List.nth_opt t.menu t.menu_index with
                       | Some (value, _) -> value <> String.trim t.input
                       | None -> false) ->
      (* Completes the highlighted entry; a second Enter runs/sends it. *)
      (match List.nth_opt t.menu t.menu_index with
       | Some (value, _) -> accept_menu t value
       | None -> ())
    | `Escape when t.menu <> [] ->
      t.menu <- [];
      t.menu_suppress <- true
    | `Enter when t.turn_active ->
      let line = t.input in
      if String.trim line <> "" then begin
        echo_user_line t line;
        t.input <- "";
        t.cursor <- 0;
        history_push t line;
        queue_prompt t line
      end
    | `Enter when List.mem `Meta mods ->
      (* Alt+Enter: compose a multi-line message; Enter still submits. *)
      put_back t "\n"
    | `Enter ->
      let len = String.length t.input in
      if len > 0 && t.input.[len - 1] = '\\' then begin
        (* shell-style continuation: a trailing backslash starts a new line,
           for terminals/keyboards where Alt+Enter is awkward (a phone). *)
        t.input <- String.sub t.input 0 (len - 1) ^ "\n";
        t.cursor <- String.length t.input
      end else begin
        let line = t.input in
        t.submitted <- Some line;
        t.input <- "";
        t.cursor <- 0;
        t.editing <- false;
        (* v0.15.4: a previous turn can end with an unfinished streamed line or
           an uncommitted tool block (interrupt, provider error). Those render
           *after* the transcript, so without this the new message appeared
           above the tail of the old answer. Commit them first. *)
        (if t.partial <> "" then end_line t);
        (if t.tool_block <> [] then flush_tools t);
        (* The frame owns the screen: once the input line clears, the message
           the user just sent would be gone. Keep it in the transcript, the way
           a shell keeps the command line it echoed. *)
        echo_user_line t line
      end
    | `Escape when t.select_mode ->
      t.select_mode <- false;
      t.sel <- None;
      t.selecting <- false
    | `Escape ->
      (* Hold the decision until the next key: a lone ESC is a key press, but
         the same byte starts every CSI sequence, and a terminal may write the
         rest of the sequence a moment later. *)
      t.escape_at <- Some (Unix.gettimeofday ())
    | `Backspace when ctrl || List.mem `Meta mods -> delete_word_back t
    | `Delete when ctrl || List.mem `Meta mods -> delete_word_forward t
    | `Arrow `Left when ctrl || List.mem `Meta mods ->
      t.cursor <- prev_word_start t.input t.cursor
    | `Arrow `Right when ctrl || List.mem `Meta mods ->
      t.cursor <- next_word_end t.input t.cursor
    | `Backspace -> delete_back t
    | `Delete -> delete_forward t
    | `Arrow `Left -> move_left t
    | `Arrow `Right -> move_right t
    | `Arrow `Up when List.mem `Shift mods -> t.scroll <- t.scroll + 1
    | `Arrow `Down when List.mem `Shift mods -> t.scroll <- max 0 (t.scroll - 1)
    | `Arrow `Up -> history_move t 1
    | `Arrow `Down -> history_move t (-1)
    | `Home -> t.cursor <- 0
    | `End -> t.cursor <- String.length t.input
    | `Tab -> complete t
    | `Page `Up -> t.scroll <- t.scroll + page
    | `Page `Down -> t.scroll <- max 0 (t.scroll - page)
    | `ASCII c when ctrl ->
      (* notty delivers Ctrl-C as 'C' (0x43) with a Ctrl modifier, not 0x03. *)
      let c = if c >= 'A' && c <= 'Z' then Char.lowercase_ascii c else c in
      (match c with
       | 'c' | '\003' -> ctrl_c t
       | 'd' | '\004' ->
         if t.input = "" then begin
           t.running <- false;
           t.submitted <- None
         end
       | 'a' -> t.cursor <- 0
       | 'e' -> t.cursor <- String.length t.input
       | 'u' ->
         if t.turn_active && t.input = "" && t.queued <> [] then begin
           match withdraw_queued t with
           | Some line ->
             append t
               (Par_code_ui.textf "  \xe2\x8f\xb3 withdrawn: %s"
                  (preview_text line)
                  ~style:(Par_code_ui.style ~dim:true ()))
           | None -> ()
         end else kill_to_start t
       | 'k' -> kill_to_end t
       | 'w' -> kill_word t
       | 'r' -> search_begin t
       | 'o' -> toggle_last_block t
       | 'x' -> toggle_select_mode t
       | _ -> ())
    | `ASCII c ->
      (* Control keys arrive as bare ASCII codes (Tab = 0x09, Ctrl-C = 0x03),
         not as a modified key: normalize them here. *)
      (match c with
       | '\t' -> complete t
       | '\003' -> ctrl_c t
       | '\004' ->
         if t.input = "" then begin
           t.running <- false;
           t.submitted <- None
         end
       | '\001' -> t.cursor <- 0
       | '\005' -> t.cursor <- String.length t.input
       | '\021' -> kill_to_start t
       | '\013' -> kill_to_end t
       | '\023' -> kill_word t
       | _ when Char.code c < 0x20 -> ()
       | _ -> put_back t (String.make 1 c))
    | `Uchar u ->
      let b = Buffer.create 4 in
      let s = Uchar.to_int u in
      let add c = Buffer.add_char b (Char.chr c) in
      if s < 0x80 then add s
      else if s < 0x800 then begin
        add (0xC0 lor (s lsr 6));
        add (0x80 lor (s land 0x3F))
      end else if s < 0x10000 then begin
        add (0xE0 lor (s lsr 12));
        add (0x80 lor ((s lsr 6) land 0x3F));
        add (0x80 lor (s land 0x3F))
      end else begin
        add (0xF0 lor (s lsr 18));
        add (0x80 lor ((s lsr 12) land 0x3F));
        add (0x80 lor ((s lsr 6) land 0x3F));
        add (0x80 lor (s land 0x3F))
      end;
      put_back t (Buffer.contents b)
    | _ -> ()
  else
    match k with
    | `ASCII ('x' | 'X') when List.mem `Ctrl mods -> toggle_select_mode t
    | `Escape when t.select_mode ->
      t.select_mode <- false;
      t.sel <- None;
      t.selecting <- false
    | `ASCII ('q' | 'Q') -> t.running <- false
    | `ASCII 'j' -> t.scroll <- max 0 (t.scroll - 1)
    | `ASCII 'k' -> t.scroll <- t.scroll + 1
    | `ASCII 'g' -> t.scroll <- 0
    | `Arrow `Up -> t.scroll <- t.scroll + 1
    | `Arrow `Down -> t.scroll <- max 0 (t.scroll - 1)
    | `Page `Up -> t.scroll <- t.scroll + page
    | `Page `Down -> t.scroll <- max 0 (t.scroll - page)
    | _ ->
      t.last_key <-
        (match k with
         | `ASCII c -> String.make 1 c
         | `Uchar u -> Printf.sprintf "U+%04X" (Uchar.to_int u)
         | _ -> "special")
  end

let frame_sig (t : t) : string =
  let sel =
    match t.sel with
    | None -> ""
    | Some ((a, b), (c, d)) -> Printf.sprintf "%d,%d:%d,%d" a b c d
  in
  Printf.sprintf "%d|%d|%d|%d|%s|%d|%d|%s|%s|%s|%b|%b|%b|%s|%b|%d|%b"
    (List.length t.transcript) (String.length t.partial) t.scroll
    (List.length t.tool_block) t.status t.menu_index (List.length t.menu)
    t.activity t.header t.composer_label (t.picker <> None)
    (t.modal <> None) t.editing sel t.select_mode
    (List.length t.queued) t.turn_active

let render (t : t) =
  t.last_sig <- frame_sig t;
  (* v0.15.4: a SIGWINCH arriving mid-write interrupts the terminal write, and
     any frame-building fault is just a lost frame. Neither is worth the
     session: clear the signature so the next pass repaints and carry on. *)
  try Notty_unix.Term.image t.term (frame t)
  with _ -> t.last_sig <- ""

(** During a turn the REPL's own reader is not running. This drains pending
    events and reports an interrupt key (Esc, or Ctrl-C) without touching the
    input line; every other key is ignored. Modals keep their own reader. *)
(* One place for pointer scrolling: the wheel steps by three lines, a drag
   scrolls by however far the finger moved (content follows the finger). *)
(* v0.15.6: turn a mouse position into (transcript line, display column).
   [view] is set every frame; rows outside the body clamp to its edges so a
   drag can run past the bottom of the screen and still extend. *)
let body_point (t : t) (x, y) : Par_code_selection.point option =
  match t.view with
  | None -> None
  | Some (first, top, height) ->
    let y = max top (min (top + height - 1) y) in
    Some (first + (y - top), max 0 (x - gutter))

let selection_text (t : t) : string =
  match t.sel with
  | None -> ""
  | Some (a, b) ->
    let lines = all_runs t ~cols:(content_cols t) in
    Par_code_selection.text_of_lines lines a b

let copy_selection (t : t) =
  match t.sel with
  | None -> ()
  | Some (a, b) when a = b -> t.sel <- None
  | Some (a, b) ->
    let text = selection_text t in
    if text = "" then t.sel <- None
    else begin
      (match Par_code_clipboard.copy_any text with
       | Ok () ->
         append t
           (Par_code_ui.textf "  \xe2\x9c\x93 copied %d characters"
              (Par_code_selection.char_count text)
              ~style:(Par_code_ui.style ~fg:Par_code_ui.Green ~dim:true ()))
       | Error e ->
         append t
           (Par_code_ui.textf "  \xe2\x9a\xa0 clipboard unavailable: %s" e
              ~style:(Par_code_ui.style ~fg:Par_code_ui.Yellow ())));
      t.sel <- Some (a, b)
    end

let handle_mouse (t : t) (m : Notty.Unescape.mouse) =
  match m with
  | `Press (`Scroll `Up), _, _ -> t.scroll <- t.scroll + 3
  | `Press (`Scroll `Down), _, _ -> t.scroll <- max 0 (t.scroll - 3)
  | `Press `Left, pos, mods ->
    if t.select_mode || List.mem `Shift mods then begin
      (match body_point t pos with
       | Some p ->
         t.sel <- Some (p, p);
         t.selecting <- true;
         t.drag_y <- None
       | None -> ())
    end else begin
      (match t.drag_y with
       | Some last ->
         let delta = snd pos - last in
         if delta <> 0 then t.scroll <- max 0 (t.scroll + delta)
       | None -> ());
      t.drag_y <- Some (snd pos)
    end
  | `Drag, pos, _ ->
    if t.selecting then begin
      (match t.sel, body_point t pos with
       | Some (a, _), Some p -> t.sel <- Some (a, p)
       | _ -> ())
    end else begin
      (match t.drag_y with
       | Some last ->
         let delta = snd pos - last in
         if delta <> 0 then t.scroll <- max 0 (t.scroll + delta)
       | None -> ());
      t.drag_y <- Some (snd pos)
    end
  | `Release, _, _ ->
    if t.selecting then begin
      t.selecting <- false;
      copy_selection t
    end else t.drag_y <- None
  | _ -> ()

(* v0.15.4: a font-size change makes the terminal send SIGWINCH, and an
   interrupted [Unix.select] raises EINTR. That used to escape as an uncaught
   exception and kill the session. A signal means "check the terminal again",
   so report "no data" and let the caller re-check [Term.pending]. *)
let select_ready (fd : Unix.file_descr) (timeout : float) : bool =
  try
    let r, _, _ = Unix.select [ fd ] [] [] timeout in
    r <> []
  with Unix.Unix_error (Unix.EINTR, _, _) -> false

let poll_interrupt ?(handle_keys = true) (t : t) : bool =
  if t.modal <> None then false
  else begin
    let read_fd, _ = Notty_unix.Term.fds t.term in
    let hit = ref false in
    let page = 10 in
    (* v0.15.6: a modal opened by the turn itself takes over the keyboard; the
       ticker must stop reading so the two event loops cannot fight over the
       terminal. *)
    let failed = ref false in
    while
      t.running && (not !failed) && t.modal = None
      && (Notty_unix.Term.pending t.term || select_ready read_fd 0.0)
    do
      (try
         (match Notty_unix.Term.event t.term with
          | `Key ((`Escape, _) as k) when not t.select_mode ->
            ignore k;
            hit := true
          | `Key ((`ASCII c, mods) as k)
            when (c = 'c' || c = 'C') && List.mem `Ctrl mods ->
            ignore k;
            note_turn_interrupt t;
            hit := true
          | `Key k ->
            (* v0.15.6: typing is allowed during a turn; Enter hands the line to
               the steer hook instead of the (idle) REPL reader. Commands that
               are not turns pass [~handle_keys:false] so typing is not
               swallowed into a submit nobody reads. *)
            if handle_keys then handle_key t ~page k
          | `Mouse m -> if handle_keys then handle_mouse t m
          | _ -> ())
       with exn ->
         failed := true;
         Printf.eprintf "[tui] poll: %s\n%!" (Printexc.to_string exn))
    done;
    !hit
  end

(* One pass of the UI loop: drain input, let [tick] update state, render.
   Waiting goes through [Unix.select] with a real timeout: a keystroke wakes the
   loop immediately, and an idle prompt costs one wakeup every 50ms instead of
   a spin. *)
let picker_key (p : picker) (k : Notty.Unescape.special)
    (set_answer : string option -> unit) =
  let n = List.length p.p_items in
  match k with
  | `Arrow `Up -> p.p_index <- max 0 (p.p_index - 1)
  | `Arrow `Down -> p.p_index <- min (max 0 (n - 1)) (p.p_index + 1)
  | `Page `Up -> p.p_index <- max 0 (p.p_index - 10)
  | `Page `Down -> p.p_index <- min (max 0 (n - 1)) (p.p_index + 10)
  | `Enter -> (match List.nth_opt p.p_items p.p_index with Some v -> set_answer (Some v) | None -> ())
  | `Escape -> set_answer None
  | _ -> ()

let pump (t : t) ~(tick : t -> unit) =
  let read_fd, _ = Notty_unix.Term.fds t.term in
  let changed = ref false in
  let ready =
    if t.running && not (Notty_unix.Term.pending t.term) then
      select_ready read_fd 0.05
    else true
  in
  (* A terminal can deliver an escape sequence in several writes (Termux ships
     the ESC of a mouse report apart from the rest). Settling for a few
     milliseconds lets notty parse the whole sequence instead of reporting the
     bare ESC and typing the tail into the input line. *)
  (* v0.15.4: wait for the input to go quiet (up to 30ms) instead of a fixed
     8ms. Termux splits a mouse report across writes; a half-read sequence used
     to be reported as separate keys and typed into the input line. *)
  if ready && t.running then begin
    let quiet = ref false in
    let deadline = Unix.gettimeofday () +. 0.03 in
    while (not !quiet) && Unix.gettimeofday () < deadline do
      if not (select_ready read_fd 0.004) then quiet := true
    done
  end;
  while t.running && (Notty_unix.Term.pending t.term || select_ready read_fd 0.0) do
    changed := true;
    (try
       match Notty_unix.Term.event t.term with
    | `End -> t.running <- false
    | `Resize _ -> ()
    | `Key (k, mods) ->
      (match t.picker with
       | Some p ->
         (match k with
          | #Notty.Unescape.special as sp ->
            picker_key p sp (fun answer ->
                p.p_answer <- answer;
                if answer = None then t.picker <- None)
          | _ -> ())
       | None ->
         let _, h = Notty_unix.Term.size t.term in
         handle_key t ~page:(max 1 (h / 2)) (k, mods);
         refresh_menu t)
    | `Mouse m -> handle_mouse t m
    | `Paste _ -> ()
     with Unix.Unix_error (Unix.EINTR, _, _) -> ())
  done;
  if t.running then begin
    tick t;
    (* v0.15.4: repaint only when the frame actually changed. The loop wakes
       every 50ms, so an unconditional render redrew the same picture ~20 times
       a second — that is the flicker seen on a phone. *)
    if !changed || frame_sig t <> t.last_sig then render t
  end

let run (t : t) ~(tick : t -> unit) : unit =
  Fun.protect
    ~finally:(fun () -> Notty_unix.Term.release t.term)
    (fun () -> while t.running do pump t ~tick done)

(* Read one line through the frame. Returns [None] when the screen is closing. *)
let read_line (t : t) ~(prompt : string) : string option =
  set_prompt t prompt;
  t.input <- "";
  t.cursor <- 0;
  t.menu <- [];
  t.menu_index <- 0;
  t.submitted <- None;
  t.scroll <- 0;
  t.editing <- true;
  let rec loop () =
    if not t.running then None
    else
      match t.submitted with
      | Some line ->
        t.editing <- false;
        t.submitted <- None;
        history_push t line;
        Some line
      | None ->
        pump t ~tick:(fun _ -> ());
        loop ()
  in
  loop ()

let stop (t : t) = t.running <- false

(* In-frame modal. Returns the chosen key, or None on Esc. *)
let rec ask (t : t) ~(title : string) ~(body : string list)
    ~(options : (string * string) list) : string option =
  let bold = Par_code_ui.style ~bold:true () in
  ask_styled t ~title ~body:(List.map (fun s -> (s, bold)) body) ~options

(** v0.15.6: the same modal with per-line styles, used by the edit approval so
    a diff reads red/green. *)
and ask_styled (t : t) ~(title : string)
    ~(body : (string * Par_code_ui.style) list)
    ~(options : (string * string) list) : string option =
  t.modal <- Some { title; body; options };
  t.modal_answer <- None;
  let rec loop () =
    if not t.running then None
    else
      match t.modal_answer with
      | Some k ->
        t.modal_answer <- None;
        Some k
      | None ->
        if t.modal = None then None
        else begin
          pump t ~tick:(fun _ -> ());
          loop ()
        end
  in
  loop ()

(** A scrollable list picker: [Some item] on Enter, [None] on Esc. *)
let pick (t : t) ~(title : string) ~(items : string list) ~(initial : int) :
    string option =
  if items = [] then None
  else begin
    let p =
      { p_title = title;
        p_items = items;
        p_index = max 0 (min initial (List.length items - 1));
        p_answer = None }
    in
    t.picker <- Some p;
    let rec loop () =
      if not t.running then None
      else
        match p.p_answer, t.picker with
        | Some v, _ ->
          t.picker <- None;
          Some v
        | None, None -> None
        | None, Some _ ->
          pump t ~tick:(fun _ -> ());
          loop ()
    in
    loop ()
  end

(* Kill signals do not run [at_exit], so a SIGTERM used to leave the shell in
   raw mode with the alt screen still owned. The handler touches nothing but
   syscalls: write the restore sequence, put the tty attributes back, then die
   from SIGKILL (calling [exit] here would run at_exit under an interrupted
   lock, which hangs). *)
let restore_tty (t : t) : unit =
  let seq =
    "\027[?1049l\027[?25h\027[?1000l\027[?1002l\027[?1006l\027[?2004l\027[0m"
  in
  (try ignore (Unix.write_substring Unix.stdout seq 0 (String.length seq))
   with Unix.Unix_error _ -> ());
  (match t.saved_tty with
   | Some io ->
     (try Unix.tcsetattr Unix.stdin Unix.TCSANOW io with Unix.Unix_error _ -> ())
   | None -> ())

let install_cleanup (t : t) : unit =
  List.iter
    (fun (sig_ : int) ->
       try
         Sys.set_signal sig_
           (Sys.Signal_handle
              (fun _ ->
                 restore_tty t;
                 (try Unix.kill (Unix.getpid ()) Sys.sigkill with _ -> ())))
       with Invalid_argument _ -> ())
    [ Sys.sigterm; Sys.sighup ]

let close (t : t) =
  t.running <- false;
  Notty_unix.Term.release t.term

(* v0.15.0: suspend/resume existed for /dev/tty modals under the line
   interface; the frame owns every prompt now. *)
