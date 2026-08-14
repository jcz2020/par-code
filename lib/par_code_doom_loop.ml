type action =
  | Continue
  | Nudge of string
  | Force_judge of string
  | Abort of string

type tool_event = {
  tool_name : string;
  args_json : Yojson.Safe.t;
  output : string option;
  failed : bool;
}

type thresholds = {
  bash_retries : int;
  edit_matches : int;
  action_streak : int;
}

type t = {
  mutable bash_fail_streak : (string * string) list;
  mutable bash_nudged : bool;
  mutable bash_aborted : bool;
  mutable edit_window : (string * string list) list;
  mutable edit_total_matches : int;
  mutable edit_nudged : bool;
  mutable edit_judged : bool;
  mutable edit_aborted : bool;
  mutable action_kind : string;
  mutable action_count : int;
  mutable action_nudged : bool;
  mutable action_judged : bool;
  mutable action_aborted : bool;
  thresholds : thresholds;
}

let re_tmp = Str.regexp "/tmp/[^ \t\n]*"
let re_digits = Str.regexp "[0-9][0-9][0-9][0-9][0-9][0-9][0-9]*"
let re_seed = Str.regexp "--seed=[^ \t]*"
let re_duration = Str.regexp "[0-9]+\\(\\.[0-9]+\\)?s\\b"

let normalize_bash_cmd s =
  let s = Str.global_replace re_tmp "<TMP>" s in
  let s = Str.global_replace re_digits "<NUM>" s in
  Str.global_replace re_seed "<SEED>" s

let normalize_output s =
  let s = Str.global_replace re_duration "<DUR>" s in
  let len = String.length s in
  if len > 2000 then
    String.sub s 0 800 ^ "<TRUNCATED>" ^ String.sub s (len - 800) 800
  else s

let shingle_lines (text : string) : string list =
  let lines = String.split_on_char '\n' text in
  let arr = Array.of_list lines in
  let n = Array.length arr in
  if n < 3 then [text]
  else
    let result = ref [] in
    for i = 0 to n - 3 do
      result := (arr.(i) ^ "\n" ^ arr.(i + 1) ^ "\n" ^ arr.(i + 2)) :: !result
    done;
    List.rev !result

module String_set = Set.Make(String)

let jaccard (a : string list) (b : string list) : float =
  let set_a = List.fold_left (fun s x -> String_set.add x s) String_set.empty a in
  let set_b = List.fold_left (fun s x -> String_set.add x s) String_set.empty b in
  let inter = String_set.inter set_a set_b in
  let union = String_set.union set_a set_b in
  if String_set.is_empty union then 1.0
  else float_of_int (String_set.cardinal inter) /. float_of_int (String_set.cardinal union)

let verify_re = Str.regexp "\\(pytest\\|make test\\|cargo test\\|go test\\|npm test\\|tsc\\|ruff\\|flake8\\|dune build\\)"

