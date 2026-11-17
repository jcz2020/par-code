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

(* v0.10.1: a few flows ship inside the binary so `/flow run` works outside this
   repository too. A file with the same id wins, so users can override them. *)
let builtin_source : (string * string) list =
  [ ("compose-seven", {|{
  "id": "compose-seven",
  "name": "Seven-stage compose: plan, execute, review, tdd, debug, verify, merge",
  "version": 1,
  "steps": [
    "Sequential",
    [
      [
        "Agent_call",
        {
          "agent_id": "explore",
          "prompt_template": "Write a concrete implementation plan for the request below: which files to touch, the change in each, and the tests that will prove it works. You are read-only. Reply with the plan only, no preamble.\n\nRequest:\n{{spec}}",
          "response_schema": null
        }
      ],
      [
        "Agent_call",
        {
          "agent_id": "par",
          "prompt_template": "Implement this plan now: edit the files. Do not run the test suite yet. When you are done, reply with a terse list of files changed and what changed in each.\n\nPlan:\n{{result_0.text}}",
          "response_schema": null
        }
      ],
      [
        "Agent_call",
        {
          "agent_id": "explore",
          "prompt_template": "Review the implementation below against the request and the plan. List concrete defects only (missing cases, broken call sites, wrong behaviour); write 'no problems found' when there are none.\n\nRequest:\n{{spec}}\n\nPlan:\n{{result_0.text}}\n\nImplementation report:\n{{result_1.text}}",
          "response_schema": null
        }
      ],
      [
        "Agent_call",
        {
          "agent_id": "par",
          "prompt_template": "Write or update the tests this change needs. They must fail without the change and pass with it. Reply with the test files touched and one line per assertion.\n\nRequest:\n{{spec}}\n\nReview findings:\n{{result_2.text}}",
          "response_schema": null
        }
      ],
      [
        "Agent_call",
        {
          "agent_id": "par",
          "prompt_template": "Run the tests you just wrote. Fix the code (not the tests) until they pass; if a test itself is wrong, say why and correct it. Report the command you ran, the failure, and the fix.\n\nTests added:\n{{result_3.text}}",
          "response_schema": null
        }
      ],
      [
        "Agent_call",
        {
          "agent_id": "par",
          "prompt_template": "Run the project's full test command now. Do not change code in this step. Report the exact command, its exit status, and a one-paragraph summary of the result.",
          "response_schema": null
        }
      ],
      [
        "Agent_call",
        {
          "agent_id": "par",
          "prompt_template": "Summarise this change for a reviewer: what changed and why, how it was verified, any risk left, and a proposed commit message. Do not commit anything.\n\nRequest:\n{{spec}}\n\nVerification:\n{{result_5.text}}",
          "response_schema": null
        }
      ]
    ]
  ],
  "variables": [
    [
      "spec",
      "Describe the change to make (pass it after the flow id, or edit variables.spec in the definition)"
    ]
  ],
  "failure_policy": [
    "Continue_on_failure"
  ],
  "parallel_limit": 1,
  "timeout": 2400
}|}) ]

let builtin (id : string) : (Types.workflow_def, string) result =
  match List.assoc_opt id builtin_source with
  | None -> Error (Printf.sprintf "no built-in flow named %s" id)
  | Some source -> def_of_string source

(* Override one variable of a loaded definition. `/flow run <id> <spec...>` uses
   this so a shipped flow can be pointed at the user's request. *)
let with_variable (def : Types.workflow_def) name value =
  let kept =
    List.filter (fun (k, _) -> k <> name) def.Types.variables
  in
  { def with Types.variables = kept @ [ (name, `String value) ] }

let load (id : string) : (Types.workflow_def, string) result =
  match List.find_opt Sys.file_exists (candidates id) with
  | None ->
    (match builtin id with
     | Ok def -> Ok def
     | Error _ ->
       Error
         (Printf.sprintf "no flow named %s (looked in %s, %s and the built-ins)"
            id dir example_dir))
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
  List.sort_uniq String.compare
    (ids_in dir @ ids_in example_dir @ List.map fst builtin_source)

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
