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
  fg_attr ++ bg_attr ++ style_attr

(* ------------------------------------------------------------------ *)
(* Screen state                                                        *)
(* ------------------------------------------------------------------ *)

type modal = {
  title : string;
  body : string list;
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

type t = {
  term : Notty_unix.Term.t;
  mutable transcript : Notty.image list;  (* oldest first *)
  mutable partial : string;               (* line being streamed *)
  mutable status : string;
  mutable scroll : int;                   (* lines up from the bottom *)
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
    status = "";
    scroll = 0;
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
    picker = None;
    busy = "";
    menu = [];
    menu_index = 0;
    files = None;
    menu_token = None;
    menu_suppress = false;
    search = None }

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
let display_width (u : Uchar.t) =
  match Uucp.Break.tty_width_hint u with w when w > 0 -> w | _ -> 1

let wrap_runs ~(cols : int) (runs : (string * Par_code_ui.style) list) :
    (string * Par_code_ui.style) list list =
  let cols = max 8 cols in
  let out = ref [] in
  let cur = ref [] in
  let used = ref 0 in
  let flush_line () =
    out := List.rev !cur :: !out;
    cur := [];
    used := 0
  in
  List.iter
    (fun (txt, sty) ->
       let piece = Buffer.create (String.length txt) in
       let flush_piece () =
         if Buffer.length piece > 0 then begin
           cur := (Buffer.contents piece, sty) :: !cur;
           Buffer.clear piece
         end
       in
       let break_if_needed w =
         if !used > 0 && !used + w > cols then begin
           flush_piece ();
           flush_line ()
         end
       in
       let folder () _i = function
         | `Uchar u ->
           break_if_needed (display_width u);
           Uutf.Buffer.add_utf_8 piece u;
           used := !used + display_width u
         | `Malformed s ->
           break_if_needed 1;
           Buffer.add_string piece s;
           incr used
       in
       ignore (Uutf.String.fold_utf_8 folder () txt);
       flush_piece ())
    runs;
  if !cur <> [] || !out = [] then flush_line ();
  List.rev !out

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

let to_notty_lines ~(cols : int) (img : Par_code_ui.image) : Notty.image list =
  let open Notty in
  List.concat_map
    (fun runs ->
       List.map
         (fun (runs : (string * Par_code_ui.style) list) ->
            match runs with
            | [] -> I.empty
            | _ ->
              I.hcat
                (List.map
                   (fun (txt, sty) -> I.string (attr_of_style sty) txt)
                   runs))
         (List.concat_map (wrap_runs ~cols) (split_runs runs)
          |> List.map trim_trailing_spaces))
    (Par_code_ui.lines img)

let wrap_text ~cols (s : string) : string list =
  wrap_runs ~cols [ (s, Par_code_ui.no_style) ]
  |> List.map (fun runs -> String.concat "" (List.map fst runs))

let to_notty ~cols (img : Par_code_ui.image) : Notty.image =
  let open Notty in
  match to_notty_lines ~cols img with [] -> I.empty | ls -> I.vcat ls

let width (t : t) = fst (Notty_unix.Term.size t.term)

(* The transcript stores one entry per *line*, not per image: a multi-line
   image used to count as a single entry, so pagination and scrolling were off
   by however many lines it had. *)
let append (t : t) (img : Par_code_ui.image) =
  t.transcript <- t.transcript @ to_notty_lines ~cols:(width t - 2) img

(* v0.14.0 S1b: a frame is not a scroll buffer — one huge tool output must not
   push everything else out. Cap the lines taken from a single image and mark
   the cut. *)
let max_lines_per_image = 60

let append_truncated (t : t) (img : Par_code_ui.image) =
  let lines = to_notty_lines ~cols:(width t - 2) img in
  let n = List.length lines in
  let kept =
    if n <= max_lines_per_image then lines
    else begin
      let rec take k l =
        if k <= 0 then [] else match l with [] -> [] | h :: tl -> h :: take (k - 1) tl
      in
      take max_lines_per_image lines
      @ [ to_notty ~cols:(width t - 2)
            (Par_code_ui.textf "… (%d more lines)" (n - max_lines_per_image)) ]
    end
  in
  t.transcript <- t.transcript @ kept

let append_text (t : t) (s : string) =
  append t (Par_code_ui.text s)

(* v0.15.1: the streamed half line, replaced wholesale by the REPL on every
   chunk so the frame shows text as it arrives. *)
let set_partial (t : t) (s : string) = t.partial <- s

(* Streaming: [feed] extends the partial line, [end_line] commits it. *)
let feed (t : t) (s : string) = t.partial <- t.partial ^ s

let end_line (t : t) =
  if t.partial <> "" then begin
    append_text t t.partial;
    t.partial <- ""
  end

let set_status (t : t) (s : string) = t.status <- s

(** A transient line shown before the status text while a turn runs. *)
let set_busy (t : t) (s : string) = t.busy <- s

let line_count (t : t) = List.length t.transcript

(* ------------------------------------------------------------------ *)
(* Input line                                                          *)
(* ------------------------------------------------------------------ *)

let set_prompt (t : t) (p : string) = t.prompt <- p

let put_back (t : t) (s : string) =
  t.input <- String.sub t.input 0 t.cursor ^ s
             ^ String.sub t.input t.cursor (String.length t.input - t.cursor);
  t.cursor <- t.cursor + String.length s

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

let visible_lines (t : t) ~(height : int) : Notty.image list =
  let all =
    if t.partial = "" then t.transcript
    else t.transcript @ [ to_notty ~cols:(width t - 2) (Par_code_ui.text t.partial) ]
  in
  let n = List.length all in
  let start = max 0 (n - height - t.scroll) in
  let start = min start n in
  let rec drop k l = if k <= 0 then l else match l with [] -> [] | _ :: tl -> drop (k - 1) tl in
  let rec take k l = if k <= 0 then [] else match l with [] -> [] | h :: tl -> h :: take (k - 1) tl in
  take height (drop start all)

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
  let input_h = max 1 (min max_input_h n_lines) in
  let first_line = max 0 (min (cursor_line - input_h + 1) (n_lines - input_h)) in
  let menu_rows =
    let n = List.length t.menu in
    let visible = min 6 n in
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
  in
  let menu_h = List.length menu_rows in
  let body_h = max 1 (h - input_h - status_h - 1 - menu_h) in
  let body =
    I.vcat (visible_lines t ~height:body_h)
    |> fun img -> I.vsnap ~align:`Top body_h (I.pad ~l:1 ~r:1 img)
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
                          (if String.length after > 1 then
                             String.sub after 1 (String.length after - 1)
                           else "") ])
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
    let scroll_hint = if t.scroll = 0 then "" else Printf.sprintf "  ↑%d" t.scroll in
    let text =
      match t.busy, t.status with
      | "", s -> s
      | b, "" -> b
      | b, s -> b ^ " · " ^ s
    in
    I.hsnap ~align:`Left w
      (I.string A.(fg lightblack)
         (sanitize_text (" " ^ text ^ scroll_hint ^ hint)))
  in
  let rule =
    I.string A.(fg lightblack) (String.concat "" (List.init w (fun _ -> "─")))
  in
  let body =
    let box ~title ~rows ~footer =
      let inner_w = min (max 32 (w - 12)) 84 in
      let border l r =
        I.string A.empty (l ^ String.concat "" (List.init inner_w (fun _ -> "─")) ^ r)
      in
      let row s =
        I.hcat
          [ I.string A.empty "│"
            ; I.hsnap ~align:`Left inner_w (I.string A.(st bold) (sanitize_text s))
            ; I.string A.empty "│" ]
      in
      let content =
        I.vcat
          (border "┌" "┐"
           :: List.map row title
           @ [ border "├" "┤" ]
           @ List.map row rows
           @ List.map row footer @ [ border "└" "┘" ])
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
               (if i = p.p_index then " ▸ " else "   ") ^ s)
      in
      box ~title:[ " " ^ p.p_title ] ~rows:items
        ~footer:[ "  ↑/↓ move · Enter select · Esc close" ]
    | Some m, _ ->
      let inner_w = min (max 32 (w - 12)) 84 in
      let leading_spaces s =
        let n = ref 0 in
        while !n < String.length s && s.[!n] = ' ' do incr n done;
        !n
      in
      let wrapped s =
        let lead = leading_spaces s in
        let body = String.sub s lead (String.length s - lead) in
        let indent = " " ^ String.make lead ' ' in
        wrap_text ~cols:(max 8 (inner_w - 1 - lead)) body
        |> List.map (fun l -> indent ^ l)
      in
      let legend =
        String.concat "   " (List.map (fun (k, label) -> k ^ ": " ^ label) m.options)
      in
      box ~title:(wrapped m.title) ~rows:(List.concat_map wrapped m.body)
        ~footer:(wrapped legend)
  in
  I.vsnap ~align:`Top body_h body <-> I.vcat menu_rows <-> rule <-> input_line
  <-> status

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

let handle_key (t : t) ~(page : int) ((k, mods) : Notty.Unescape.key) =
  let ctrl = List.mem `Ctrl mods in
  match t.modal, t.search with
  | Some modal, _ ->
    (* A modal owns the keyboard: only its keys, Esc, and Ctrl-C matter. *)
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
     | _ -> ignore ctrl)
  | None, Some _ -> search_handle t k ~ctrl
  | None, None ->
  let ascii = match k with `ASCII c -> Some c | _ -> None in
  if t.csi_drop then begin
    (* Dropping the tail of a split escape sequence (a mouse report arrives as
       ESC + "[<65;83;39M" when the terminal writes it in pieces). *)
    (match ascii with
     | Some c when (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || c = '~' ->
       t.csi_drop <- false
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
  if t.editing then
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
        (* The frame owns the screen: once the input line clears, the message
           the user just sent would be gone. Keep it in the transcript, the way
           a shell keeps the command line it echoed. *)
        match String.trim line with
        | "" -> ()
        | _ ->
          (* v0.15.1 visual pass: a blank line separates the end of one turn
             from the next, and the echo is bold so it reads as the start of a
             turn rather than as more output. *)
          append t (Par_code_ui.text "");
          append t
            (Par_code_ui.textf "\xe2\x80\xba %s" line
               ~style:(Par_code_ui.style ~fg:Par_code_ui.Green ~bold:true ()))
      end
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
       | 'u' -> kill_to_start t
       | 'k' -> kill_to_end t
       | 'w' -> kill_word t
       | 'r' -> search_begin t
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

let render (t : t) = Notty_unix.Term.image t.term (frame t)

(** During a turn the REPL's own reader is not running. This drains pending
    events and reports an interrupt key (Esc, or Ctrl-C) without touching the
    input line; every other key is ignored. Modals keep their own reader. *)
let poll_interrupt (t : t) : bool =
  if t.modal <> None then false
  else begin
    let read_fd, _ = Notty_unix.Term.fds t.term in
    let hit = ref false in
    while
      t.running
      && (Notty_unix.Term.pending t.term
          || (let r, _, _ = Unix.select [ read_fd ] [] [] 0.0 in r <> []))
    do
      (match Notty_unix.Term.event t.term with
       | `Key (`Escape, _) -> hit := true
       | `Key (`ASCII 'c', mods) when List.mem `Ctrl mods -> hit := true
       | _ -> ())
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
  let ready =
    if t.running && not (Notty_unix.Term.pending t.term) then
      let r, _, _ = Unix.select [ read_fd ] [] [] 0.05 in
      r <> []
    else true
  in
  (* A terminal can deliver an escape sequence in several writes (Termux ships
     the ESC of a mouse report apart from the rest). Settling for a few
     milliseconds lets notty parse the whole sequence instead of reporting the
     bare ESC and typing the tail into the input line. *)
  if ready && t.running then ignore (Unix.select [] [] [] 0.008);
  while t.running && (Notty_unix.Term.pending t.term ||
                      (let r, _, _ = Unix.select [ read_fd ] [] [] 0.0 in r <> [])) do
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
    | `Mouse (`Press (`Scroll `Up), _, _) -> t.scroll <- t.scroll + 3
    | `Mouse (`Press (`Scroll `Down), _, _) ->
      t.scroll <- max 0 (t.scroll - 3)
    | `Paste _ -> ()
    | _ -> ()
  done;
  if t.running then begin
    tick t;
    render t
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
let ask (t : t) ~(title : string) ~(body : string list)
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
