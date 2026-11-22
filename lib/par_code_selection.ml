(* par_code_selection — which cells a mouse selection covers, and the text in
   them. Pure: the screen owns the coordinates; this module answers column
   questions and rewrites styled runs for the highlight. *)

type point = int * int
(* (transcript line, zero-based display column). Lines count wrapped rows, the
   same coordinates [par_code_screen.visible_runs] paints in. *)

type runs = (string * Par_code_ui.style) list
type line = runs

let width_of (u : Uchar.t) : int =
  match Uucp.Break.tty_width_hint u with w when w > 0 -> w | _ -> 1

let text_width (s : string) : int =
  let w = ref 0 in
  let folder () _ (v : [ `Malformed of string | `Uchar of Uchar.t ]) =
    match v with
    | `Malformed _ -> ()
    | `Uchar u -> w := !w + width_of u
  in
  ignore (Uutf.String.fold_utf_8 folder () s);
  !w

(** UTF-8 codepoints, not bytes: "copied 7 characters" must match what the
    user sees when the text is Chinese. *)
let char_count (s : string) : int =
  Uutf.String.fold_utf_8 (fun n _ _ -> n + 1) 0 s

(** Order two points so the first is the start. *)
let normalize (a : point) (b : point) : point * point =
  if a <= b then (a, b) else (b, a)

(** The column span selected on [line], or [None] when the line is outside the
    selection. The last line of a selection has a real end column; every line
    before it is selected to its end. *)
let line_span (a : point) (b : point) (line : int) : (int * int) option =
  let (la, ca), (lb, cb) = normalize a b in
  if line < la || line > lb then None
  else
    Some
      ( (if line = la then ca else 0),
        (if line = lb then cb else max_int) )

(* One pass over a line's codepoints, tracking display columns. *)
let iter_cells (runs : runs)
    (f : Uchar.t -> col:int -> width:int -> unit) : unit =
  let col = ref 0 in
  List.iter
    (fun (txt, _) ->
       let folder () _ (v : [ `Malformed of string | `Uchar of Uchar.t ]) =
         match v with
         | `Malformed _ -> ()
         | `Uchar u ->
           let w = width_of u in
           f u ~col:!col ~width:w;
           col := !col + w
       in
       ignore (Uutf.String.fold_utf_8 folder () txt))
    runs

(** Rewrite [runs] so every character that overlaps [[from, to_) is reversed
    in the terminal. Wide characters count whole: a cell of a CJK glyph selects
    the glyph. *)
let select_runs (runs : runs) ~(from : int) ~(to_ : int) : runs =
  if from >= to_ then runs
  else begin
    let out = ref [] in
    let buf = Buffer.create 32 in
    let selected = ref false in
    let col = ref 0 in
    let flush sty =
      if Buffer.length buf > 0 then begin
        let sty =
          if !selected then { sty with Par_code_ui.reverse = true } else sty
        in
        out := (Buffer.contents buf, sty) :: !out;
        Buffer.clear buf
      end
    in
    List.iter
      (fun (txt, sty) ->
         let folder () _ (v : [ `Malformed of string | `Uchar of Uchar.t ]) =
           match v with
           | `Malformed _ -> ()
           | `Uchar u ->
             let w = width_of u in
             let here = !col in
             col := here + w;
             let hit = here < to_ && here + w > from in
             if hit <> !selected then begin
               flush sty;
               selected := hit
             end;
             Uutf.Buffer.add_utf_8 buf u
         in
         ignore (Uutf.String.fold_utf_8 folder () txt);
         flush sty)
      runs;
    List.rev !out
  end

(** The text covered by the selection on one line. *)
let text_of_runs (runs : runs) ~(from : int) ~(to_ : int) : string =
  let b = Buffer.create 64 in
  iter_cells runs (fun u ~col ~width ->
      if col < to_ && col + width > from then Uutf.Buffer.add_utf_8 b u);
  Buffer.contents b

(** Join the selected part of every covered line with newlines. *)
let text_of_lines (lines : line list) (a : point) (b : point) : string =
  let parts = ref [] in
  List.iteri
    (fun i line ->
       match line_span a b i with
       | None -> ()
       | Some (from, to_) ->
         parts := text_of_runs line ~from ~to_ :: !parts)
    lines;
  String.concat "\n" (List.rev !parts)
