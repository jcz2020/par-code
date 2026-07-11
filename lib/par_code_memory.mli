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

val open_db : unit -> (t, [> `Db_error of string]) result

val close : t -> unit

val resolve_project_id : unit -> string

val add : t -> project_id:string -> kind:kind -> content:string ->
          summary:string -> citations:string list -> source:[< `Manual | `Agent | `Import] ->
          (string, [> `Db_error of string]) result

val forget : t -> id:string -> (unit, [> `Db_error of string]) result

val list : t -> project_id:string -> ?limit:int -> unit ->
           (memory list, [> `Db_error of string]) result

val recall : t -> project_id:string -> query:string -> ?limit:int -> unit ->
             (memory list, [> `Db_error of string]) result

val bump_usage : t -> id:string -> unit

val render_index : t -> project_id:string -> string

val export_markdown : t -> project_id:string -> string

val prune_stale : t -> project_id:string -> older_than_days:float ->
                  (int, [> `Db_error of string]) result

val search_history : t -> query:string -> ?limit:int -> unit ->
                     (history_hit list, [> `Db_error of string]) result
