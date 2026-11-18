(** Self-update logic for [par upgrade].
    eio-based HTTP; atomic replace with smoke-test + rollback. *)

(** Return the current version string. *)
val current_version : unit -> string

(** [is_newer ~latest ~current] is true only when [latest] is strictly newer,
    comparing dotted numbers and ignoring a pre-release suffix. *)
val is_newer : latest:string -> current:string -> bool

(** Fetch the latest release tag from GitHub.
    Honors [PAR_MIRROR], [PAR_NO_UPDATE_CHECK], and cache at
    [~/.par/.latest-cache.json] with 24h TTL.
    Default timeout 2.0s. *)
val fetch_latest_tag :
  ?timeout:float -> unit ->
  (string, [> `Http of string | `Offline ]) result

(** Download, verify, and install a new version.
    [~target] overrides the version to install (default: latest).
    Returns the installed version string on success. *)
val perform_upgrade :
  ?target:string -> unit ->
  (string, [> `Download_failed of string | `Checksum_mismatch
           | `Smoke_test_failed of string ]) result

(** Atomically replace [dst] with [src] using [rename(2)].
    Post-swap smoke test: runs [{dst} --version] with 3s timeout.
    Rolls back on failure. *)
val atomic_replace :
  src:string -> dst:string ->
  (unit, [> `Rename_failed of string ]) result
