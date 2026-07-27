(* lib/par_code_mode.ml *)
type mode = Plan | Build

let planner_agent_id = "planner"
let build_agent_id = "par"

let current : mode ref = ref Build    (* module-level mutable state *)

let switch m =
  let old = !current in
  current := m;
  old                                  (* return previous for logging *)

let agent_id_for (m : mode) =
  match m with
  | Plan -> planner_agent_id
  | Build -> build_agent_id

let label = function Plan -> "plan" | Build -> "build"

let mode_file_path = ".par/last_session_mode.txt"

let save_current_mode_to_disk () : unit =
  try
    if not (Sys.file_exists ".par") then
      Unix.mkdir ".par" 0o755;
    let oc = open_out mode_file_path in
    output_string oc (label !current);
    close_out oc
  with Sys_error _ -> ()

let load_mode_from_disk () : mode option =
  try
    let ic = open_in mode_file_path in
    let s = input_line ic in
    close_in ic;
    (match s with
     | "plan" -> Some Plan
     | "build" -> Some Build
     | _ -> None)
  with Sys_error _ | End_of_file -> None
