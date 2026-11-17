(** v0.14.0 S1 — the Notty screen.

    Owns the terminal (alt-screen) and renders a transcript plus a one-line
    status bar. One thread drives it; agent turns and streaming callbacks only
    append. The S0 spike established that input must be detected through
    [Term.fds] readability — [Term.pending] alone never sees raw bytes. *)

type t

val create : unit -> t
(** Enter the alternate screen. [run] releases it. *)

val append : t -> Par_code_ui.image -> unit
(** Add an image to the transcript (one or more lines). *)

val append_truncated : t -> Par_code_ui.image -> unit
(** Like {!append} but caps a single image at 60 lines with a "… (N more lines)"
    marker, so one large tool output cannot push the session out of view. *)

val append_text : t -> string -> unit

val feed : t -> string -> unit
(** Extend the line currently being streamed. *)

val end_line : t -> unit
(** Commit the streamed line to the transcript. *)

val set_status : t -> string -> unit

val line_count : t -> int
(** Lines currently in the transcript (for tests and the status bar). *)

val run : t -> tick:(t -> unit) -> unit
(** Frame loop: drain keys, call [tick], render. In browsing mode q quits and
    j/k, Up/Down, PgUp/PgDn scroll. *)

val read_line : t -> prompt:string -> string option
(** Read one line through the frame (cursor, history, Tab completion). [None]
    means the screen was closed. An empty string means the line was cancelled
    (Ctrl-C). *)

val pump : t -> tick:(t -> unit) -> unit
(** One UI pass; useful from streaming callbacks that need to repaint while an
    agent turn is blocked in [invoke]. *)

val render : t -> unit


val stop : t -> unit

val suspend : t -> unit
(** Release the terminal so a /dev/tty modal can run. *)

val resume : t -> unit
(** Recreate the terminal and repaint after {!suspend}. *)

val ask :
  t ->
  title:string ->
  body:string list ->
  options:(string * string) list ->
  string option
(** In-frame modal: returns the key the user pressed (a member of [options]),
    or [None] when Esc dismisses it. Blocks until answered. *)

val close : t -> unit
(** Release the terminal (alt-screen off, cursor restored). [run] does this
    itself; call it explicitly when the caller drives [read_line] directly. *)
