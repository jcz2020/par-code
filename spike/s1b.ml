(* S1b demo: the existing render_* functions write into the screen through the
   sink backend, and one oversized image is truncated with a marker. *)

let () =
  let screen = Par_code_screen.create () in
  let ui = Par_code_ui.create_screen_backend ~sink:(fun img ->
      Par_code_screen.append_truncated screen img)
  in
  Par_code_screen.set_status screen "screen backend · build · 0 tok";
  (* These are the real helpers the REPL uses everywhere. *)
  Par_code_ui.render_notice ui "par-code S1b — render_* into the frame";
  Par_code_ui.render_success ui "session ready";
  Par_code_ui.render_warning ui "this warning went through render_warning";
  Par_code_ui.render_error ui "and this error through render_error";
  let big =
    List.init 70 (fun i -> Par_code_ui.text (Printf.sprintf "tool output line %03d" i))
  in
  Par_code_ui.render_line ui (Par_code_ui.vcat big);
  Par_code_ui.render_notice ui "after the oversized block";
  Par_code_screen.set_status screen "screen backend · build · 0 tok";
  Par_code_screen.run screen ~tick:(fun _ -> ())
