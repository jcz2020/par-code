(* S1 demo: drive Par_code_screen with real image values from Par_code_ui.
   Proves the bridge (image -> Notty cells), streaming append, scrolling and the
   status bar, without touching the REPL yet. *)

let () =
  let screen = Par_code_screen.create () in
  let open Par_code_ui in
  Par_code_screen.set_status screen "model gpt-test · build · 0 tok";
  Par_code_screen.append screen
    (text ~style:(style ~bold:true ()) "par-code S1 — transcript bridge");
  Par_code_screen.append screen (text "");
  Par_code_screen.append screen
    (textf "✓ session ready at %s" (Sys.getcwd ())
       ~style:(style ~fg:Green ()));
  Par_code_screen.append screen
    (textf "⚠ a warning line with a 中文 tail" ~style:(style ~fg:Yellow ()));
  Par_code_screen.append screen
    (text ~style:(style ~fg:Cyan ~bold:true ()) "→ lsp...");
  Par_code_screen.append screen
    (text ~style:(style ~dim:true ()) "  → lsp ✓ (17.5ms)");
  for i = 1 to 30 do
    Par_code_screen.append_text screen
      (Printf.sprintf "history line %02d — 中文内容 with 颜色 %s" i
         (if i mod 3 = 0 then "green" else "plain"))
  done;
  (* Streaming: chunks arrive, the partial line grows, then it is committed. *)
  let words = [ "Streaming"; "works:"; "each"; "chunk"; "appends"; "to"; "the";
                "partial"; "line, "; "then"; "end_line"; "commits"; "it." ] in
  let fed = ref 0 in
  let quit = ref false in
  Par_code_screen.run screen ~tick:(fun _ ->
      if (not !quit) && !fed < List.length words then begin
        Par_code_screen.feed screen (List.nth words !fed ^ " ");
        incr fed;
        Par_code_screen.set_status screen
          (Printf.sprintf "streaming %d/%d · build · 128 tok" !fed
             (List.length words));
        if !fed = List.length words then begin
          Par_code_screen.end_line screen;
          Par_code_screen.set_status screen "done · build · 129 tok";
          quit := true
        end
      end)
