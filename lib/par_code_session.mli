(** Session management for par-code.

    Provides listing, loading, and partial-ID resolution for saved sessions
    stored in the SQLite conversations table. *)

open Par

type session_info = {
  id : string;
  event_count : int;
  first_event_at : float;
  last_event_at : float;
}

val format_age : float -> string
(** Human-readable age string ("5m ago", "2h ago", "3d ago"). *)

val list_sessions : limit:int -> (session_info list, string) result
(** List sessions for the current project, newest first.
    Errors include DB failures. Returns empty list if no sessions. *)

val load : string -> (Types.conversation option, string) result
(** Load a full conversation by session ID. Returns [Ok None] if not found. *)

val resolve_id : string -> (string, string) result
(** Resolve a session ID or unique prefix to a full session ID.
    If [prefix] is >= 36 chars, treated as full UUID.
    If shorter, searches for unique prefix match; errors if ambiguous. *)

val resolve_title : string -> string
(** Extract the first user message from a session as its display title.
    Returns "(unavailable)" if the session cannot be loaded. *)

val fork : string -> (string, string) result
(** Fork a session: copy its conversation to a new session ID.
    Returns [Ok new_id] on success. The original session is untouched. *)
