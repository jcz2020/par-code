let (let*) = Result.bind

let current_version () = Par_code_version.version

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

let github_host () =
  Option.value ~default:"api.github.com" (Sys.getenv_opt "PAR_MIRROR")

let download_host () =
  Option.value ~default:"github.com" (Sys.getenv_opt "PAR_MIRROR")

let user_agent = "par-code/" ^ Par_code_version.version

let tls_wrapper uri raw_flow =
  let cfg = Lazy.force Par.Http_client.tls_config in
  match Uri.host uri with
  | None -> Tls_eio.client_of_flow cfg raw_flow
  | Some host ->
    (match Par.Http_client.tls_host_of_string host with
     | Some h -> Tls_eio.client_of_flow cfg ~host:h raw_flow
     | None -> Tls_eio.client_of_flow cfg raw_flow)

let make_client net = Cohttp_eio.Client.make ~https:(Some tls_wrapper) net

let http_get ~net ~sw ~headers url =
  let rec follow redirects_left url =
    let uri = Uri.of_string url in
    let client = make_client net in
    let hdrs = Cohttp.Header.of_list headers in
    let resp, resp_body =
      Cohttp_eio.Client.call ~sw ~headers:hdrs client `GET uri in
    let status = Cohttp.Code.code_of_status (Http.Response.status resp) in
    match status, redirects_left with
    | (301 | 302 | 303 | 307 | 308), n when n > 0 ->
      (match Cohttp.Header.get (Http.Response.headers resp) "location" with
       | Some location -> follow (n - 1) location
       | None ->
         let body = Eio.Buf_read.parse_exn
           ~max_size:(50 * 1024 * 1024) Eio.Buf_read.take_all resp_body in
         (status, Cohttp.Header.get (Http.Response.headers resp) "etag", body))
    | _ ->
      let etag = Cohttp.Header.get (Http.Response.headers resp) "etag" in
      let body = Eio.Buf_read.parse_exn
        ~max_size:(50 * 1024 * 1024) Eio.Buf_read.take_all resp_body in
      (status, etag, body)
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
        let (status, etag, body) = http_get ~net ~sw ~headers url in
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

let perform_upgrade_core ~env ~sw ?target () =
  let net = Eio.Stdenv.net env in
  let proc_mgr = Eio.Stdenv.process_mgr env in
  let bin =
    let raw = Sys.executable_name in
    let abs = if Filename.is_relative raw then
      Filename.concat (Sys.getcwd ()) raw else raw in
    try Unix.readlink abs with _ -> abs in
  let bin_dir = Filename.dirname bin in
  let temp_archive =
    Filename.concat bin_dir (Printf.sprintf "par-upgrade-%d.tmp" (Unix.getpid ())) in
  let staging =
    Filename.concat bin_dir (Printf.sprintf "par-staging-%d" (Unix.getpid ())) in
  let cleanup () =
    (try Sys.remove temp_archive with _ -> ());
    (try rm_rf staging with _ -> ()) in
  Fun.protect ~finally:cleanup (fun () ->
    let* tag = (match target with
      | Some t -> Ok t
      | None -> fetch_latest_tag_core ~net ~sw ()
    ) |> Result.map_error (function
      | `Http m -> `Download_failed ("version lookup: " ^ m)
      | `Offline -> `Download_failed "offline") in
    let* (platform, ext) = detect_platform () in
    let dl = download_host () in
    let asset = Printf.sprintf "par-%s-%s.%s" tag platform ext in
    let url = Printf.sprintf "https://%s/jcz2020/par-code/releases/download/%s/%s"
      dl tag asset in
    let hdr = [("User-Agent", user_agent)] in
    let* archive =
      try
        let (s, _, body) = http_get ~net ~sw ~headers:hdr url in
        if s = 200 then Ok body
        else Error (`Download_failed (Printf.sprintf "HTTP %d" s))
      with exn -> Error (`Download_failed (Printexc.to_string exn))
    in
    let* () =
      try
        let (s, _, hash) = http_get ~net ~sw ~headers:hdr (url ^ ".sha256") in
        if s = 200 then
          if verify_sha256 ~expected:hash archive then Ok ()
          else Error `Checksum_mismatch
        else Error (`Download_failed (Printf.sprintf "checksum HTTP %d" s))
      with exn -> Error (`Download_failed (Printexc.to_string exn))
    in
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
      match atomic_replace_core ~env ~sw ~src:new_bin ~dst:bin with
      | Ok () -> Ok tag
      | Error (`Rename_failed m) -> Error (`Download_failed m)
      | Error (`Smoke_test_failed m) -> Error (`Smoke_test_failed m)
    end)

let perform_upgrade ?target () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  perform_upgrade_core ~env ~sw ?target ()
