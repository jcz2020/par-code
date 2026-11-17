(* S2 demo: read_line through the frame — typing, Tab completion, history,
   cursor movement. The REPL will drive exactly this loop. *)

let () =
  let screen = Par_code_screen.create () in
  let ui =
    Par_code_ui.create_screen_backend ~sink:(fun img ->
        Par_code_screen.append_truncated screen img)
  in
  Par_code_ui.render_notice ui
    "Type a line and press Enter. Tab completes, Up recalls history, Ctrl-C cancels, \"exit\" quits.";
  let rec loop () =
    Par_code_screen.set_status screen
      (Printf.sprintf "S2 · lines=%d · build" (Par_code_screen.line_count screen));
    match Par_code_screen.read_line screen ~prompt:"(build) par> " with
    | None -> ()
    | Some "" ->
      Par_code_ui.render_warning ui "[cancelled]";
      loop ()
    | Some "exit" -> Par_code_ui.render_notice ui "[bye]"
    | Some line ->
      Par_code_ui.render_notice ui ("echo: " ^ line);
      loop ()
  in
  Fun.protect ~finally:(fun () -> Par_code_screen.close screen) loop
