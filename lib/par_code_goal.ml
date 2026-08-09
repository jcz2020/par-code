type status = Active | Met | Aborted | Paused

type goal_state = {
  objective : string;
  step_count : int;
  max_steps : int;
  status : status;
}

let current : goal_state option ref = ref None

let status_label = function
  | Active -> "active"
  | Met -> "met"
  | Aborted -> "aborted"
  | Paused -> "paused"

let goal_file_path = ".par/goals/current.json"

let ensure_goal_dir () =
  if not (Sys.file_exists ".par") then
    (try Unix.mkdir ".par" 0o755 with Unix.Unix_error _ -> ());
  if not (Sys.file_exists ".par/goals") then
    (try Unix.mkdir ".par/goals" 0o755 with Unix.Unix_error _ -> ())

let to_json (g : goal_state) : Yojson.Safe.t =
  `Assoc [
    ("objective", `String g.objective);
    ("step_count", `Int g.step_count);
    ("max_steps", `Int g.max_steps);
    ("status", `String (status_label g.status));
  ]

let of_json (json : Yojson.Safe.t) : goal_state option =
  try
    let open Yojson.Safe.Util in
    let objective = json |> member "objective" |> to_string in
    let step_count = json |> member "step_count" |> to_int in
    let max_steps = json |> member "max_steps" |> to_int in
    let status_str = json |> member "status" |> to_string in
    let status = match status_str with
      | "met" -> Met
      | "aborted" -> Aborted
      | "paused" -> Paused
      | _ -> Active
    in
    Some { objective; step_count; max_steps; status }
  with _ -> None

let save_current_goal_to_disk () =
  match !current with
  | None -> ()
  | Some g ->
    ensure_goal_dir ();
    let tmp = goal_file_path ^ ".tmp" in
    let oc = open_out tmp in
    output_string oc (Yojson.Safe.pretty_to_string ~std:true (to_json g));
    output_char oc '\n';
    close_out oc;
    Sys.rename tmp goal_file_path

let load_goal_from_disk () =
  if not (Sys.file_exists goal_file_path) then None
  else
    try
      let ic = open_in goal_file_path in
      let n = in_channel_length ic in
      let s = Bytes.create n in
      really_input ic s 0 n;
      close_in ic;
      of_json (Yojson.Safe.from_string (Bytes.to_string s))
    with _ -> None

let set_goal ~objective ?(max_steps = 50) () =
  current := Some { objective; step_count = 0; max_steps; status = Active };
  save_current_goal_to_disk ()

let clear_goal () =
  current := None;
  (try Sys.remove goal_file_path with Sys_error _ -> ())

let advance_step () =
  match !current with
  | Some g ->
    let g' = { g with step_count = g.step_count + 1 } in
    current := Some g';
    g'.step_count
  | None -> 0

let mark_status s =
  match !current with
  | Some g -> current := Some { g with status = s }
  | None -> ()

let done_signal : string option ref = ref None

let set_done_signal summary = done_signal := Some summary
let clear_done_signal () = done_signal := None
