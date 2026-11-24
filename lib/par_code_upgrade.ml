let (let*) = Result.bind

let current_version () = Par_code_version.version

(* v0.15.1: the update notice compared for inequality, so a stale cached tag
   (or any older release) printed "is available" while the running version was
   already newer. Compare numerically instead. *)
let version_components (s : string) : int list =
  let s = String.trim s in
  let s = if s <> "" && s.[0] = 'v' then String.sub s 1 (String.length s - 1) else s in
  let s = match String.index_opt s '-' with Some i -> String.sub s 0 i | None -> s in
  String.split_on_char '.' s |> List.filter_map int_of_string_opt

let is_newer ~(latest : string) ~(current : string) : bool =
  let rec cmp a b =
    match a, b with
    | x :: xs, y :: ys -> if x <> y then compare x y else cmp xs ys
    | x :: _, [] -> compare x 0
    | [], y :: _ -> compare 0 y
    | [], [] -> 0
  in
  cmp (version_components latest) (version_components current) > 0

let cache_path () =
  Filename.concat (Par_code_config.config_dir ()) ".latest-cache.json"

let cache_ttl = 24.0 *. 60.0 *. 60.0

type cache_entry = {
  last_checked : float;
  latest_tag : string;
  etag : string option;
}

let read_cache () =
  try
    let path = cache_path () in
    if not (Sys.file_exists path) then None
    else
      let ic = open_in path in
      let s = really_input_string ic (in_channel_length ic) in
      close_in ic;
      let json = Yojson.Safe.from_string s in
      let open Yojson.Safe.Util in
      Some {
        last_checked = json |> member "last_checked" |> to_float;
        latest_tag = json |> member "latest_tag" |> to_string;
        etag = (match json |> member "etag" with `String e -> Some e | _ -> None);
      }
  with _ -> None

let write_cache entry =
  try
    let json = `Assoc [
      ("last_checked", `Float entry.last_checked);
      ("latest_tag", `String entry.latest_tag);
      ("etag", match entry.etag with Some s -> `String s | None -> `Null);
    ] in
    let oc = open_out (cache_path ()) in
    output_string oc (Yojson.Safe.pretty_to_string ~std:true json);
    output_char oc '\n';
    close_out oc
  with _ -> ()

(* Startup must never wait on GitHub: it only reads the cache. A stale or
   missing cache asks for a refresh, which [main.ml] runs in a detached child
   so the first frame is not delayed. *)
let cached_update_notice ~(current : string) : string option =
  match read_cache () with
  | Some c when is_newer ~latest:c.latest_tag ~current -> Some c.latest_tag
  | _ -> None

let cache_needs_refresh () =
  match read_cache () with
  | None -> true
  | Some c -> Unix.gettimeofday () -. c.last_checked >= cache_ttl

let github_host () =
  Option.value ~default:"api.github.com" (Sys.getenv_opt "PAR_MIRROR")

let download_host () =
  Option.value ~default:"github.com" (Sys.getenv_opt "PAR_MIRROR")

let user_agent = "par-code/" ^ Par_code_version.version

let tls_wrapper uri raw_flow =
  let cfg = Lazy.force Par.Http_client.tls_config in
  (* PAR 0.16 dropped [Http_client.tls_host_of_string]; [tls-eio]'s [~host]
     takes a [Domain_name.t], so build it here. An unparsable host keeps the
     SNI-less path rather than silently skipping certificate checks. *)
  match Uri.host uri with
  | None -> Tls_eio.client_of_flow cfg raw_flow
  | Some host ->
    (match Domain_name.of_string host with
     | Ok d ->
       (match Domain_name.host d with
        | Ok h -> Tls_eio.client_of_flow cfg ~host:h raw_flow
        | Error _ -> Tls_eio.client_of_flow cfg raw_flow)
     | Error _ -> Tls_eio.client_of_flow cfg raw_flow)

let make_client net = Cohttp_eio.Client.make ~https:(Some tls_wrapper) net

(* [on_start] receives the advertised Content-Length (when the server sent
   one) and [on_chunk] the running byte count, so a multi-megabyte download
   can report progress instead of looking frozen. Both default to no-ops. *)
let max_body_bytes = 100 * 1024 * 1024

let http_get
    ?(on_start = fun _ -> ())
    ?(on_chunk = fun ~total:_ ~length:_ -> ())
    ~net ~sw ~headers url =
  let read_body ~length resp_body =
    on_start length;
    let buf = Buffer.create 65536 in
    let chunk = Cstruct.create 65536 in
    let total = ref 0 in
    let rec loop () =
      match Eio.Flow.single_read resp_body chunk with
      | 0 -> ()
      | n ->
        total := !total + n;
        if !total > max_body_bytes then
          failwith (Printf.sprintf "response larger than %d bytes" max_body_bytes);
        Buffer.add_string buf (Cstruct.to_string (Cstruct.sub chunk 0 n));
        on_chunk ~total:!total ~length;
        loop ()
      | exception End_of_file -> ()
    in
    loop ();
    Buffer.contents buf
  in
  let rec follow redirects_left url =
    let uri = Uri.of_string url in
    let client = make_client net in
    let hdrs = Cohttp.Header.of_list headers in
    let resp, resp_body =
      Cohttp_eio.Client.call ~sw ~headers:hdrs client `GET uri in
    let status = Cohttp.Code.code_of_status (Http.Response.status resp) in
    let resp_headers = Http.Response.headers resp in
    let etag = Cohttp.Header.get resp_headers "etag" in
    let content_length =
      match Cohttp.Header.get resp_headers "content-length" with
      | Some s -> int_of_string_opt (String.trim s)
      | None -> None in
    match status, redirects_left with
    | (301 | 302 | 303 | 307 | 308), n when n > 0 ->
      (match Cohttp.Header.get resp_headers "location" with
       | Some location -> follow (n - 1) location
       | None ->
         let body = read_body ~length:content_length resp_body in
         (status, etag, content_length, body))
    | _ ->
      let body = read_body ~length:content_length resp_body in
      (status, etag, content_length, body)
  in
  follow 5 url

let fetch_latest_tag_core ~net ~sw ?(timeout=2.0) () =
  let _timeout = timeout in
  let now = Unix.gettimeofday () in
  if Sys.getenv_opt "PAR_NO_UPDATE_CHECK" = Some "1"
  || Sys.getenv_opt "PAR_NO_UPDATE_CHECK" = Some "true" then
    match read_cache () with
    | Some c -> Ok c.latest_tag
    | None -> Error `Offline
  else
    match read_cache () with
    | Some c when now -. c.last_checked < cache_ttl -> Ok c.latest_tag
    | cached ->
      let base = [
        ("User-Agent", user_agent);
        ("Accept", "application/vnd.github.v3+json");
      ] in
      let headers = match cached with
        | Some { etag = Some e; _ } -> ("If-None-Match", e) :: base
        | _ -> base in
      let url = Printf.sprintf "https://%s/repos/jcz2020/par-code/releases/latest"
        (github_host ()) in
      (try
        let (status, etag, _, body) = http_get ~net ~sw ~headers url in
        if status = 304 then
          match cached with
          | Some c ->
            write_cache { c with last_checked = now }; Ok c.latest_tag
          | None -> Error (`Http "304 without cache")
        else if status = 200 then begin
          let json = Yojson.Safe.from_string body in
          let tag = Yojson.Safe.Util.(json |> member "tag_name" |> to_string) in
          write_cache { last_checked = now; latest_tag = tag; etag };
          Ok tag
        end else
          Error (`Http (Printf.sprintf "HTTP %d" status))
      with
      | Eio.Io _ -> Error `Offline
      | exn -> Error (`Http (Printexc.to_string exn)))

let fetch_latest_tag ?timeout () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  fetch_latest_tag_core ~net ~sw ?timeout ()

let detect_platform () =
  let uname_flag =
    try
      let ic = Unix.open_process_in "uname -s" in
      let s = input_line ic in
      ignore (Unix.close_process_in ic);
      s
    with _ -> Sys.os_type in
  let arch_str =
    try
      let ic = Unix.open_process_in "uname -m" in
      let s = input_line ic in
      ignore (Unix.close_process_in ic);
      s
    with _ -> "unknown" in
  match (String.lowercase_ascii uname_flag, String.lowercase_ascii arch_str) with
  | ("linux", "x86_64") -> Ok ("linux-x64", "tar.gz")
  | ("linux", "aarch64") | ("linux", "arm64") -> Ok ("linux-arm64", "tar.gz")
  | ("darwin", "arm64") | ("darwin", "aarch64") -> Ok ("darwin-arm64", "zip")
  | (os, arch) ->
    Error (`Download_failed (Printf.sprintf "Unsupported platform: %s/%s" os arch))

let verify_sha256 ~expected data =
  let computed = Digestif.SHA256.digest_string data |> Digestif.SHA256.to_hex in
  String.lowercase_ascii computed = String.lowercase_ascii (String.trim expected)

let rec rm_rf path =
  if Sys.file_exists path then
    if Sys.is_directory path then begin
      Array.iter (fun e -> rm_rf (Filename.concat path e)) (Sys.readdir path);
      Unix.rmdir path
    end else
      Sys.remove path

let find_par_in dir =
  let found = ref None in
  let rec walk d =
    if Sys.is_directory d then
      Array.iter (fun e ->
        let p = Filename.concat d e in
        if e = "par" && not (Sys.is_directory p) then found := Some p
        else if Sys.is_directory p then walk p
      ) (Sys.readdir d)
  in
  walk dir; !found

let atomic_replace_core ~env ~sw:_ ~src ~dst =
  let old = dst ^ ".old" in
  match Unix.rename dst old with
  | exception Unix.Unix_error (e, _, _) ->
    Error (`Rename_failed (Unix.error_message e))
  | () ->
    (match Unix.rename src dst with
     | exception Unix.Unix_error (e, _, _) ->
       (try Unix.rename old dst with _ -> ());
       Error (`Rename_failed (Unix.error_message e))
     | () ->
       let clock = Eio.Stdenv.clock env in
       let proc_mgr = Eio.Stdenv.process_mgr env in
       let buf = Buffer.create 256 in
       let smoke =
         try
           Eio.Switch.run (fun smoke_sw ->
             let proc = Eio.Process.spawn ~sw:smoke_sw proc_mgr
               ~stdout:(Eio.Flow.buffer_sink buf) [dst; "--version"] in
             Eio.Fiber.first
               (fun () ->
                 match Eio.Process.await proc with
                 | `Exited 0 ->
                   if String.starts_with ~prefix:"par " (Buffer.contents buf)
                   then Ok ()
                   else Error "bad version output"
                 | `Exited n -> Error (Printf.sprintf "exit %d" n)
                 | `Signaled s -> Error (Printf.sprintf "signal %d" s))
               (fun () ->
                 Eio.Time.sleep clock 3.0;
                 (try Eio.Process.signal proc Sys.sigkill with _ -> ());
                 Error "timeout after 3s"))
         with exn -> Error (Printexc.to_string exn)
       in
       match smoke with
       | Ok () -> (try Sys.remove old with _ -> ()); Ok ()
       | Error msg ->
         (try Sys.remove dst with _ -> ());
         (try ignore (Unix.rename old dst) with _ -> ());
         Error (`Smoke_test_failed msg))

let atomic_replace ~src ~dst =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  atomic_replace_core ~env ~sw ~src ~dst
  |> Result.map_error (function
    | `Rename_failed _ as e -> e
    | `Smoke_test_failed msg -> `Rename_failed ("smoke test: " ^ msg))

(* One flushed line per phase on stderr: a multi-megabyte download or a source
   rebuild is slow, and silence reads as a hang. stdout stays clean so callers
   can still parse the final result. *)
let info fmt = Printf.ksprintf (fun s -> Printf.eprintf "[info] %s\n%!" s) fmt

let mb bytes = float_of_int bytes /. (1024.0 *. 1024.0)

(* What an upgrade request should do, decided without touching the network so
   the guard rails are testable. [Current_is_ahead] is the case where the
   running build is newer than the release (a local build, or a tag that was
   yanked): installing the release would silently downgrade. *)
type decision =
  | Already_current
  | Current_is_ahead
  | Newer_available of string
  | Downgrade of string

let decide_upgrade ~(current : string) ~(resolved : string) ~(explicit : bool) =
  if version_components resolved = version_components current then Already_current
  else if is_newer ~latest:resolved ~current then Newer_available resolved
  else if explicit then Downgrade resolved
  else Current_is_ahead

let perform_upgrade_core ~env ~sw ?target () =
  let net = Eio.Stdenv.net env in
  let proc_mgr = Eio.Stdenv.process_mgr env in
  let current = current_version () in
  info "current: %s" current;
  let bin =
    let raw = Sys.executable_name in
    let abs = if Filename.is_relative raw then
      Filename.concat (Sys.getcwd ()) raw else raw in
    try Unix.readlink abs with _ -> abs in
  let bin_dir = Filename.dirname bin in
  let prefix = Filename.dirname bin_dir in
  let* tag = (match target with
    | Some t -> info "installing requested version %s" t; Ok t
    | None ->
      info "checking latest release...";
      fetch_latest_tag_core ~net ~sw ()
  ) |> Result.map_error (function
    | `Http m -> `Download_failed (Printf.sprintf "could not check the latest release (%s)" m)
    | `Offline -> `Download_failed "offline: could not reach GitHub") in
  let install tag =
    match detect_platform () with
    | Error _ ->
      (* No prebuilt binary for this platform (e.g. macOS Intel). Fall back to
         recompiling from source via the official installer, so [par upgrade]
         stays consistent with the installer's behaviour instead of dead-ending
         the user. Installer progress streams to the user's stdout/stderr; a
         first-time source build takes 5-20 minutes. *)
      info "no prebuilt binary for this platform; recompiling from source (this can take 5-20 minutes)";
      let host = download_host () in
      let url = Printf.sprintf
        "https://%s/jcz2020/par-code/releases/download/%s/install.sh" host tag in
      let hdr = [("User-Agent", user_agent)] in
      info "downloading installer...";
      let* script =
        try
          let (s, _, _, body) = http_get ~net ~sw ~headers:hdr url in
          if s = 200 then Ok body
          else Error (`Download_failed (Printf.sprintf "installer download HTTP %d" s))
        with exn -> Error (`Download_failed (Printexc.to_string exn))
      in
      let tmp = Filename.temp_file "par-install" ".sh" in
      Fun.protect
        ~finally:(fun () -> (try Sys.remove tmp with _ -> ()))
        (fun () ->
          let oc = open_out tmp in output_string oc script; close_out oc;
          Unix.chmod tmp 0o755;
          let args = [tmp; "--from-source"; "--prefix"; prefix; "--version"; tag] in
          info "running installer (its own build progress follows)...";
          try
            Eio.Switch.run (fun sw2 ->
              let p = Eio.Process.spawn ~sw:sw2 proc_mgr
                ~stdout:(Eio.Stdenv.stdout env)
                ~stderr:(Eio.Stdenv.stderr env)
                args in
              match Eio.Process.await p with
              | `Exited 0 -> Ok (`Upgraded tag)
              | `Exited n ->
                Error (`Download_failed (Printf.sprintf "installer exited %d" n))
              | `Signaled s ->
                Error (`Download_failed
                  (Printf.sprintf "installer killed by signal %d" s)))
          with exn -> Error (`Download_failed (Printexc.to_string exn)))
    | Ok (platform, ext) ->
      let temp_archive =
        Filename.concat bin_dir (Printf.sprintf "par-upgrade-%d.tmp" (Unix.getpid ())) in
      let staging =
        Filename.concat bin_dir (Printf.sprintf "par-staging-%d" (Unix.getpid ())) in
      let cleanup () =
        (try Sys.remove temp_archive with _ -> ());
        (try rm_rf staging with _ -> ()) in
      Fun.protect ~finally:cleanup (fun () ->
        let dl = download_host () in
        let asset = Printf.sprintf "par-%s-%s.%s" tag platform ext in
        let url = Printf.sprintf "https://%s/jcz2020/par-code/releases/download/%s/%s"
          dl tag asset in
        let hdr = [("User-Agent", user_agent)] in
        let reported = ref 0 in
        let on_start length =
          match length with
          | Some n -> info "downloading %s (%.1f MB)" asset (mb n)
          | None -> info "downloading %s" asset in
        let on_chunk ~total ~length =
          if total - !reported >= 2 * 1024 * 1024 then begin
            reported := total;
            match length with
            | Some n -> info "  %.1f / %.1f MB" (mb total) (mb n)
            | None -> info "  %.1f MB" (mb total)
          end in
        let* archive =
          try
            let (s, _, _, body) =
              http_get ~on_start ~on_chunk ~net ~sw ~headers:hdr url in
            if s = 200 then Ok body
            else Error (`Download_failed (Printf.sprintf "%s: HTTP %d" asset s))
          with exn ->
            Error (`Download_failed
              (Printf.sprintf
                 "network error while downloading %s (%s) - nothing was changed, run it again"
                 asset (Printexc.to_string exn)))
        in
        info "downloaded %.1f MB" (mb (String.length archive));
        info "verifying checksum...";
        let* () =
          try
            let (s, _, _, hash) = http_get ~net ~sw ~headers:hdr (url ^ ".sha256") in
            if s = 200 then
              if verify_sha256 ~expected:hash archive then Ok ()
              else Error `Checksum_mismatch
            else Error (`Download_failed (Printf.sprintf "checksum HTTP %d" s))
          with exn ->
            Error (`Download_failed
              (Printf.sprintf
                 "network error while fetching the checksum (%s) - nothing was changed, run it again"
                 (Printexc.to_string exn)))
        in
        info "extracting archive...";
        let* () =
          try
            let oc = open_out temp_archive in
            output_string oc archive; close_out oc;
            Unix.mkdir staging 0o755;
            let cmd = match ext with
              | "tar.gz" -> ["tar"; "xzf"; temp_archive; "-C"; staging]
              | "zip" -> ["unzip"; "-o"; temp_archive; "-d"; staging]
              | _ -> failwith ("Unknown format: " ^ ext) in
            let ok = Eio.Switch.run (fun sw2 ->
              let p = Eio.Process.spawn ~sw:sw2 proc_mgr cmd in
              match Eio.Process.await p with
              | `Exited 0 -> true | _ -> false) in
            if ok then Ok ()
            else Error (`Download_failed "extraction failed")
          with exn -> Error (`Download_failed (Printexc.to_string exn))
        in
        let new_bin =
          let direct = Filename.concat staging "par" in
          if Sys.file_exists direct then direct
          else match find_par_in staging with Some p -> p | None -> "" in
        if new_bin = "" then
          Error (`Download_failed "par binary not found in archive")
        else begin
          Unix.chmod new_bin 0o755;
          info "installing to %s (smoke test runs after)..." bin;
          match atomic_replace_core ~env ~sw ~src:new_bin ~dst:bin with
          | Ok () -> Ok (`Upgraded tag)
          | Error (`Rename_failed m) -> Error (`Rename_failed m)
          | Error (`Smoke_test_failed m) -> Error (`Smoke_test_failed m)
        end)
  in
  match decide_upgrade ~current ~resolved:tag ~explicit:(Option.is_some target) with
  | Already_current ->
    info "already at %s - nothing to do" tag;
    Ok (`Up_to_date tag)
  | Current_is_ahead ->
    info "latest release is %s; running %s is newer - nothing to do" tag current;
    Ok (`Up_to_date current)
  | Newer_available t ->
    info "updating %s -> %s" current t;
    install t
  | Downgrade t ->
    info "downgrading %s -> %s (explicit --to)" current t;
    install t

let perform_upgrade ?target () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  perform_upgrade_core ~env ~sw ?target ()
