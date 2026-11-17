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
(** Frame loop: drain keys, call [tick], render. Keys: q quits, j/k and
    Up/Down scroll one line, PgUp/PgDn a page, g returns to the bottom. *)

val stop : t -> unit
