(* par_code_skills.ml — user/project skill discovery for v0.9.0 self-improvement.
 *
 * The PAR SDK ships [Skill_loader] (filesystem discovery + frontmatter parser)
 * and [Runtime.register_skill]. par-code previously registered only
 * [Builtin_skills.builtin_skills]; this module wires the file-backed skills in
 * and exposes the pieces the REPL needs to turn a manual skill into a
 * custom slash command.
 *
 * Scope (v0.9.0 W0/W1): manual skills only. Auto/Keyword user skills are
 * reported as skipped until [skills_auto_activate] lands (W4). The SDK does not
 * consume [skill_descriptor.body_path] at runtime (0.12-beta), so the REPL
 * reads the body itself and injects it via [~system_prompt_appendix]. *)

open Par

type source = Project | User

type entry = {
  descriptor : Types.skill_descriptor;
  source : source;
}

let custom : (string, entry) Hashtbl.t = Hashtbl.create 16

(* Built-in REPL commands (without the leading slash). A user skill with one
   of these ids would be shadowed by the hardcoded dispatch, so it is rejected
   at load time instead of silently doing nothing. *)
let reserved_commands =
  [ "help"; "session"; "health"; "reset"; "checkpoint"; "checkpoints";
    "quit"; "exit"; "cost"; "plan"; "build"; "max"; "goal";
    "skills"; "distill"; "dream" ]

let builtin_skill_ids =
  List.map (fun (d : Types.skill_descriptor) -> d.id) Builtin_skills.builtin_skills

let source_string = function
  | Project -> "project"
  | User -> "user"

let error_to_string (e : Types.error_category) =
  match e with
  | Types.Timeout -> "timeout"
  | Types.Invalid_input s -> s
  | Types.External_failure s -> s
  | Types.Rate_limited -> "rate limited"
  | Types.Permission_denied s -> s
  | Types.Internal s -> s
  | Types.Embedding_unsupported -> "embeddings unsupported"
  | Types.Cancelled _ -> "cancelled"

let scan_dir dir source : (entry list * (string * string) list) =
  let exists_dir p =
    try Sys.file_exists p && Sys.is_directory p with Sys_error _ -> false
  in
  if not (exists_dir dir) then ([], [])
  else
    let names =
      try Sys.readdir dir |> Array.to_list
      with Sys_error _ -> []
    in
    let ok, errs =
      List.fold_left (fun (ok, errs) name ->
        let sub = Filename.concat dir name in
        if not (exists_dir sub) then (ok, errs)
        else
          let path = Filename.concat sub "skill.md" in
          if not (Sys.file_exists path) then (ok, errs)
          else
            match Skill_loader.parse_skill_file ~path with
            | Ok descriptor -> ({ descriptor; source } :: ok, errs)
            | Error msg -> (ok, (name, msg) :: errs)
      ) ([], []) names
    in
    (List.rev ok, List.rev errs)

(* Project skills shadow user skills with the same id (the SDK loader uses the
   same precedence). Parse errors are returned with the directory name so the
   startup/reload notice can point at the broken file. *)
let scan ?(user_dir = Skill_loader.default_user_skills_dir ())
    ?(project_dir = Skill_loader.default_project_skills_dir ()) () =
  let project, project_errs = scan_dir project_dir Project in
  let user, user_errs = scan_dir user_dir User in
  let project_ids = List.map (fun (e : entry) -> e.descriptor.id) project in
  let user =
    List.filter
      (fun (e : entry) -> not (List.mem e.descriptor.id project_ids))
      user
  in
  (project @ user, project_errs @ user_errs)

let already_registered (rt : Runtime.runtime) id =
  List.exists (fun (d : Types.skill_descriptor) -> d.id = id) (Runtime.list_skills rt)

