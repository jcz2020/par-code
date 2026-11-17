(* v0.13.0 W1 — user-defined permission rules.

   A rule matches a tool call by tool name and, optionally, by a substring of
   its most telling argument (the command for `bash`, the path for file tools).
   The first matching rule wins, so the file is read top to bottom:

     { "rules": [
         { "tool": "bash", "match": "git push", "action": "deny" },
         { "tool": "bash", "match": "rm -rf",   "action": "deny" },
         { "tool": "write", "match": ".env",    "action": "ask"  },
         { "tool": "read",  "action": "allow" } ] }

   Rules live in the project (`.par/permissions.json`) and are shadowed by the
   user file (`~/.par/permissions.json`)? No — both are read, project first,
   because a repository is allowed to tighten but the operator's file decides
   for machine-wide patterns. See [load] for the exact order. *)

open Par

type action = Allow | Ask | Deny

type rule = {
  tool : string;
  match_ : string option;
  action : action;
}

let action_of_string = function
  | "allow" -> Some Allow
  | "ask" -> Some Ask
  | "deny" | "block" -> Some Deny
  | _ -> None

let string_of_action = function
  | Allow -> "allow"
  | Ask -> "ask"
  | Deny -> "deny"

let permissions_path () =
  Filename.concat (Par_code_config.config_dir ()) "permissions.json"

let project_permissions_path () =
  Filename.concat (Filename.concat (Sys.getcwd ()) ".par") "permissions.json"

let rule_of_json (json : Yojson.Safe.t) : rule option =
  let open Yojson.Safe.Util in
  match json |> member "tool" |> to_string_option with
  | None -> None
  | Some tool ->
    let action =
      match json |> member "action" |> to_string_option with
      | Some s -> action_of_string (String.lowercase_ascii s)
      | None -> None
    in
    (match action with
     | None -> None
     | Some action ->
       Some
         { tool;
           match_ = json |> member "match" |> to_string_option;
           action })

let load_file path : rule list =
  try
    let ic = open_in_bin path in
    let n = in_channel_length ic in
    let text = really_input_string ic n in
    close_in ic;
    match Yojson.Safe.from_string text with
    | `Assoc fields ->
      (match List.assoc_opt "rules" fields with
       | Some (`List items) -> List.filter_map rule_of_json items
       | _ -> [])
    | _ -> []
  with _ -> []

(* User rules first: an operator's deny applies even when the repository would
   allow the same call. Then the project file, which can only tighten what the
   user left open. *)
let load () : rule list =
  load_file (permissions_path ()) @ load_file (project_permissions_path ())

(* The argument a rule is matched against: the command for bash, the path for
   file tools, otherwise the whole input rendered as JSON. *)
let subject (ctx : Hook.tool_call_context) =
  (* [member] raises on a non-object, and tool input is not always an object
     (a malformed call arrives as null); read fields defensively. *)
  let field key (j : Yojson.Safe.t) =
    match j with
    | `Assoc fields ->
      (match List.assoc_opt key fields with Some (`String s) -> Some s | _ -> None)
    | _ -> None
  in
  match ctx.tool_name with
  | "bash" ->
    (match field "command" ctx.input with
     | Some c -> c
     | None ->
       (match ctx.input with
        | `Assoc fields ->
          (match List.assoc_opt "argv" fields with
           | Some (`List l) ->
             String.concat " "
               (List.filter_map
                  (function `String s -> Some s | _ -> None)
                  l)
           | _ -> Yojson.Safe.to_string ctx.input)
        | _ -> Yojson.Safe.to_string ctx.input))
  | "write" | "edit" | "apply_patch" | "read" | "ls" | "find" | "grep" ->
    (match field "path" ctx.input with
     | Some p -> p
     | None -> Yojson.Safe.to_string ctx.input)
  | _ -> Yojson.Safe.to_string ctx.input

let matches_rule (ctx : Hook.tool_call_context) subject (r : rule) =
  r.tool = "*" || r.tool = ctx.tool_name
  &&
  match r.match_ with
  | None -> true
  | Some needle ->
    let hay = String.lowercase_ascii subject in
    let needle = String.lowercase_ascii needle in
    (try
       ignore (Str.search_forward (Str.regexp_string needle) hay 0);
       true
     with Not_found -> false)

let decide ~(rules : rule list) (ctx : Hook.tool_call_context) : action option =
  let subject = subject ctx in
  match List.find_opt (matches_rule ctx subject) rules with
  | Some r -> Some r.action
  | None -> None

let hook (rules : rule list) : Hook.tool_call_hook =
 fun ctx ->
  match decide ~rules ctx with
  | Some Deny ->
    Hook.Block
      { reason =
          Printf.sprintf
            "blocked by a permission rule (%s). Edit .par/permissions.json or \
             ~/.par/permissions.json to allow it."
            ctx.tool_name }
  | Some Allow -> Hook.Allow
  | Some Ask | None -> Hook.Allow
