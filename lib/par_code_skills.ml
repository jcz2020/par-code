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

type source = Project | User | Remote

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
  | Remote -> "remote"

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

(* -------------------------------------------------------------------------- *)
(* v0.11.0 W3: remote skill sources                                         *)
(* -------------------------------------------------------------------------- *)

(* Downloads land here and are then scanned like any other directory, so a
   fetch failure degrades to the cached copy instead of losing the skill. *)
let remote_cache_dir () =
  Filename.concat (Par_code_config.config_dir ()) "skills-remote"

let max_remote_bytes = 256 * 1024

(* Eio's capability types carry a brand parameter that cannot live in a
   module-level ref, and the same trick the SDK's MCP transport uses (store
   [Obj.repr], cast back on use) keeps the slot monomorphic here. *)
let remote_net : Obj.t option ref = ref None
let remote_sw : Eio.Switch.t option ref = ref None

let set_remote_env ~net ~sw =
  remote_net := Some (Obj.repr net);
  remote_sw := Some sw

let tls_wrapper uri raw_flow =
  let cfg = Lazy.force Par.Http_client.tls_config in
  match Uri.host uri with
  | None -> Tls_eio.client_of_flow cfg raw_flow
  | Some host ->
    (match Domain_name.of_string host with
     | Ok d ->
       (match Domain_name.host d with
        | Ok h -> Tls_eio.client_of_flow cfg ~host:h raw_flow
        | Error _ -> Tls_eio.client_of_flow cfg raw_flow)
     | Error _ -> Tls_eio.client_of_flow cfg raw_flow)

let http_get ~net ~sw url =
  let uri = Uri.of_string url in
  let client =
    Cohttp_eio.Client.make ~https:(Some tls_wrapper) net
  in
  let headers =
    Cohttp.Header.of_list
      [ "user-agent", "par-code/" ^ Par_code_version.version ]
  in
  let resp, body =
    Cohttp_eio.Client.call ~sw ~headers client `GET uri
  in
  let status = Cohttp.Code.code_of_status (Http.Response.status resp) in
  let text =
    Eio.Buf_read.parse_exn ~max_size:(max_remote_bytes + 1)
      Eio.Buf_read.take_all body
  in
  (status, text)

let fetch_url url : (string, string) result =
  match (!remote_net, !remote_sw) with
  | Some net, Some sw ->
    (try
       let status, body = http_get ~net:(Obj.obj net) ~sw url in
       if status <> 200 then Error (Printf.sprintf "HTTP %d" status)
       else if String.length body > max_remote_bytes then
         Error (Printf.sprintf "skill exceeds %d bytes" max_remote_bytes)
       else Ok body
     with ex -> Error (Printf.sprintf "fetch failed: %s" (Printexc.to_string ex)))
  | _ -> Error "no network context (remote skills load inside the REPL)"

let valid_id id =
  let len = String.length id in
  if len = 0 || len > 64 then false
  else
    let ok c = (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c = '-' in
    String.for_all ok id && id.[0] <> '-' && id.[len - 1] <> '-'

let write_atomic path content =
  let rec mkdirs d =
    if d <> "/" && d <> "." && not (Sys.file_exists d) then begin
      mkdirs (Filename.dirname d);
      try Unix.mkdir d 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ()
    end
  in
  mkdirs (Filename.dirname path);
  let tmp = path ^ ".tmp" in
  let oc = open_out_bin tmp in
  output_string oc content;
  close_out oc;
  Sys.rename tmp path

(* v0.11.0: remote skills are fetched as markdown, validated with the same
   frontmatter parser as local ones, and written to the cache only if the id is
   safe. A bad remote file therefore cannot escape the cache directory. *)
let install_remote ~dir url : (string, string) result =
  match fetch_url url with
  | Error e -> Error e
  | Ok body ->
    let tmp = Filename.temp_file "par-skill" ".md" in
    write_atomic tmp body;
    Fun.protect
      ~finally:(fun () -> try Sys.remove tmp with Sys_error _ -> ())
      (fun () ->
         match Skill_loader.parse_skill_file ~path:tmp with
         | Error e -> Error ("parse: " ^ e)
         | Ok (d : Types.skill_descriptor) ->
           if not (valid_id d.id) then Error ("invalid id: " ^ d.id)
           else if List.mem d.id reserved_commands then
             Error ("id shadows a REPL command: " ^ d.id)
           else if List.mem d.id builtin_skill_ids then
             Error ("id shadows a builtin skill: " ^ d.id)
           else begin
             write_atomic (Filename.concat (Filename.concat dir d.id) "skill.md") body;
             Ok d.id
           end)

let sync_remote (urls : string list) : (string list * (string * string) list) =
  let dir = remote_cache_dir () in
  let ok, errs =
    List.fold_left
      (fun (ok, errs) url ->
         match install_remote ~dir url with
         | Ok id -> (id :: ok, errs)
         | Error e -> (ok, (url, e) :: errs))
      ([], []) urls
  in
  (List.rev ok, List.rev errs)

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
    ?(project_dir = Skill_loader.default_project_skills_dir ())
    ?(remote_dir = remote_cache_dir ()) () =
  let project, project_errs = scan_dir project_dir Project in
  let user, user_errs = scan_dir user_dir User in
  let remote, remote_errs = scan_dir remote_dir Remote in
  let project_ids = List.map (fun (e : entry) -> e.descriptor.id) project in
  let user =
    List.filter
      (fun (e : entry) -> not (List.mem e.descriptor.id project_ids))
      user
  in
  (* Remote skills have the lowest precedence: a local skill with the same id
     always wins, so a stale download can never shadow a local edit. *)
  let taken =
    List.map (fun (e : entry) -> e.descriptor.id) (project @ user)
  in
  let remote =
    List.filter
      (fun (e : entry) -> not (List.mem e.descriptor.id taken))
      remote
  in
  (project @ user @ remote, project_errs @ user_errs @ remote_errs)

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
             (* /skills reload: PAR 0.17 can replace a binding in place, so a
                rewritten frontmatter (prompt override, tool filter, trigger)
                takes effect now instead of after a restart. The fresh entry is
                kept either way so listing and body reads stay live. *)
             Hashtbl.replace custom id e;
             registered := e :: !registered;
             (match registered_descriptor rt id with
              | Some old_d ->
                let changed = frontmatter_diff old_d e.descriptor in
                if changed <> [] then
                  (match Runtime.replace_skill rt e.descriptor with
                   | Ok _ ->
                     rejected :=
                       (id,
                        Printf.sprintf "frontmatter changed (%s); binding replaced"
                          (String.concat ", " changed))
                       :: !rejected
                   | Error e2 ->
                     rejected :=
                       (id,
                        Printf.sprintf "frontmatter changed (%s) but replace failed: %s"
                          (String.concat ", " changed)
                          (error_to_string e2))
                       :: !rejected)
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
