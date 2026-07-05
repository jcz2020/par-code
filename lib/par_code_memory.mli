(* par_code_memory.mli — Project memory layer for par-code v0.3.0.
 *
 * SQLite-backed memory entries with FTS5 full-text search, per-project
 * scoping, and markdown export. Memories are stored in the same par.db
 * database (Path A: PAR SDK 0.6.9+ exposes raw_sqlite3_db) or a dedicated
 * memory.db (Path C fallback).
 *
 * The memory index (top-K by recency + frequency) is auto-injected into the
 * agent's system prompt at session start. The LLM can call recall_memory for
 * full-content retrieval via FTS5 BM25 ranking. *)

(** Opaque handle to the memory database. *)
type t

(** Memory entry categories. *)
type kind = Preference | Convention | Insight | Gotcha | Task_map

(** A single memory entry. *)
type memory = {
  id : int;
  project_id : string;
  kind : kind;
  content : string;
  summary : string;
  citations : string list;
  created_at : float;
  updated_at : float;
  last_used_at : float option;
  usage_count : int;
  source : [`Manual | `Agent | `Import];
}

(** A conversation history search result with highlighted snippet. *)
type history_hit = {
  session_id : string;
  snippet : string;
  updated_at : float;
  turn_count : int;
}

(** {2 Lifecycle} *)

val open_db : unit -> (t, [> `Db_error of string]) result
(** Open the memory database. Uses the same file as [Par_code_config.db_path ()]
    (i.e. [~/.par/par.db]). Enables WAL mode for concurrent access with PAR's
    connection. Calls [ensure_schema] to create tables if needed. *)

val close : t -> unit
(** Close the database handle. Idempotent. *)

(** {2 Schema} *)

val resolve_project_id : unit -> string
(** Resolve the current project's stable identifier.
    If inside a git repo, returns the repo root ([git rev-parse --show-toplevel]).
    Otherwise falls back to [Sys.getcwd ()]. *)

val ensure_schema : t -> (unit, [> `Db_error of string]) result
(** Create the memory tables, FTS5 virtual table, and sync triggers if they
    do not already exist. Idempotent — safe to call on every [open_db]. *)

(** {2 CRUD} *)

val add : t -> project_id:string -> kind:kind -> content:string ->
          summary:string -> citations:string list -> source:[< `Manual | `Agent | `Import] ->
          (int, [> `Db_error of string]) result
(** Insert a new memory entry. Returns the row id. *)

val forget : t -> id:int -> (unit, [> `Db_error of string]) result
(** Delete a memory entry by id. The FTS5 trigger auto-removes it from the
    full-text index. *)

val list : t -> project_id:string -> ?limit:int -> unit ->
           (memory list, [> `Db_error of string]) result
(** List memories for a project, ordered by [updated_at DESC].
    @param limit defaults to 50. *)

val recall : t -> project_id:string -> query:string -> ?limit:int -> unit ->
             (memory list, [> `Db_error of string]) result
(** Full-text search via FTS5 MATCH. Returns memories ranked by BM25.
    User query is sanitized (special FTS5 characters escaped) to prevent
    syntax errors. After fetching, bumps [usage_count] on each result.
    @param limit defaults to 5. *)

val bump_usage : t -> id:int -> unit
(** Increment [usage_count] and set [last_used_at] for a memory.
    Silent best-effort — errors are swallowed. *)

(** {2 Export} *)

val render_index : t -> project_id:string -> string
(** Compact markdown index of memories for injection into the system prompt.
    Groups by kind, one line per memory: [- #id (kind) — summary].
    Capped at 200 lines. Returns empty string if no memories exist. *)

val export_markdown : t -> project_id:string -> string
(** Full MEMORY.md export with YAML-style frontmatter per entry.
    Groups by kind. Includes summary, content, citations, and usage stats. *)

(** {2 Maintenance} *)

val prune_stale : t -> project_id:string -> older_than_days:float ->
                  (int, [> `Db_error of string]) result
(** Delete memories with [usage_count = 0] and [updated_at] older than the
    given threshold. Returns the count of deleted rows. *)

val search_history : t -> query:string -> ?limit:int -> unit ->
                     (history_hit list, [> `Db_error of string]) result
(** Full-text search of conversation history via FTS5 MATCH on the
    [conversations_fts] virtual table. Returns session snippets with
    highlighted matches, ranked by BM25 relevance.
    @param limit defaults to 10. *)
