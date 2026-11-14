(* par_code_flow.ml — v0.10.0 W2: workflows defined as files.
 *
 * A flow is a `.par/flows/<id>.json` holding a PAR [workflow_def]; the SDK owns
 * the engine (register / submit / status / cancel / recover), par-code owns the
 * file convention and the slash command. Keeping the definition in a file means
 * it can be reviewed, diffed and shared like a skill. *)

open Par

let dir = ".par/flows"
let example_dir = "examples/flows"

let path_of id = Filename.concat dir (id ^ ".json")

let candidates id =
  [ path_of id; Filename.concat example_dir (id ^ ".json") ]

(* Pure and unit-tested: parse a definition without touching the disk. *)
let def_of_string (s : string) : (Types.workflow_def, string) result =
  match Yojson.Safe.from_string s with
  | json ->
    (match Types.workflow_def_of_yojson json with
     | Ok def -> Ok def
     | Error msg -> Error ("invalid flow definition: " ^ msg))
  | exception Yojson.Json_error msg -> Error ("invalid JSON: " ^ msg)

let load (id : string) : (Types.workflow_def, string) result =
  match List.find_opt Sys.file_exists (candidates id) with
  | None ->
    Error
      (Printf.sprintf "no flow named %s (looked in %s and %s)" id dir
         example_dir)
  | Some path ->
    match (try Some (open_in_bin path) with Sys_error _ -> None) with
    | None -> Error (Printf.sprintf "cannot open %s" path)
    | Some ic ->
      Fun.protect
        ~finally:(fun () -> close_in_noerr ic)
        (fun () ->
           def_of_string (really_input_string ic (in_channel_length ic)))

let ids_in d =
  match Sys.readdir d with
  | entries ->
    Array.to_list entries
    |> List.filter (fun f -> Filename.check_suffix f ".json")
    |> List.map (fun f -> Filename.chop_suffix f ".json")
  | exception Sys_error _ -> []

let available () : string list =
  List.sort_uniq String.compare (ids_in dir @ ids_in example_dir)

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

(* Agents that can stop and wait for a human: [par] and [general] carry bash and
   write tools, [planner] asks whether to switch mode. A workflow step has no
   channel for either, so a run that names one can hang with no way to answer. *)
let interactive_agents = [ "par"; "planner"; "general" ]

let agent_ids (def : Types.workflow_def) : string list =
  let rec walk = function
    | `Assoc fields ->
      List.concat_map
        (fun (key, value) ->
           if key = "agent_id" then
             match value with `String s -> [ s ] | _ -> []
           else walk value)
        fields
    | `List items -> List.concat_map walk items
    | _ -> []
  in
  walk (Types.workflow_def_to_yojson def) |> List.sort_uniq String.compare
