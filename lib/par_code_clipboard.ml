(* par_code_clipboard — put text on the terminal's clipboard.

   A full-screen TUI cannot use a command that owns the tty, so the portable
   route is OSC 52: the terminal emulator itself receives the text and writes
   its own clipboard. Termux (the primary target) implements it. There is no
   way to know whether the emulator honoured the sequence, so the caller shows
   a notice either way. *)

let base64_table =
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

let base64 (s : string) : string =
  let n = String.length s in
  let b = Buffer.create ((n + 2) / 3 * 4) in
  let i = ref 0 in
  while !i < n do
    let c1 = Char.code s.[!i] in
    let c2 = if !i + 1 < n then Char.code s.[!i + 1] else 0 in
    let c3 = if !i + 2 < n then Char.code s.[!i + 2] else 0 in
    Buffer.add_char b base64_table.[c1 lsr 2];
    Buffer.add_char b base64_table.[((c1 land 0x3) lsl 4) lor (c2 lsr 4)];
    Buffer.add_char b
      (if !i + 1 < n then base64_table.[((c2 land 0xF) lsl 2) lor (c3 lsr 6)]
       else '=');
    Buffer.add_char b (if !i + 2 < n then base64_table.[c3 land 0x3F] else '=');
    i := !i + 3
  done;
  Buffer.contents b

(** The escape sequence a terminal reads as "copy this to the clipboard". *)
let osc52 (s : string) : string = "\027]52;c;" ^ base64 s ^ "\007"

(** Hand [s] to the terminal. Returns an error only when writing fails. *)
let copy (s : string) : (unit, string) result =
  try
    output_string stdout (osc52 s);
    flush stdout;
    Ok ()
  with Sys_error e -> Error e

(* v0.15.6: when the Termux API helper is installed it writes the real system
   clipboard directly; otherwise the terminal emulator handles OSC 52. the
   helper is not on every install (it needs the termux-api package), so this
   stays a fallback, not the primary path. *)
let termux_clipboard_bin = "/data/data/com.termux/files/usr/bin/termux-clipboard-set"

let command_available path =
  Sys.file_exists path && (try Unix.access path [ Unix.X_OK ]; true with _ -> false)

let copy_via_command path (s : string) : (unit, string) result =
  try
    let r, w = Unix.pipe () in
    (* The child must not inherit the write end: with it open, [cat] would
       never see EOF on its stdin and waitpid would block forever. *)
    Unix.set_close_on_exec w;
    let devnull = Unix.openfile "/dev/null" Unix.[ O_RDONLY ] 0 in
    let pid = Unix.create_process path [| path |] r devnull devnull in
    Unix.close r;
    Unix.close devnull;
    let oc = Unix.out_channel_of_descr w in
    (try output_string oc s with _ -> ());
    close_out_noerr oc;
    let _, status = Unix.waitpid [] pid in
    match status with
    | Unix.WEXITED 0 -> Ok ()
    | Unix.WEXITED n -> Error (Printf.sprintf "exit %d" n)
    | Unix.WSIGNALED n -> Error (Printf.sprintf "signal %d" n)
    | Unix.WSTOPPED n -> Error (Printf.sprintf "stopped %d" n)
  with Unix.Unix_error (e, _, _) -> Error (Unix.error_message e)

(** Prefer the Termux clipboard helper when present; fall back to OSC 52. *)
let copy_any (s : string) : (unit, string) result =
  if command_available termux_clipboard_bin then
    match copy_via_command termux_clipboard_bin s with
    | Ok () -> Ok ()
    | Error _ -> copy s
  else copy s
