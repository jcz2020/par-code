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

type t = {
  term : Notty_unix.Term.t;
  mutable transcript : Notty.image list;  (* oldest first *)
  mutable partial : string;               (* line being streamed *)
  mutable status : string;
  mutable scroll : int;                   (* lines up from the bottom *)
  mutable running : bool;
  mutable last_key : string;
}

let create () : t =
  { term = Notty_unix.Term.create ();
    transcript = [];
    partial = "";
    status = "";
    scroll = 0;
    running = true;
    last_key = "" }

let to_notty_lines (img : Par_code_ui.image) : Notty.image list =
  let open Notty in
  List.map
    (fun (runs : (string * Par_code_ui.style) list) ->
       I.hcat (List.map (fun (txt, sty) -> I.string (attr_of_style sty) txt) runs))
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
  let status_h = 1 in
  let body_h = max 1 (h - status_h) in
  let body = I.vcat (visible_lines t ~height:body_h) in
  let scroll_hint =
    if t.scroll = 0 then "" else Printf.sprintf " ↑%d " t.scroll
  in
  let status =
    let hint =
      if t.last_key = "" then "" else Printf.sprintf "  [%s]" t.last_key
    in
    I.hsnap ~align:`Left w
      (I.hcat
         [ I.string A.(st reverse) " par "
           ; I.string A.empty (" " ^ t.status ^ scroll_hint ^ hint) ])
  in
  I.vsnap ~align:`Top body_h body <-> status

let handle_key (t : t) ~(page : int) (k : Notty.Unescape.key) =
  match k with
  | (`ASCII ('q' | 'Q'), _) -> t.running <- false
  | (`ASCII 'j', _) -> t.scroll <- max 0 (t.scroll - 1)
  | (`ASCII 'k', _) -> t.scroll <- t.scroll + 1
  | (`ASCII 'g', _) -> t.scroll <- 0
  | `Arrow `Up, _ -> t.scroll <- t.scroll + 1
  | `Arrow `Down, _ -> t.scroll <- max 0 (t.scroll - 1)
  | `Page `Up, _ -> t.scroll <- t.scroll + page
  | `Page `Down, _ -> t.scroll <- max 0 (t.scroll - page)
  | (k, _) ->
    t.last_key <-
      (match k with
       | `ASCII c -> String.make 1 c
       | `Uchar u -> Printf.sprintf "U+%04X" (Uchar.to_int u)
       | _ -> "special")

let render (t : t) = Notty_unix.Term.image t.term (frame t)

(* ------------------------------------------------------------------ *)
(* Loop                                                                *)
(* ------------------------------------------------------------------ *)

let run (t : t) ~(tick : t -> unit) : unit =
  Fun.protect
    ~finally:(fun () -> Notty_unix.Term.release t.term)
    (fun () ->
       let read_fd, _ = Notty_unix.Term.fds t.term in
       let input_ready () =
         let r, _, _ = Unix.select [ read_fd ] [] [] 0.0 in
         r <> []
       in
       while t.running do
         while t.running && (Notty_unix.Term.pending t.term || input_ready ()) do
           match Notty_unix.Term.event t.term with
           | `End -> t.running <- false
           | `Resize _ -> ()
           | `Key (k, mods) ->
             let _, h = Notty_unix.Term.size t.term in
             handle_key t ~page:(max 1 (h / 2)) (k, mods)
           | _ -> ()
         done;
         if t.running then begin
           tick t;
           render t;
           Unix.sleepf 0.05
         end
       done)

let stop (t : t) = t.running <- false
