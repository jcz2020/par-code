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

val drop_mouse_tail : string -> string
(** Remove a trailing mouse-report fragment (["<35;12;4M"]) that arrived
    without its escape sequence; such a tail used to be typed into the input
    line when a terminal delivered the report in pieces. *)

val append_tool_line : t -> name:string -> key:string -> Par_code_ui.image -> unit
(** Collect a tool line for the current turn; folded into one block on flush.
    [key] is the call's task id, so its result can replace this exact row. *)

val fold_plan : int -> int * int * int
(** How a block of [n] tool lines is folded: (head, hidden, tail). *)

val activity : t -> string
(** Name of the tool running right now ("" when none). *)

val replace_tool_line : t -> key:string -> Par_code_ui.image -> unit
(** Swap the start row of that call for its result (falls back to the last row
    when no row carries the key). *)

val flush_tools : t -> unit
(** Commit the collected tool lines to the transcript, folding long runs. *)

val feed : t -> string -> unit
(** Extend the line currently being streamed. *)

val end_line : t -> unit
(** Commit the streamed line to the transcript. *)

val set_partial : t -> string -> unit
(** The half line being streamed, shown after the transcript; empty clears it. *)

val width : t -> int
(** Current terminal width in columns. *)

val set_header : t -> string -> unit
(** Title line at the top of the frame; "" hides it. *)

val set_composer_label : t -> string -> unit
(** Label on the composer's top border (the mode); "" hides the border. *)

val set_status : t -> string -> unit

val set_turn_active : t -> bool -> unit
(** v0.15.6: mark a turn as running. While it is, the input line stays
    editable and Enter queues the line instead of submitting to the REPL
    reader. *)

val queue_prompt : t -> string -> unit
(** Remember a line typed during a turn; the dock shows it and the REPL
    delivers it (inside the turn when possible, otherwise as the next turn). *)

val take_queued : t -> string list
(** Remove and return every queued prompt, oldest first. *)

val withdraw_queued : t -> string option
(** Remove and return the newest queued prompt (Ctrl-U). *)

val queued_count : t -> int

val set_busy : t -> string -> unit(** Transient text (a spinner, elapsed time) shown before the status line while
    a turn runs. Empty clears it. *)

val status_right_hint :
  modal_open:bool ->
  busy:string ->
  turn_active:bool ->
  has_input:bool ->
  left_w:int ->
  width:int ->
  string
(** The right edge of the status bar. A modal owns Esc, so it shows a deny hint
    instead of the turn's interrupt hint. *)

val take_cancel_request : t -> bool
(** True once after Ctrl-C was pressed inside a modal during a turn; the REPL
    ticker turns it into a turn cancellation. *)

val clear_cancel_request : t -> unit
(** Drop a stale request at the start of a turn. *)

val line_count : t -> int
(** Lines currently in the transcript, including the streamed half line (for
    tests and the scroll ceiling). *)

val scroll_after_layout :
  scroll:int -> total:int -> body:int -> prev_total:int -> prev_body:int -> int
(** [scroll_after_layout ~scroll ~total ~body ~prev_total ~prev_body] keeps a
    scrolled-up viewport on the same transcript line when a stream, a resize
    or an input-line change alters the frame. A viewport at the bottom
    (scroll = 0) keeps following new output. Exposed for unit tests. *)

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

val poll_interrupt : ?handle_keys:bool -> t -> bool(** While a turn runs (the REPL reader is idle), drain pending events and report
    whether Esc or Ctrl-C was pressed. Non-interrupt keys are handled only when
    [handle_keys] is true (a turn); commands pass false so typed text is not
    swallowed into a submit nobody reads. A modal keeps its own reader and is
    left alone. *)


val stop : t -> unit

val ask :
  t ->
  title:string ->
  body:string list ->
  options:(string * string) list ->
  string option
(** In-frame modal: returns the key the user pressed (a member of [options]),
    or [None] when Esc dismisses it. Blocks until answered. *)

val ask_styled :
  t ->
  title:string ->
  body:(string * Par_code_ui.style) list ->
  options:(string * string) list ->
  string option
(** v0.15.6: the modal with per-line styles (red/green diff rows). *)

val load_history : t -> path:string -> unit
(** Load prompt history from [path] (oldest line first on disk) and remember it
    so later entries are saved back there. *)

val pick : t -> title:string -> items:string list -> initial:int -> string option
(** A scrollable list picker: Up/Down move, Enter selects (returns the item),
    Esc returns [None]. Blocks until answered. *)

val close : t -> unit
(** Release the terminal (alt-screen off, cursor restored). [run] does this
    itself; call it explicitly when the caller drives [read_line] directly. *)

val install_cleanup : t -> unit
(** Release the terminal on SIGTERM/SIGHUP before exiting. [at_exit] does not run
    for those signals, so without this the shell is left in raw mode. *)

val wrap_text : cols:int -> string -> string list
(** Wrap one string to [cols] display columns (CJK/emoji count two) and return
    the resulting lines. *)

val wrap_runs :
  cols:int ->
  (string * Par_code_ui.style) list ->
  (string * Par_code_ui.style) list list
(** Wrap one logical line of styled runs to [cols] display columns, on word
    boundaries, keeping a list item's hang indent. *)
