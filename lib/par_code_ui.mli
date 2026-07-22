(** par_code_ui — UI abstraction layer.

    All rendering goes through composable [image] values.  The current
    backend is printf + ANSI escape codes; future TUI backends (Notty,
    Matrix/Mosaic) can implement the same interface without changing
    call sites.

    Design principle: the image/style/backend types must be 1:1
    mappable to Notty's [I.image] / [A.attr] and Matrix's
    [Image.t] / [Style.t]. *)

(** {1 Types} *)

(** Terminal color.  ANSI 16 + 256-palette + 24-bit true color. *)
type color =
  | Default
  | Black | Red | Green | Yellow | Blue | Magenta | Cyan | White
  | Bright of color  (** Bright Black, Bright Red, ... *)
  | Palette of int   (** 0–255 *)
  | Rgb of int * int * int  (** 24-bit true color *)

(** Visual style.  Combine fields record-style. *)
type style = {
  fg : color option;
  bg : color option;
  bold : bool;
  italic : bool;
  underline : bool;
  dim : bool;         (** aka "faint" — ANSI SGR code 2 *)
  reverse : bool;     (** aka "inverse" — ANSI SGR code 7 *)
}

(** Styled text rectangle.  Immutable. *)
type image

(** Backend handle — holds terminal state (output channels, color
    capability, cached dimensions). *)
type backend

(** {1 Styles} *)

(** No style — default terminal rendering. *)
val no_style : style

(** Construct a style with named optional fields.  Unspecified fields
    default to [false] / [None]. *)
val style :
  ?fg:color -> ?bg:color ->
  ?bold:bool -> ?italic:bool -> ?underline:bool ->
  ?dim:bool -> ?reverse:bool ->
  unit -> style

(** {1 Primitives} *)

(** Empty image (zero width, zero height). *)
val empty : image

(** Single-line styled text.  Does not wrap. *)
val text : ?style:style -> string -> image

(** Printf-style formatted single-line text.
    Example: [textf ~style:s "count: %d" n] *)
val textf : ?style:style -> ('a, Format.formatter, unit, image) format4 -> 'a

(** {1 Composition} *)

(** Horizontal composition — [left <|> right]. *)
val ( <|> ) : image -> image -> image

(** Vertical composition — [top <-> bottom]. *)
val ( <-> ) : image -> image -> image

(** Horizontal concatenation — [hcat \[a; b; c\]] = [a <|> b <|> c]. *)
val hcat : image list -> image

(** Vertical concatenation — [vcat \[a; b; c\]] = [a <-> b <-> c]. *)
val vcat : image list -> image

(** {1 Layout} *)

(** Pad horizontally.  [hpad left right img] adds [left] spaces on
    the left and [right] spaces on the right. *)
val hpad : int -> int -> image -> image

(** Pad vertically.  [vpad top bottom img] adds [top] blank lines
    above and [bottom] blank lines below. *)
val vpad : int -> int -> image -> image

(** Snap to target width.  Crops if wider, pads if narrower.
    Default [align = `Left]. *)
val hsnap : ?align:[`Left | `Center | `Right] -> int -> image -> image

(** Snap to target height.  Crops if taller, pads if shorter.
    Default [align = `Top]. *)
val vsnap : ?align:[`Top | `Middle | `Bottom] -> int -> image -> image

(** {1 Dimensions} *)

(** Width in columns (longest line). *)
val width : image -> int

(** Height in rows (number of lines). *)
val height : image -> int

(** {1 Backend} *)

(** Create a backend.  Auto-detects TTY, [NO_COLOR] env var
    ({https://no-color.org}), and [TERM=dumb]. *)
val create_backend : unit -> backend

(** Render image to terminal (no trailing newline). *)
val render : backend -> image -> unit

(** Render image followed by a newline. *)
val render_line : backend -> image -> unit

(** Read a line from stdin with a prompt.  Flushes stdout before
    reading stdin.  Returns [None] on EOF. *)
val read_line : backend -> prompt:image -> string option

(** Terminal size [(columns, rows)].  Falls back to [(80, 24)] if
    detection fails. *)
val get_size : backend -> int * int

(** Whether the backend renders color. *)
val supports_color : backend -> bool

(** Release terminal resources (no-op for the printf backend). *)
val close : backend -> unit

(** {1 High-level rendering} *)

val render_error : backend -> string -> unit
val render_warning : backend -> string -> unit
val render_notice : backend -> string -> unit
val render_success : backend -> string -> unit

(** Render a PAR SDK LLM response chunk.  Handles all 5 variants:
    - [Text_delta]: feeds through markdown state machine
    - [Tool_call_start]: shows "calling X..." indicator
    - [Tool_call_delta]: no-op (could show spinner)
    - [Usage_update]: no-op (could update live counter)
    - [Done]: flushes markdown state *)
val render_llm_chunk : backend -> Par.Types.llm_response_chunk -> unit

(** Render a PAR SDK tool event.  Handles [Tool_invoked]/[completed]/[failed]/[progress],
    [Bash_invoked]/[completed].  Other events are no-ops. *)
val render_tool_event : backend -> Par.Types.event -> unit

(** Cost summary for session display. *)
type cost_summary = {
  llm_calls : int;
  prompt_tokens : int;
  completion_tokens : int;
  total_tokens : int;
  context_tokens : int;
  turn_count : int;
  metrics : (string * int) list;
}

val render_cost : backend -> cost_summary -> unit
val render_session_info : backend -> agent_id:string -> session_id:string -> turn_count:int -> unit
val render_banner : backend -> version:string -> unit
val render_prompt : backend -> unit
val render_help : backend -> unit

(** Simple fixed-width column table renderer. *)
val render_table : backend -> headers:string list -> rows:string list list -> unit

(** Flush pending markdown content and reset the parser state.
    Call this when an LLM response ends abnormally (error path) to avoid
    stale content garbling the next response. The [Done] chunk handles
    this automatically; this function is for error paths that bypass [Done]. *)
val flush_markdown : backend -> unit