let classify_tool ~tool_name ~args_json ~is_bash =
  if tool_name = "edit" || tool_name = "write" then "edit"
  else if is_bash then
    let cmd =
      match args_json with
      | `String s -> s
      | _ ->
        (try Yojson.Safe.Util.to_string args_json with _ -> "")
    in
    let normalized = normalize_bash_cmd cmd in
    if Str.string_match verify_re normalized 0 then "verify"
    else "other"
  else if tool_name = "read" || tool_name = "grep" || tool_name = "find"
       || tool_name = "ls" then "info"
  else "other"

let create ?(bash_retries = 3) ?(edit_matches = 2) ?(action_streak = 4) () = {
  bash_fail_streak = [];
  bash_nudged = false;
  bash_aborted = false;
  edit_window = [];
  edit_total_matches = 0;
  edit_nudged = false;
  edit_judged = false;
  edit_aborted = false;
  action_kind = "";
  action_count = 0;
  action_nudged = false;
  action_judged = false;
  action_aborted = false;
  thresholds = { bash_retries; edit_matches; action_streak };
}

let max_action a b =
  match a, b with
  | Abort _, _ -> a
  | _, Abort _ -> b
  | Force_judge _, _ -> a
  | _, Force_judge _ -> b
  | Nudge _, _ -> a
  | _, Nudge _ -> b
  | Continue, Continue -> Continue

let record (t : t) (evt : tool_event) : action =
  let thr = t.thresholds in

  let bash_action =
    if evt.tool_name = "bash" && evt.failed then begin
      let cmd_str =
        match evt.args_json with
        | `String s -> s
        | _ -> (try Yojson.Safe.Util.to_string evt.args_json with _ -> "")
      in
      let norm_cmd = normalize_bash_cmd cmd_str in
      let norm_out = match evt.output with
        | Some o -> normalize_output o
        | None -> ""
      in
      let matches_last =
        match t.bash_fail_streak with
        | (last_cmd, last_out) :: _ -> last_cmd = norm_cmd && last_out = norm_out
        | [] -> false
      in
      let n =
        if matches_last then
          let n = List.length t.bash_fail_streak + 1 in
          t.bash_fail_streak <- (norm_cmd, norm_out) :: t.bash_fail_streak;
          n
        else begin
          t.bash_fail_streak <- [(norm_cmd, norm_out)];
          1
        end
      in
      if n >= 3 * thr.bash_retries && not t.bash_aborted then begin
        t.bash_aborted <- true;
        Abort (Printf.sprintf "Bash retry signal: %d consecutive failures with identical normalized output — aborting goal" n)
      end else if n >= thr.bash_retries && not t.bash_nudged then begin
        t.bash_nudged <- true;
        Nudge (Printf.sprintf "Bash retry signal: %d consecutive failures — reassess your approach" n)
      end else
        Continue
    end else begin
      if evt.tool_name = "bash" then t.bash_fail_streak <- [];
      Continue
    end
  in

  let edit_action =
    if evt.tool_name = "edit" || evt.tool_name = "write" then begin
      let output_text = match evt.output with Some s -> s | None -> "" in
      let new_shingles = shingle_lines output_text in
      let match_count = List.fold_left (fun acc (_id, ws) ->
        let sim = jaccard ws new_shingles in
        if sim > 0.8 then acc + 1 else acc
      ) 0 t.edit_window in
      t.edit_window <- (evt.tool_name, new_shingles) :: t.edit_window;
      if List.length t.edit_window > 12 then
        t.edit_window <- List.filteri (fun i _ -> i < 12) t.edit_window;
      t.edit_total_matches <- t.edit_total_matches + match_count;
      let total = t.edit_total_matches in
      if total >= 3 * thr.edit_matches && not t.edit_aborted then begin
        t.edit_aborted <- true;
        Abort (Printf.sprintf "Edit repeat signal: %d near-duplicate edits detected — aborting goal" total)
      end else if total >= 2 * thr.edit_matches && not t.edit_judged then begin
        t.edit_judged <- true;
        Force_judge (Printf.sprintf "Edit repeat signal: %d near-duplicate edits detected — forcing judge evaluation" total)
      end else if total >= thr.edit_matches && not t.edit_nudged then begin
        t.edit_nudged <- true;
        Nudge (Printf.sprintf "Edit repeat signal: %d near-duplicate edits detected — reassess your approach" total)
      end else
        Continue
    end else
      Continue
  in

  let action_action =
    let kind = classify_tool ~tool_name:evt.tool_name ~args_json:evt.args_json
      ~is_bash:(evt.tool_name = "bash") in
    if kind = "info" then begin
      t.action_kind <- kind;
      t.action_count <- 0;
      Continue
    end else if kind = t.action_kind && t.action_count > 0 then begin
      t.action_count <- t.action_count + 1;
      let n = t.action_count in
      if n >= 3 * thr.action_streak && not t.action_aborted then begin
        t.action_aborted <- true;
        Abort (Printf.sprintf "Action streak signal: %d consecutive %s actions — aborting goal" n kind)
      end else if n >= 2 * thr.action_streak && not t.action_judged then begin
        t.action_judged <- true;
        Force_judge (Printf.sprintf "Action streak signal: %d consecutive %s actions — forcing judge evaluation" n kind)
      end else if n >= thr.action_streak && not t.action_nudged then begin
        t.action_nudged <- true;
        Nudge (Printf.sprintf "Action streak signal: %d consecutive %s actions — reassess your approach" n kind)
      end else
        Continue
    end else begin
      t.action_kind <- kind;
      t.action_count <- 1;
      Continue
    end
  in

  max_action bash_action (max_action edit_action action_action)

let write_incident ~signal ~reason ~normalized ~original =
  let dir = ".par/goals/incidents" in
  let ensure_dir () =
    if not (Sys.file_exists ".par") then
      (try Unix.mkdir ".par" 0o755 with Unix.Unix_error _ -> ());
    if not (Sys.file_exists ".par/goals") then
      (try Unix.mkdir ".par/goals" 0o755 with Unix.Unix_error _ -> ());
    if not (Sys.file_exists dir) then
      (try Unix.mkdir dir 0o755 with Unix.Unix_error _ -> ())
  in
  ensure_dir ();
  let ts = Unix.gettimeofday () in
  let tm = Unix.gmtime ts in
  let filename = Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ.json"
    (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1) tm.Unix.tm_mday
    tm.Unix.tm_hour tm.Unix.tm_min tm.Unix.tm_sec
    (int_of_float ((ts -. floor ts) *. 1000.0)) in
  let path = Filename.concat dir filename in
  let json : Yojson.Safe.t = `Assoc [
    ("signal", `String signal);
    ("reason", `String reason);
    ("normalized_input", `String normalized);
    ("original_input", `String original);
    ("timestamp_iso", `String (Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
      (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1) tm.Unix.tm_mday
      tm.Unix.tm_hour tm.Unix.tm_min tm.Unix.tm_sec));
  ] in
  let tmp = path ^ ".tmp" in
  let oc = open_out tmp in
  output_string oc (Yojson.Safe.pretty_to_string ~std:true json);
  output_char oc '\n';
  close_out oc;
  Sys.rename tmp path;
  path

let action_count t = t.action_count
let total_edit_matches t = t.edit_total_matches
let bash_fail_streak_count t = List.length t.bash_fail_streak
let nudged t = t.bash_nudged || t.edit_nudged || t.action_nudged
let forced_judge t = t.edit_judged || t.action_judged
let aborted t = t.bash_aborted || t.action_aborted
