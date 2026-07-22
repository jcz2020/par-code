(* par_code_ui_markdown.mli — Streaming markdown to ANSI renderer.
 *
 * Consumes incremental text chunks (e.g., from an LLM token stream) and
 * produces ANSI-styled strings. Designed for an optimistic line-based
 * rendering pattern: incomplete markdown constructs are buffered in [state],
 * and only complete lines are emitted per [push].
 *
 * Reference algorithm: streaming-markdown.js (MIT-licensed, thetarnav).
 *
 * Round-trip property: for any well-formed markdown document [doc],
 * chunking [doc] arbitrarily and folding [push] produces the same output
 * as feeding [doc] in one [push]. This holds because:
 *   1. State carries only [ctx] (code-block flag) and the partial line.
 *   2. Each complete line is rendered independently given [ctx].
 *   3. [flush] renders any trailing partial line identically to a final
 *      line emitted by [push]. *)

(** Parser state. Carries the current markdown context (in a code block?)
    plus any buffered incomplete content. Abstract: callers cannot inspect
    internals. *)
type state

(** Initial state — no markdown context, empty buffer. *)
val initial : state

(** Feed a chunk of text. Returns the new state and the ANSI-rendered
    string for any content that is safe to emit now.

    Invariant: the returned string never contains partial markdown
    syntax — incomplete constructs are buffered in [state]. *)
val push : state -> string -> state * string

(** End of stream. Flush any remaining buffer, closing unclosed
    constructs gracefully (unclosed code block emits remaining content
    with code styling; unclosed inline markers emit literally). *)
val flush : state -> string

(** Reset hook. With the immutable-state API, this is a no-op kept for
    API symmetry with the reference implementation; callers should use
    [initial] for a fresh state when starting a new LLM response. *)
val reset : unit -> unit
