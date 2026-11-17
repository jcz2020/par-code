(* S0 spike (docs/v0.14.0-ROADMAP.md): can notty drive a full-screen frame,
   read keys and survive a resize inside this terminal?

   Deliberately single-threaded: the UI loop owns the terminal and polls
   [Term.pending] instead of blocking on [Term.event]. Agent turns will later
   push state from Eio fibers into a shared cell, so the terminal is only ever
   touched by this one loop. *)

let hello = "中文对齐测试：表格 | 状态 | 退出"
let emoji = "emoji: 🚀 ✅ 🧪 | CJK: 终端界面"

let frame ~w ~h ~count ~last_key ~resizes =
  let open Notty in
  let open Notty.I in
  let title = I.string A.(st bold) "par-code S0 spike" in
  let body =
    I.vcat
      [ title;
        I.string A.empty (Printf.sprintf "size: %dx%d" w h);
        I.string A.empty (Printf.sprintf "frames: %d" count);
        I.string A.empty (Printf.sprintf "last key: %s" last_key);
        I.string A.empty (Printf.sprintf "resizes: %d" resizes);
        I.string A.empty hello;
        I.string A.empty emoji;
        I.string A.empty "press q to quit, arrows are captured" ]
  in
  let bar =
    I.hcat
      [ I.string A.(st reverse) " TUI "
        ; I.string A.empty (Printf.sprintf " %dx%d " w h)
        ; I.string A.(st reverse) " q: quit " ]
  in
  let status_height = 1 in
  let body_height = max 1 (h - status_height) in
  I.vsnap ~align:`Top body_height body
  <->
  I.hsnap ~align:`Left w bar

let () =
  let term = Notty_unix.Term.create () in
  Fun.protect
    ~finally:(fun () -> Notty_unix.Term.release term)
    (fun () ->
       let running = ref true in
       let count = ref 0 in
       let last_key = ref "-" in
       let resizes = ref 0 in
       let read_fd, _write_fd = Notty_unix.Term.fds term in
       let input_ready () =
         (* [Term.pending] only reports events already parsed; raw bytes sit in
            the fd unread, so the readable check is the one that matters. *)
         let r, _, _ = Unix.select [ read_fd ] [] [] 0.0 in
         r <> []
       in
       while !running do
         (* Drain every pending event without blocking. *)
         while !running && (Notty_unix.Term.pending term || input_ready ()) do
           match Notty_unix.Term.event term with
           | `End -> running := false
           | `Resize (w, h) ->
             incr resizes;
             last_key := Printf.sprintf "resize %dx%d" w h
           | `Key ((`ASCII ('q' | 'Q'), _)) -> running := false
           | `Key (k, mods) ->
             let name =
               match k with
               | `ASCII c -> Printf.sprintf "%c" c
               | `Uchar u -> Printf.sprintf "U+%04X" (Uchar.to_int u)
               | _ -> "special"
             in
             let mods =
               List.map (function `Ctrl -> "C" | `Meta -> "M" | `Shift -> "S") mods
             in
             last_key := (if mods = [] then name else String.concat "-" mods ^ "-" ^ name)
           | _ -> ()
         done;
         if !running then begin
           let w, h = Notty_unix.Term.size term in
           Notty_unix.Term.image term (frame ~w ~h ~count:!count ~last_key:!last_key ~resizes:!resizes);
           incr count;
           Unix.sleepf 0.05
         end
       done)
