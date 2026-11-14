(* par_code_flow.ml — v0.10.0 W2: workflows defined as files.
 *
 * A flow is a `.par/flows/<id>.json` holding a PAR [workflow_def]; the SDK owns
 * the engine (register / submit / status / cancel / recover), par-code owns the
 * file convention and the slash command. Keeping the definition in a file means
 * it can be reviewed, diffed and shared like a skill. *)

open Par

let dir = ".par/flows"

let path_of id = Filename.concat dir (id ^ ".json")

(* Pure and unit-tested: parse a definition without touching the disk. *)
let def_of_string (s : string) : (Types.workflow_def, string) result =
  match Yojson.Safe.from_string s with
  | json ->
    (match Types.workflow_def_of_yojson json with
     | Ok def -> Ok def
     | Error msg -> Error ("invalid flow definition: " ^ msg))
  | exception Yojson.Json_error msg -> Error ("invalid JSON: " ^ msg)

let load (id : string) : (Types.workflow_def, string) result =
  let path = path_of id in
  if not (Sys.file_exists path) then
    Error (Printf.sprintf "no flow named %s (expected %s)" id path)
  else
    match (try Some (open_in_bin path) with Sys_error _ -> None) with
    | None -> Error (Printf.sprintf "cannot open %s" path)
    | Some ic ->
      Fun.protect
        ~finally:(fun () -> close_in_noerr ic)
        (fun () ->
           def_of_string (really_input_string ic (in_channel_length ic)))

let available () : string list =
  match Sys.readdir dir with
  | entries ->
    Array.to_list entries
    |> List.filter (fun f -> Filename.check_suffix f ".json")
    |> List.map (fun f -> Filename.chop_suffix f ".json")
    |> List.sort String.compare
  | exception Sys_error _ -> []

let status_line = function
  | Types.Wf_pending -> "pending"
  | Types.Wf_running -> "running"
  | Types.Wf_suspended _ -> "suspended (waiting for approval)"
  | Types.Wf_completed r ->
    Printf.sprintf "completed (%s, %.1fs)"
      (match r.Types.status with
       | `Success -> "success"
       | `Partial -> "partial"
       | `Failed -> "failed")
      r.Types.elapsed
  | Types.Wf_failed e -> "failed: " ^ Par_code_setup.error_to_string e

let workflow_of (def : Types.workflow_def) : Types.workflow =
  { Types.def; on_complete = None }
