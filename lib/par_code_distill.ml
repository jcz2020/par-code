(* par_code_distill.ml — v0.9.0 W2: turn a repeated workflow into a manual skill.
 *
 * The distiller agent only proposes a skill (JSON); this module validates the
 * proposal, shows it to the user, writes <base>/<id>/skill.md atomically, parses
 * it back with the SDK loader, and reloads the custom-command registry.
 * No silent overwrite: an existing id needs --force and is backed up first. *)

open Par

let distiller_agent_id = "skill-distiller"

let distiller_system_prompt = {|
You are a skill distiller for par-code, a terminal coding agent.

Given the user's request, the recent session context, the project memory index,
and the existing skill ids, design ONE reusable manual skill that captures a
repeated workflow.

Return ONLY a JSON object:
{"id":"<lowercase-hyphen>","name":"<display name>","description":"<one line, <=1024 chars>","body":"<markdown instructions>"}

Rules:
- id: lowercase letters, digits, and hyphens; start/end with a letter or digit;
  normally do not reuse a built-in command or an existing skill id. If the
  request pins a target skill id, use exactly that id, even if it exists.
- body: instructions for the agent (what to do, in what order, what to check).
  It is NOT a shell script and must not contain secrets, tokens, or external
  project/company names.
- Keep the body focused on one workflow; <= 64 KB.
- trigger is always manual; the user invokes the skill as /<id>.
|}

type proposal = {
  id : string;
  name : string;
  description : string;
  body : string;
}

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

let usage =
  "usage: /distill <what to turn into a skill> [--id <id>] [--user] [--force]"

(* Flags are recognized anywhere in the argument string; every other token is
   request text. [--id <id>] pins the skill id so the distiller cannot invent
   a different one — that is what makes [--force] reachable: the user names
   the existing skill to rewrite instead of hoping the model picks it. *)
type args = {
  user : bool;
  force : bool;
  target_id : string option;
  request : string;
}

let parse_args (args : string) : (args, string) result =
  let tokens =
    String.split_on_char ' ' args |> List.filter (fun s -> s <> "")
  in
  let rec go user force target_id acc = function
    | [] -> Ok { user; force; target_id; request = String.concat " " (List.rev acc) }
    | "--user" :: rest -> go true force target_id acc rest
    | "--force" :: rest -> go user true target_id acc rest
    | "--id" :: id :: rest ->
      if String.length id > 1 && id.[0] = '-' then Error usage
      else go user force (Some id) acc rest
    | "--id" :: [] -> Error usage
    | tok :: rest ->
      if String.length tok >= 5 && String.sub tok 0 5 = "--id=" then begin
        let v = String.sub tok 5 (String.length tok - 5) in
        if v = "" then Error usage
        else go user force (Some v) acc rest
      end else go user force target_id (tok :: acc) rest
  in
  go false false None [] tokens

let last_n s n =
  let len = String.length s in
  if len <= n then s else String.sub s (len - n) n

