(* par_code_memory.mli — v0.3.3: storage delegated to PAR SDK Sqlite_memory. *)

type t

type kind = Preference | Convention | Insight | Gotcha | Task_map

type memory = {
  id : string;
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

type history_hit = {
  session_id : string;
  snippet : string;
  updated_at : float;
  turn_count : int;
}

val open_db : ?embedding_fn:Par_memory.Memory_service.embedding_fn ->
  ?dimension:int ->
  unit -> (t, [> `Db_error of string]) result

val close : t -> unit

val raw_db : t -> Sqlite3.db

val resolve_project_id : unit -> string

val add : t -> project_id:string -> kind:kind -> content:string ->
          summary:string -> citations:string list -> source:[< `Manual | `Agent | `Import] ->
          (string, [> `Db_error of string]) result

val forget : t -> id:string -> (unit, [> `Db_error of string]) result

val list : t -> project_id:string -> ?limit:int -> unit ->
           (memory list, [> `Db_error of string]) result

val recall : t -> project_id:string -> query:string -> ?limit:int -> unit ->
             (memory list, [> `Db_error of string]) result

val render_index : t -> project_id:string -> string

val export_markdown : t -> project_id:string -> string

val prune_stale : t -> project_id:string -> older_than_days:float ->
                  (int, [> `Db_error of string]) result

val prune_stale_dry_run : t -> project_id:string -> older_than_days:float ->
                          (int, [> `Db_error of string]) result

type storage_stats = {
  page_size : int;
  page_count : int;
  freelist_count : int;
  free_bytes : int;
  auto_vacuum : int;  (* 0 = off, 1 = full, 2 = incremental *)
}
(** v0.16.0: page-level picture of the shared database file. *)

val storage_stats : t -> (storage_stats, [> `Db_error of string]) result

val reclaim :
  t ->
  mode:[ `Incremental | `Full ] ->
  (storage_stats * storage_stats, [> `Db_error of string]) result
(** v0.16.0: release pages left on the freelist by deleted sessions/memories.
    [`Incremental] releases the freelist in place (and switches the database to
    auto_vacuum=INCREMENTAL first, which needs one full rewrite); [`Full] always
    runs VACUUM. Returns the stats before and after. *)

val resolve_memory_id : t -> project_id:string -> string ->
                        (string, string) result

val search_history : t -> query:string -> ?limit:int -> unit ->
                     (history_hit list, [> `Db_error of string]) result
