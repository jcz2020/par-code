(** Self-update logic for [par upgrade].
    eio-based HTTP; atomic replace with smoke-test + rollback. *)

(** Return the current version string. *)
val current_version : unit -> string

(** [is_newer ~latest ~current] is true only when [latest] is strictly newer,
    comparing dotted numbers and ignoring a pre-release suffix. *)
val is_newer : latest:string -> current:string -> bool

(** What an upgrade request should do. Decided without the network so the
    guard rails are testable. [Current_is_ahead] means the running version is
    newer than the release (local build or yanked tag) and must not be
    replaced. *)
type decision =
  | Already_current
  | Current_is_ahead
  | Newer_available of string
  | Downgrade of string

(** [decide_upgrade ~current ~resolved ~explicit] classifies an upgrade to
    [resolved]. [explicit] is true when the user named the version with
    [--to]; only then can a downgrade proceed. *)
val decide_upgrade :
  current:string -> resolved:string -> explicit:bool -> decision

(** Fetch the latest release tag from GitHub.
    Honors [PAR_MIRROR], [PAR_NO_UPDATE_CHECK], and cache at
    [~/.par/.latest-cache.json] with 24h TTL.
    Default timeout 2.0s.
    Never call this on the startup path: it touches the network. *)
val fetch_latest_tag :
  ?timeout:float -> unit ->
  (string, [> `Http of string | `Offline ]) result

(** Cache-only view for startup (no network).
    [Some tag] when the cached release tag is newer than [current]. *)
val cached_update_notice : current:string -> string option

(** True when the release cache is missing or older than its 24h TTL. *)
val cache_needs_refresh : unit -> bool

(** Download, verify, and install a new version.
    [~target] overrides the version to install (default: latest).
    Progress lines go to stderr, one per phase.
    Returns [\`Upgraded tag] when a new binary was installed and
    [\`Up_to_date version] when nothing was replaced (already current, or the
    running build is newer than the release). *)
val perform_upgrade :
  ?target:string -> unit ->
  ( [> `Upgraded of string | `Up_to_date of string ],
    [> `Download_failed of string | `Checksum_mismatch
     | `Smoke_test_failed of string | `Rename_failed of string ] )
  result

(** Atomically replace [dst] with [src] using [rename(2)].
    Post-swap smoke test: runs [{dst} --version] with 3s timeout.
    Rolls back on failure. *)
val atomic_replace :
  src:string -> dst:string ->
  (unit, [> `Rename_failed of string ]) result