let valid_id id =
  let len = String.length id in
  if len = 0 || len > 64 then false
  else
    let is_ok c =
      (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c = '-'
    in
    String.for_all is_ok id
    && id.[0] <> '-' && id.[len - 1] <> '-'

(* The pinned target id wins over whatever id the model returns: /distill
   --id foo must write foo, otherwise [--force] could never reach an existing
   skill (the distiller is told to invent a fresh id). *)
let pin_target_id (target : string option) (p : proposal) : proposal =
  match target with
  | None -> p
  | Some id -> { p with id }

(* Early check on a user-pinned id — fail before spending an LLM call. *)
let check_target_id (id : string) : (unit, string) result =
  if not (valid_id id) then
    Error "id must be lowercase letters/digits/hyphens (<=64 chars, no leading/trailing hyphen)"
  else if List.mem id Par_code_skills.reserved_commands then
    Error (Printf.sprintf "id %s conflicts with a built-in command" id)
  else if List.mem id Par_code_skills.builtin_skill_ids then
    Error (Printf.sprintf "id %s conflicts with a built-in skill" id)
  else Ok ()

let parse_proposal (text : string) : (proposal, string) result =
  let text = Par.Json_extract.strip_think_tags text in
  match Par_code_json_extract.extract_object text with
  | None -> Error "model did not return a JSON object"
  | Some json_str ->
    (try
       let json = Yojson.Safe.from_string json_str in
       let open Yojson.Safe.Util in
       let field name =
         json |> member name |> to_string_option |> Option.value ~default:""
       in
       let id = String.trim (field "id") in
       let name = String.trim (field "name") in
       let description = String.trim (field "description") in
       let body = field "body" in
       if String.trim body = "" then Error "proposal body is empty"
       else Ok { id; name; description; body }
     with Yojson.Json_error msg ->
       Error (Printf.sprintf "invalid proposal JSON: %s" msg))

let validate_proposal ~(existing : string list) ~(force : bool)
    (p : proposal) : (unit, string) result =
  if not (valid_id p.id) then
    Error "id must be lowercase letters/digits/hyphens (<=64 chars, no leading/trailing hyphen)"
  else if List.mem p.id Par_code_skills.reserved_commands then
    Error (Printf.sprintf "id %s conflicts with a built-in command" p.id)
  else if List.mem p.id Par_code_skills.builtin_skill_ids then
    Error (Printf.sprintf "id %s conflicts with a built-in skill" p.id)
  else if List.mem p.id existing && not force then
    Error (Printf.sprintf "skill %s already exists (use --force to overwrite)" p.id)
  else if p.name = "" then Error "skill name is empty"
  else if p.description = "" then Error "skill description is empty"
  else if String.length p.description > 1024 then
    Error "skill description exceeds 1024 chars"
  else if String.length p.body > 64 * 1024 then
    Error "skill body exceeds 64 KB"
  else Ok ()

let one_line s =
  String.map (fun c -> if c = '\n' || c = '\r' then ' ' else c) s |> String.trim

let render_skill_file (p : proposal) =
  Printf.sprintf
    "---\nschema_version: 1\nid: %s\nname: %s\ndescription: %s\ntrigger: manual\ntool_filter: All\n---\n\n%s\n"
    p.id (one_line p.name) (one_line p.description) p.body

let rec mkdir_p dir =
  if dir = "" || dir = "." || dir = "/" || Sys.file_exists dir then ()
  else begin
    let parent = Filename.dirname dir in
    if parent <> dir then mkdir_p parent;
    (try Unix.mkdir dir 0o755 with
     | Unix.Unix_error (Unix.EEXIST, _, _) -> ())
  end

let copy_file src dst =
  let ic = open_in_bin src in
  let len = in_channel_length ic in
  let content = really_input_string ic len in
  close_in ic;
  let oc = open_out_bin dst in
  output_string oc content;
  close_out oc

let write_skill ~base_dir ~(force : bool) (p : proposal) :
  ((string * string option), string) result =
  if not (valid_id p.id) then Error "invalid skill id"
  else
    try begin
      let dir = Filename.concat base_dir p.id in
    let path = Filename.concat dir "skill.md" in
    if Sys.file_exists path && not force then
      Error (Printf.sprintf "skill %s already exists at %s (use --force)" p.id path)
    else begin
      mkdir_p dir;
      let tmp = path ^ ".tmp" in
      let oc = open_out_bin tmp in
      output_string oc (render_skill_file p);
      close_out oc;
      match Skill_loader.parse_skill_file ~path:tmp with
      | Error msg ->
        (try Sys.remove tmp with Sys_error _ -> ());
        Error (Printf.sprintf "generated skill does not parse: %s" msg)
      | Ok _ ->
        let backup =
          if not (Sys.file_exists path) then None
          else begin
            let backup_dir =
              Filename.concat (Filename.dirname base_dir)
                (Filename.concat "backups" "skills")
            in
            mkdir_p backup_dir;
            let stamp = Printf.sprintf "%.0f" (Unix.gettimeofday ()) in
            let dst =
              Filename.concat backup_dir
                (Printf.sprintf "%s-%s.md" p.id stamp)
            in
            copy_file path dst;
            Some dst
          end
        in
        Sys.rename tmp path;
        Ok (path, backup)
      end
    end with
    | Sys_error msg -> Error msg
    | Unix.Unix_error (e, fn, arg) ->
      Error (Printf.sprintf "%s: %s%s" fn (Unix.error_message e)
               (if arg = "" then "" else " (" ^ arg ^ ")"))

let build_context ~(rt : Runtime.runtime) ~(mem_db : Par_code_memory.t option)
    ~(conv : Types.conversation option) ~(target_id : string option)
    (request : string) =
  let transcript =
    match conv with
    | Some c -> last_n (Par_code_extractor.serialize_transcript c) 8000
    | None -> ""
  in
  let memory_index =
    match mem_db with
    | Some t ->
      let pid = Par_code_memory.resolve_project_id () in
      last_n (Par_code_memory.render_index t ~project_id:pid) 4000
    | None -> ""
  in
  let existing =
    Runtime.list_skills rt
    |> List.map (fun (d : Types.skill_descriptor) -> d.id)
    |> List.sort_uniq String.compare
    |> String.concat ", "
  in
  let target =
    match target_id with
    | None -> ""
    | Some id ->
      Printf.sprintf
        "\n\n## Target skill id\nThe user asked to (re)write the skill with id `%s`.\nUse exactly this id, even if it already exists — the rewrite \
         overwrites it." id
  in
  Printf.sprintf
    "## Request\n%s%s\n\n## Recent session\n%s\n\n## Project memory index\n%s\n\n## Existing skill ids\n%s"
    request target transcript memory_index existing

let confirm_and_write ~(rt : Runtime.runtime) ~(ui : Par_code_ui.backend)
    (parsed : args) (proposal : proposal) =
  let base_dir =
    if parsed.user then Skill_loader.default_user_skills_dir ()
    else Skill_loader.default_project_skills_dir ()
  in
  if parsed.user then
    Par_code_ui.render_notice ui
      "Note: a project skill with the same id shadows a user skill.";
  let path = Filename.concat (Filename.concat base_dir proposal.id) "skill.md" in
  Par_code_ui.render_notice ui "Proposed skill:";
  Par_code_ui.render_notice ui
    (Printf.sprintf "  /%s  %s" proposal.id proposal.name);
  Par_code_ui.render_notice ui
    (Printf.sprintf "  %s" proposal.description);
  Par_code_ui.render_notice ui
    (Printf.sprintf "  path: %s" path);
  Par_code_ui.render_notice ui "  body:";
  let preview =
    if String.length proposal.body <= 2000 then proposal.body
    else String.sub proposal.body 0 2000 ^ "\n[...]"
  in
  Par_code_ui.render_notice ui preview;
  match Par_code_ui.prompt_confirm ~backend:ui "Write this skill? [y/N] " with
  | Some ("y" | "yes") ->
    (match write_skill ~base_dir ~force:parsed.force proposal with
     | Error msg ->
       Par_code_ui.render_error ui
         (Printf.sprintf "[distill] %s" msg)
     | Ok (written, backup) ->
       Par_code_ui.render_success ui
         (Printf.sprintf "[distill] wrote %s" written);
       (match backup with
        | Some b ->
          Par_code_ui.render_notice ui
            (Printf.sprintf "[distill] backup: %s" b)
        | None -> ());
       let registered, rejected = Par_code_skills.reload ~rt () in
       Par_code_ui.render_notice ui
         (Printf.sprintf "[distill] registered %d skill(s)"
            (List.length registered));
       List.iter
         (fun (id, reason) ->
            Par_code_ui.render_warning ui
              (Printf.sprintf "[distill] %s: %s" id reason))
         rejected;
       Par_code_ui.render_notice ui
         (Printf.sprintf "Run /%s <args>." proposal.id))
  | _ ->
    Par_code_ui.render_notice ui "[distill] cancelled"

let run ~(rt : Runtime.runtime) ~(ui : Par_code_ui.backend)
    ~(mem_db : Par_code_memory.t option) ~(conv : Types.conversation option)
    ?cancellation_token ?(on_invoke = fun _ -> ()) ~(args : string) () : unit =
  match parse_args args with
  | Error msg -> Par_code_ui.render_warning ui msg
  | Ok parsed when parsed.request = "" ->
    Par_code_ui.render_notice ui usage
  | Ok parsed ->
    let proceed () =
      Par_code_ui.render_notice ui "[distilling...]";
      let message =
        build_context ~rt ~mem_db ~conv ~target_id:parsed.target_id parsed.request
      in
      let result =
        on_invoke true;
        Fun.protect ~finally:(fun () -> on_invoke false) (fun () ->
          Runtime.invoke rt ~agent_id:distiller_agent_id ~message
            ~save:false ~update_current:false
            ~on_chunk:(Some (fun (_ : Types.llm_response_chunk) -> ()))
            ?cancellation_token ())
      in
      (* A cancelled call must never fall through to parsing: when the provider
         stream dies from the signal the SDK can return [Ok] with empty text,
         which would otherwise surface as a bogus "no JSON object" error — and
         a complete-looking reply would still be offered for writing. *)
      let cancelled =
        match cancellation_token with
        | Some tok -> Par.Cancellation.is_cancelled tok
        | None -> false
      in
      if cancelled then Par_code_ui.render_notice ui "[distill] cancelled"
      else
      match result with
      | Error (Types.Cancelled _, _) ->
        Par_code_ui.render_notice ui "[distill] cancelled"
      | Error (e, _) ->
        Par_code_ui.render_error ui
          (Printf.sprintf "[distill] distiller failed: %s" (error_to_string e))
      | Ok result ->
        let text =
          match result.Types.response.Types.text with Some t -> t | None -> ""
        in
        (match parse_proposal text with
         | Error msg ->
           Par_code_ui.render_error ui (Printf.sprintf "[distill] %s" msg)
         | Ok raw ->
           let proposal = pin_target_id parsed.target_id raw in
           let existing =
             Runtime.list_skills rt
             |> List.map (fun (d : Types.skill_descriptor) -> d.id)
           in
           (match validate_proposal ~existing ~force:parsed.force proposal with
            | Error msg ->
              Par_code_ui.render_error ui (Printf.sprintf "[distill] %s" msg)
            | Ok () -> confirm_and_write ~rt ~ui parsed proposal))
    in
    match parsed.target_id with
    | Some id ->
      (match check_target_id id with
       | Error msg ->
         Par_code_ui.render_error ui (Printf.sprintf "[distill] %s" msg)
       | Ok () -> proceed ())
    | None -> proceed ()
