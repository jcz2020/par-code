(* v0.13.0 W2 — whole-workspace snapshots and undo.

   Every user turn is committed into a shadow git repository under
   [<root>/.par/snapshot.git] before the agent runs, so an `/undo` can put the
   workspace back exactly as it was — including files a shell command deleted or
   rewrote, which per-file backups cannot cover.

   The shadow repo never touches the project's own `.git`: it is created with
   [--bare] plus an explicit [core.worktree], and `.par/` itself is excluded so
   snapshots do not recurse into their own storage. *)

let git_dir root = Filename.concat (Filename.concat root ".par") "snapshot.git"

let excludes =
  [ ".par/"
  ; "_build/"
  ; "node_modules/"
  ; ".git/"
  ; "__pycache__/"
  ; ".venv/"
  ; "dist/"
  ; "target/"
  ]

(* -- plumbing ------------------------------------------------------------ *)

let run_argv argv : (string, string) result =
  let devnull = Unix.openfile "/dev/null" [ Unix.O_WRONLY ] 0 in
  let out_read, out_write = Unix.pipe () in
  Unix.set_close_on_exec out_read;
  let env =
    Array.append (Unix.environment ()) [| "GIT_TERMINAL_PROMPT=0" |]
  in
  match Unix.create_process_env "git" argv env Unix.stdin out_write out_write with
  | exception ex ->
    Unix.close out_read; Unix.close out_write; Unix.close devnull;
    Error (Printexc.to_string ex)
  | pid ->
    Unix.close out_write;
    Unix.close devnull;
    let buf = Buffer.create 256 in
    let chunk = Bytes.create 4096 in
    let rec drain () =
      match Unix.read out_read chunk 0 4096 with
      | 0 -> ()
      | n -> Buffer.add_subbytes buf chunk 0 n; drain ()
      | exception Unix.Unix_error (Unix.EINTR, _, _) -> drain ()
    in
    drain ();
    Unix.close out_read;
    let _, status = Unix.waitpid [] pid in
    let output = Buffer.contents buf in
    match status with
    | Unix.WEXITED 0 -> Ok output
    | Unix.WEXITED n -> Error (Printf.sprintf "git exited %d: %s" n output)
    | Unix.WSIGNALED s -> Error (Printf.sprintf "git killed by signal %d" s)
    | Unix.WSTOPPED s -> Error (Printf.sprintf "git stopped by signal %d" s)

let run_git ~root args : (string, string) result =
  (* Explicit flags instead of GIT_DIR/GIT_WORK_TREE: git rejects the latter
     without the former in some call shapes, and the flags are unambiguous. *)
  run_argv
    (Array.of_list
       ([ "git"; "--git-dir"; git_dir root; "--work-tree"; root ] @ args))

let ensure_repo ~root : (unit, string) result =
  let dir = git_dir root in
  if Sys.file_exists dir then Ok ()
  else
    match
      run_argv
        (Array.of_list [ "git"; "init"; "--bare"; "--quiet"; dir ])
    with
    | Error e -> Error e
    | Ok _ ->
      (match
         run_git ~root [ "config"; "core.bare"; "false" ] with
       | Error e -> Error e
       | Ok _ ->
         let exclude_path =
           Filename.concat (Filename.concat dir "info") "exclude"
         in
         (try
            let oc = open_out exclude_path in
            List.iter (fun p -> output_string oc (p ^ "\n")) excludes;
            close_out oc
          with _ -> ());
         Ok ())

(* True when the workspace has anything to record. *)
let has_changes ~root : bool =
  match run_git ~root [ "add"; "-A"; "--"; "." ] with
  | Error _ -> false
  | Ok _ ->
    (match run_git ~root [ "diff"; "--cached"; "--quiet" ] with
     | Ok _ -> false
     | Error _ -> true)

let capture ~root ~reason : (string, string) result =
  match ensure_repo ~root with
  | Error e -> Error e
  | Ok () ->
    if not (has_changes ~root) then Ok ""
    else
      match
        run_git ~root
          [ "-c"; "user.name=par"; "-c"; "user.email=par@localhost";
            "commit"; "--quiet"; "-m"; reason ] with
      | Error e -> Error e
      | Ok _ ->
        (match run_git ~root [ "rev-parse"; "HEAD" ] with
         | Error e -> Error e
         | Ok out -> Ok (String.trim out))

type entry = { sha : string; reason : string; time : int }

let parse_log text =
  String.split_on_char '\n' text
  |> List.filter_map (fun line ->
      if String.trim line = "" then None
      else
        match String.split_on_char '\t' line with
        | [ sha; time; reason ] ->
          (match int_of_string_opt time with
           | Some t -> Some { sha; reason; time = t }
           | None -> None)
        | sha :: rest ->
          Some { sha; reason = String.concat "\t" rest; time = 0 }
        | [] -> None)

let list_entries ~root ?(limit = 20) () : entry list =
  match
    run_git ~root
      [ "log"; "--format=%H%x09%ct%x09%s"; "-n"; string_of_int limit ]
  with
  | Error _ -> []
  | Ok text -> parse_log text

(* Put the workspace back to [sha] without moving HEAD: the snapshot list has to
   stay intact, otherwise the state we just left would become unreachable and
   `/undo` could not be undone. *)
let restore ~root ~sha : (unit, string) result =
  match run_git ~root [ "read-tree"; sha ] with
  | Error e -> Error e
  | Ok _ ->
    (match run_git ~root [ "checkout-index"; "-a"; "-f" ] with
     | Error e -> Error e
     | Ok _ ->
       (* Drop files that the snapshot does not contain. Ignored paths
          (`.par/`, `_build/`, …) are left alone. *)
       (match run_git ~root [ "clean"; "-fdq" ] with
        | Error e -> Error e
        | Ok _ -> Ok ()))

let undo ~root ~(index : int) : (string, string) result =
  (* Record where we are first. That entry becomes index 0, which is what makes
     a second `/undo` return to the state the first one left behind. *)
  let captured =
    match capture ~root ~reason:"before undo" with
    | Error e -> Error e
    | Ok sha -> Ok sha
  in
  match captured with
  | Error e -> Error e
  | Ok sha ->
    let entries = list_entries ~root ~limit:(index + 3) () in
    let offset = if sha = "" then index else index + 1 in
    (match List.nth_opt entries offset with
     | None -> Error "no snapshot to go back to"
     | Some target ->
       (match restore ~root ~sha:target.sha with
        | Error e -> Error (Printf.sprintf "restore failed: %s" e)
        | Ok () ->
          Ok
            (Printf.sprintf "restored workspace to snapshot %s (%s)"
               (String.sub target.sha 0 8) target.reason)))
