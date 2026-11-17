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

type t = {
  mutable term : Notty_unix.Term.t;
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
  mutable hist_pos : int option;
  mutable submitted : string option;
  mutable editing : bool;          (* keys go to the input line *)
  mutable last_ctrl_c : float option;
  mutable suspended : bool;
  mutable modal : modal option;
  mutable modal_answer : string option;
}

let create () : t =
  { term = Notty_unix.Term.create ~mouse:true ~bpaste:true ();
    transcript = [];
    partial = "";
    status = "";
    scroll = 0;
    running = true;
    last_key = "";
    input = "";
    cursor = 0;
    prompt = "> ";
    history = [];
    hist_pos = None;
    submitted = None;
    editing = false;
    last_ctrl_c = None;
    suspended = false;
    modal = None;
    modal_answer = None }

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

let to_notty_lines (img : Par_code_ui.image) : Notty.image list =
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
         (split_runs runs))
    (Par_code_ui.lines img)

let to_notty (img : Par_code_ui.image) : Notty.image =
  let open Notty in
  match to_notty_lines img with [] -> I.empty | ls -> I.vcat ls

(* The transcript stores one entry per *line*, not per image: a multi-line
   image used to count as a single entry, so pagination and scrolling were off
   by however many lines it had. *)
let append (t : t) (img : Par_code_ui.image) =
  t.transcript <- t.transcript @ to_notty_lines img

(* v0.14.0 S1b: a frame is not a scroll buffer — one huge tool output must not
   push everything else out. Cap the lines taken from a single image and mark
   the cut. *)
let max_lines_per_image = 60

let append_truncated (t : t) (img : Par_code_ui.image) =
  let lines = to_notty_lines img in
  let n = List.length lines in
  let kept =
    if n <= max_lines_per_image then lines
    else begin
      let rec take k l =
        if k <= 0 then [] else match l with [] -> [] | h :: tl -> h :: take (k - 1) tl
      in
      take max_lines_per_image lines
      @ [ to_notty
            (Par_code_ui.textf "… (%d more lines)" (n - max_lines_per_image)) ]
    end
  in
  t.transcript <- t.transcript @ kept

let append_text (t : t) (s : string) =
  append t (Par_code_ui.text s)

(* Streaming: [feed] extends the partial line, [end_line] commits it. *)
let feed (t : t) (s : string) = t.partial <- t.partial ^ s
let end_line (t : t) =
  if t.partial <> "" then begin
    append_text t t.partial;
    t.partial <- ""
  end

let set_status (t : t) (s : string) = t.status <- s

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

let complete (t : t) =
  let text = t.input in
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

let history_push (t : t) (line : string) =
  if String.trim line <> "" then begin
    t.history <- line :: List.filter (fun h -> h <> line) t.history;
    t.history <- List.filteri (fun i _ -> i < 200) t.history
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
    else t.transcript @ [ to_notty (Par_code_ui.text t.partial) ]
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
  let input_h = 1 in
  let status_h = 1 in
  let body_h = max 1 (h - input_h - status_h) in
  let body = I.vcat (visible_lines t ~height:body_h) in
  let input_line =
    let before = String.sub t.input 0 t.cursor in
    let after = String.sub t.input t.cursor (String.length t.input - t.cursor) in
    I.hsnap ~align:`Left w
      (I.hcat
         [ I.string A.(st bold) (sanitize_text (t.prompt ^ before))
           ; I.string A.(st reverse) (if after = "" then " " else sanitize_text (String.sub after 0 1))
           ; I.string A.empty
               (if String.length after > 1 then String.sub after 1 (String.length after - 1)
                else "") ])
  in
  let status =
    let hint =
      if t.last_key = "" then "" else Printf.sprintf "  [%s]" t.last_key
    in
    let scroll_hint = if t.scroll = 0 then "" else Printf.sprintf " ↑%d" t.scroll in
    I.hsnap ~align:`Left w
      (I.hcat
         [ I.string A.(st reverse) " par "
           ; I.string A.empty (sanitize_text (" " ^ t.status ^ scroll_hint ^ hint)) ])
  in
  let body =
    match t.modal with
    | None -> body
    | Some m ->
      (* Box drawn over the body area: title, content, key legend. *)
      let inner_w = min (max 32 (w - 12)) 84 in
      let border l r =
        I.string A.empty (l ^ String.concat "" (List.init inner_w (fun _ -> "─")) ^ r)
      in
      (* Pad by display width, not bytes: "⚠" is one column but three bytes, and
         manual padding made the right border ragged. *)
      let row s =
        I.hcat
          [ I.string A.empty "│"
            ; I.hsnap ~align:`Left inner_w (I.string A.(st bold) (sanitize_text s))
            ; I.string A.empty "│" ]
      in
      let legend =
        String.concat "   " (List.map (fun (k, label) -> k ^ ": " ^ label) m.options)
      in
      let content =
        I.vcat
          (border "┌" "┐"
           :: [ row (" " ^ m.title) ]
           @ [ border "├" "┤" ]
           @ List.map (fun l -> row (" " ^ l)) m.body
           @ [ row (" " ^ legend); border "└" "┘" ])
      in
      I.vsnap ~align:`Middle body_h (I.hsnap ~align:`Middle w content)
  in
  I.vsnap ~align:`Top body_h body <-> input_line <-> status

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
  match t.modal with
  | Some modal ->
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
  | None ->
  if t.editing then
    match k with
    | `Enter ->
      t.submitted <- Some t.input;
      t.editing <- false
    | `Escape ->
      t.input <- "";
      t.cursor <- 0
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

let render (t : t) = Notty_unix.Term.image t.term (frame t)

(* One pass of the UI loop: drain input, let [tick] update state, render.
   Waiting goes through [Unix.select] with a real timeout: a keystroke wakes the
   loop immediately, and an idle prompt costs one wakeup every 50ms instead of
   a spin. *)
let pump (t : t) ~(tick : t -> unit) =
  let read_fd, _ = Notty_unix.Term.fds t.term in
  if t.running && not (Notty_unix.Term.pending t.term) then
    ignore (Unix.select [ read_fd ] [] [] 0.05);
  while t.running && (Notty_unix.Term.pending t.term ||
                      (let r, _, _ = Unix.select [ read_fd ] [] [] 0.0 in r <> [])) do
    match Notty_unix.Term.event t.term with
    | `End -> t.running <- false
    | `Resize _ -> ()
    | `Key (k, mods) ->
      let _, h = Notty_unix.Term.size t.term in
      handle_key t ~page:(max 1 (h / 2)) (k, mods)
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

let close (t : t) =
  t.running <- false;
  Notty_unix.Term.release t.term

(* v0.14.0 S2: a modal that reads /dev/tty (approval, /distill) cannot work
   while the alt-screen owns the terminal. Release it, let the modal run, then
   recreate and repaint. The transcript lives in memory, so nothing is lost. *)
let suspend (t : t) =
  if not t.suspended then begin
    (try Notty_unix.Term.release t.term with _ -> ());
    t.suspended <- true
  end

let resume (t : t) =
  if t.suspended then begin
    t.term <- Notty_unix.Term.create ~mouse:true ~bpaste:true ();
    t.suspended <- false;
    render t
  end