(* The descriptor the runtime currently holds for [id] (None when the id is
   not registered). PAR 0.12-beta exposes no unregister/replace on
   [Runtime], so this is the only way to tell "already registered, nothing
   changed" from "already registered, frontmatter drifted". *)
let registered_descriptor (rt : Runtime.runtime) id =
  List.find_opt (fun (d : Types.skill_descriptor) -> d.id = id) (Runtime.list_skills rt)

(* Frontmatter fields that differ between two descriptors of the same id.
   Only these matter to a reload: [body_path] points at the same file, so a
   body-only edit is invisible to the runtime binding. *)
let frontmatter_diff (old_d : Types.skill_descriptor) (new_d : Types.skill_descriptor) =
  let fields = ref [] in
  let add name changed = if changed then fields := name :: !fields in
  add "name" (old_d.name <> new_d.name);
  add "description" (old_d.description <> new_d.description);
  add "trigger" (old_d.trigger <> new_d.trigger);
  add "tool_filter" (old_d.tool_filter <> new_d.tool_filter);
  add "system_prompt_override"
    (old_d.system_prompt_override <> new_d.system_prompt_override);
  List.rev !fields

let discover_and_register ~(rt : Runtime.runtime)
    ?(user_dir = Skill_loader.default_user_skills_dir ())
    ?(project_dir = Skill_loader.default_project_skills_dir ())
    ?(auto_activate = false) () =
  Hashtbl.reset custom;
  let candidates, scan_errors = scan ~user_dir ~project_dir () in
  let rejected =
    ref (List.map (fun (id, msg) -> (id, "parse: " ^ msg)) scan_errors)
  in
  let registered = ref [] in
  List.iter
    (fun (e : entry) ->
       let id = e.descriptor.id in
       if List.mem id reserved_commands then
         rejected := (id, "conflicts with built-in command") :: !rejected
       else if List.mem id builtin_skill_ids then
         rejected := (id, "conflicts with built-in skill") :: !rejected
       else if (not auto_activate) && e.descriptor.trigger <> Types.Manual then
         rejected :=
           (id, "auto/keyword skills are disabled in v0.9.0 W0/W1; use trigger: manual")
           :: !rejected
       else
         match Runtime.register_skill rt e.descriptor with
         | Ok _ ->
           Hashtbl.replace custom id e;
           registered := e :: !registered
         | Error err ->
           if already_registered rt id then begin
             (* /skills reload: keep the fresh descriptor for body/description
                reads; the runtime binding's frontmatter changes need a restart
                because the SDK exposes no unregister/replace via Runtime.
                Only report a problem when the frontmatter actually drifted —
                an unchanged skill must reload silently. *)
             Hashtbl.replace custom id e;
             registered := e :: !registered;
             (match registered_descriptor rt id with
              | Some old_d ->
                let changed = frontmatter_diff old_d e.descriptor in
                if changed <> [] then
                  rejected :=
                    (id,
                     Printf.sprintf
                       "frontmatter changed (%s); the runtime binding keeps the old \
                        values until restart"
                       (String.concat ", " changed))
                    :: !rejected
              | None -> ())
           end else
             rejected := (id, error_to_string err) :: !rejected)
    candidates;
  (List.rev !registered, List.rev !rejected)

let reload ~(rt : Runtime.runtime)
    ?(user_dir = Skill_loader.default_user_skills_dir ())
    ?(project_dir = Skill_loader.default_project_skills_dir ())
    ?(auto_activate = false) () =
  Hashtbl.reset custom;
  Skill_loader.force_reload ();
  discover_and_register ~rt ~user_dir ~project_dir ~auto_activate ()

let list_custom () =
  Hashtbl.fold (fun _ e acc -> e :: acc) custom []
  |> List.sort (fun (a : entry) (b : entry) ->
    String.compare a.descriptor.id b.descriptor.id)

let find_manual id =
  match Hashtbl.find_opt custom id with
  | Some e when e.descriptor.trigger = Types.Manual -> Some e
  | _ -> None

let read_body (e : entry) : (string, string) result =
  try
    let ic = open_in_bin e.descriptor.body_path in
    let len = in_channel_length ic in
    let content = really_input_string ic len in
    close_in ic;
    let lines = String.split_on_char '\n' content in
    let drop_frontmatter = function
      | [] -> []
      | line :: rest when String.trim line = "---" ->
        let rec after_open = function
          | [] -> []
          | l :: r when String.trim l = "---" -> r
          | _ :: r -> after_open r
        in
        after_open rest
      | _ -> lines
    in
    let body = String.concat "\n" (drop_frontmatter lines) |> String.trim in
    if body = "" then Error "empty skill body"
    else if String.length body > 64 * 1024 then Error "skill body exceeds 64 KB"
    else Ok body
  with Sys_error msg -> Error msg

let clear () = Hashtbl.reset custom
