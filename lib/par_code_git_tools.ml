(* par_code_git_tools.ml — Read-only git tools for the planner agent.
 *
 * Two tool bindings that expose git state to the planner:
 * - git_status: show working tree status (modified, added, deleted, untracked)
 * - git_log: show recent commit history
 *
 * Each tool is a [Types.tool_binding] with descriptor + handler, compatible
 * with [Runtime.register_tool]. The planner has no bash tool — these are its
 * only way to see git state. *)

open Par

(* -- Helpers -------------------------------------------------------------- *)

(** Build an [Error] handler result with the given category and message. *)
let tool_error ~category ~message () =
  let open Types in
  Error { category; message; retryable = false; metadata = [] }

(** Run a git command and capture stdout/stderr.
    Returns [(exit_code, stdout, stderr)].
    Raises if the process cannot be spawned. *)
let run_git ~process_mgr ~sw args =
  let stdout_buf = Buffer.create 1024 in
  let stderr_buf = Buffer.create 1024 in
  let proc =
    Eio.Process.spawn ~sw process_mgr
      ~stdin:(Eio.Flow.string_source "")
      ~stdout:(Eio.Flow.buffer_sink stdout_buf)
      ~stderr:(Eio.Flow.buffer_sink stderr_buf)
      args
  in
  let status = Eio.Process.await proc in
  let code = match status with
    | `Exited n -> n
    | `Signaled _ -> 128
  in
  (code, Buffer.contents stdout_buf, Buffer.contents stderr_buf)

(* -- Parsing -------------------------------------------------------------- *)

(** Parse [git status --porcelain=v1 -b] output into JSON.

    First line: [## branch...tracking [ahead N]] or [## branch]
    Subsequent lines: [XY filename] where XY are status codes. *)
let parse_git_status output =
  let lines = String.split_on_char '\n' output in
  let lines = List.filter (fun s -> String.length s > 0) lines in
  match lines with
  | [] ->
    `Assoc [("branch", `String ""); ("files", `List [])]
  | header :: rest ->
    (* Extract branch name: skip "## ", stop at "..." or end *)
    let branch_part =
      if String.length header > 3 then
        String.sub header 3 (String.length header - 3)
      else
        ""
    in
    let branch =
      let len = String.length branch_part in
      let rec find_three_dots i =
        if i + 2 >= len then branch_part
        else if branch_part.[i] = '.' && branch_part.[i+1] = '.' && branch_part.[i+2] = '.'
        then String.sub branch_part 0 i
        else find_three_dots (i + 1)
      in
      find_three_dots 0
    in
    (* Parse file statuses: each line is "XY path" *)
    let files = List.filter_map (fun line ->
      if String.length line >= 3 then
        let status = String.sub line 0 2 in
        let path = String.sub line 3 (String.length line - 3) in
        Some (`Assoc [("path", `String path); ("status", `String status)])
      else
        None
    ) rest
    in
    `Assoc [("branch", `String branch); ("files", `List files)]

(** Parse [git log --format='%H|%s|%ai'] output into JSON.

    Each line: [hash|message|date] — split on first and last [|]. *)
let parse_git_log output =
  let lines = String.split_on_char '\n' output in
  let lines = List.filter (fun s -> String.length s > 0) lines in
  let commits = List.filter_map (fun line ->
    match String.index_opt line '|' with
    | None -> None
    | Some first_pipe ->
      match String.rindex_opt line '|' with
      | None -> None
      | Some last_pipe ->
        if first_pipe = last_pipe then None
        else
          let hash = String.sub line 0 first_pipe in
          let date_start = last_pipe + 1 in
          let date =
            String.sub line date_start (String.length line - date_start)
          in
          let msg_start = first_pipe + 1 in
          let msg_len = last_pipe - msg_start in
          let message = String.sub line msg_start msg_len in
          Some (`Assoc
            [ ("hash",    `String hash)
            ; ("message", `String message)
            ; ("date",    `String date)
            ])
  ) lines in
  `Assoc [("commits", `List commits)]

(* -- Tool schemas --------------------------------------------------------- *)

let git_status_input_schema : Yojson.Safe.t =
  `Assoc
    [ ("type", `String "object")
    ; ("properties", `Assoc [])
    ; ("required", `List [])
    ]

let git_log_input_schema : Yojson.Safe.t =
  `Assoc
    [ ("type", `String "object")
    ; ("properties", `Assoc
        [ ("count", `Assoc
            [ ("type", `String "integer")
            ; ("description", `String "Number of commits to show (default 10)")
            ])
        ])
    ; ("required", `List [])
    ]

(* -- Tool bindings -------------------------------------------------------- *)

let tools ~process_mgr : Types.tool_binding list =
  let open Types in
  let git_status =
    let descriptor =
      { name = "git_status"
      ; description =
          "Show the current git working tree status. Returns modified, added, \
           deleted, and untracked files, plus the current branch name. \
           Read-only — does not modify anything."
      ; input_schema = git_status_input_schema
      ; output_schema = None
      ; permission = Allow
      ; timeout = Some 10.0
      ; concurrency_limit = None
      ; on_update = None
      ; cache_control = None
      }
    in
    let handler = fun _input tok ->
      try
        let (code, stdout, stderr) =
          run_git ~process_mgr ~sw:tok.switch
            ["git"; "status"; "--porcelain=v1"; "-b"]
        in
        if code = 0 then
          Success (parse_git_status stdout)
        else
          tool_error ~category:(External_failure "git")
            ~message:(Printf.sprintf "git status failed (exit %d): %s"
                        code stderr)
            ()
      with exn ->
        tool_error ~category:(External_failure "git")
          ~message:(Printf.sprintf "git status error: %s"
                      (Printexc.to_string exn))
          ()
    in
    { descriptor; handler }
  in
  let git_log =
    let descriptor =
      { name = "git_log"
      ; description =
          "Show recent git commit history. Returns commit hashes, messages, \
           and dates. Read-only — does not modify anything."
      ; input_schema = git_log_input_schema
      ; output_schema = None
      ; permission = Allow
      ; timeout = Some 10.0
      ; concurrency_limit = None
      ; on_update = None
      ; cache_control = None
      }
    in
    let handler = fun input tok ->
      let open Yojson.Safe.Util in
      let count =
        match input |> member "count" with
        | `Null -> 10
        | j -> (try to_int j with _ -> 10)
      in
      try
        let count_str = string_of_int count in
        let (code, stdout, stderr) =
          run_git ~process_mgr ~sw:tok.switch
            [ "git"; "log"; "--format=%H|%s|%ai"; "-" ^ count_str ]
        in
        if code = 0 then
          Success (parse_git_log stdout)
        else
          tool_error ~category:(External_failure "git")
            ~message:(Printf.sprintf "git log failed (exit %d): %s"
                        code stderr)
            ()
      with exn ->
        tool_error ~category:(External_failure "git")
          ~message:(Printf.sprintf "git log error: %s"
                      (Printexc.to_string exn))
          ()
    in
    { descriptor; handler }
  in
  [ git_status; git_log ]
