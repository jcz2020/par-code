(* S3 demo: the in-frame modal. Opens a bash-approval box and prints the answer
   into the transcript, exactly as the REPL's prompt_permission will. *)

let () =
  let screen = Par_code_screen.create () in
  let ui =
    Par_code_ui.create_screen_backend ~sink:(fun img ->
        Par_code_screen.append_truncated screen img)
  in
  Par_code_ui.render_notice ui "S3 — in-frame modal test";
  Par_code_ui.set_modal_hook
    (Some (fun ~title ~body ~options ->
         Par_code_screen.ask screen ~title ~body ~options));
  let answer =
    Par_code_ui.prompt_permission ~backend:ui
      ~command:"touch /tmp/modal-demo"
      ~reason:"the approval policy requires a human here"
      ~always_pattern:"touch *" ()
  in
  (match answer with
   | Some k -> Par_code_ui.render_success ui ("answer: " ^ k)
   | None -> Par_code_ui.render_warning ui "dismissed");
  Par_code_screen.run screen ~tick:(fun _ -> ())
