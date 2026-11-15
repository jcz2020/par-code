(* test_par_code_skills.ml — v0.9.0 W0/W1 skill discovery tests.
   Pure filesystem/frontmatter checks: no runtime, no LLM, no network. *)

let rec rm_rf path =
  if Sys.file_exists path then
    if Sys.is_directory path then begin
      Sys.readdir path
      |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path
    end else
      Sys.remove path

let write_file path content =
  let oc = open_out path in
  output_string oc content;
  close_out oc

let with_temp_base f =
  let base = Filename.temp_file "test_skills" "" in
  Sys.remove base;
  Unix.mkdir base 0o700;
  Fun.protect ~finally:(fun () -> rm_rf base) (fun () -> f base)

let skill_md ~id ~trigger ~body =
  Printf.sprintf
    "---\nschema_version: 1\nid: %s\nname: %s\ndescription: %s demo skill\ntrigger: %s\n---\n\n%s\n"
    id id id trigger body

let make_skill base ~source ~id ~trigger ~body =
  let dir = Filename.concat base (Filename.concat source id) in
  Unix.mkdir (Filename.concat base source) 0o700;
  Unix.mkdir dir 0o700;
  write_file (Filename.concat dir "skill.md") (skill_md ~id ~trigger ~body)

let scan ~base =
  Par_code_skills.scan
    ~project_dir:(Filename.concat base "project")
    ~user_dir:(Filename.concat base "user") ()

let test_scan_finds_project_skill () =
  with_temp_base (fun base ->
    make_skill base ~source:"project" ~id:"demo" ~trigger:"manual"
      ~body:"Do the thing.";
    let entries, errs = scan ~base in
    Alcotest.(check int) "one entry" 1 (List.length entries);
    Alcotest.(check int) "no errors" 0 (List.length errs);
    let e = List.hd entries in
    Alcotest.(check string) "id" "demo" e.Par_code_skills.descriptor.id;
    Alcotest.(check string) "source" "project"
      (Par_code_skills.source_string e.Par_code_skills.source);
    match Par_code_skills.read_body e with
    | Ok body -> Alcotest.(check string) "body" "Do the thing." body
    | Error msg -> Alcotest.fail ("read_body failed: " ^ msg))

let test_project_shadows_user () =
  with_temp_base (fun base ->
    make_skill base ~source:"project" ~id:"demo" ~trigger:"manual"
      ~body:"project body";
    make_skill base ~source:"user" ~id:"demo" ~trigger:"manual"
      ~body:"user body";
    let entries, _ = scan ~base in
    Alcotest.(check int) "deduped" 1 (List.length entries);
    let e = List.hd entries in
    Alcotest.(check string) "project wins" "project"
      (Par_code_skills.source_string e.Par_code_skills.source);
    match Par_code_skills.read_body e with
    | Ok body -> Alcotest.(check string) "project body" "project body" body
    | Error msg -> Alcotest.fail ("read_body failed: " ^ msg))

let test_parse_error_reported () =
  with_temp_base (fun base ->
    let dir = Filename.concat (Filename.concat base "project") "broken" in
    Unix.mkdir (Filename.concat base "project") 0o700;
    Unix.mkdir dir 0o700;
    write_file (Filename.concat dir "skill.md")
      "---\nschema_version: 1\nname: missing id\n---\nbody\n";
    let entries, errs = scan ~base in
    Alcotest.(check int) "no entries" 0 (List.length entries);
    Alcotest.(check bool) "error reported" true (List.length errs = 1);
    match errs with
    | (id, _) :: _ -> Alcotest.(check string) "error id" "broken" id
    | [] -> Alcotest.fail "expected an error")

let test_empty_body_rejected () =
  with_temp_base (fun base ->
    make_skill base ~source:"project" ~id:"empty" ~trigger:"manual" ~body:"";
    let entries, _ = scan ~base in
    match entries with
    | [ e ] ->
      (match Par_code_skills.read_body e with
       | Ok _ -> Alcotest.fail "empty body should be rejected"
       | Error _ -> ())
    | _ -> Alcotest.fail "expected one entry")

let test_reserved_commands () =
  Alcotest.(check bool) "skills is reserved" true
    (List.mem "skills" Par_code_skills.reserved_commands);
  Alcotest.(check bool) "help is reserved" true
    (List.mem "help" Par_code_skills.reserved_commands);
  Alcotest.(check bool) "custom id is free" false
    (List.mem "daily-standup" Par_code_skills.reserved_commands);
  Alcotest.(check bool) "builtin skill ids are not commands" false
    (List.mem "summarizer" Par_code_skills.reserved_commands);
  Alcotest.(check bool) "summarizer is a builtin skill" true
    (List.mem "summarizer" Par_code_skills.builtin_skill_ids)

let parse_skill path =
  match Par.Skill_loader.parse_skill_file ~path with
  | Ok d -> d
  | Error msg -> Alcotest.failf "parse_skill_file %s: %s" path msg

let test_frontmatter_diff () =
  with_temp_base (fun base ->
    let write ~name ~description ~trigger =
      let path = Filename.concat base "skill.md" in
      let oc = open_out path in
      Printf.sprintf
        "---\nschema_version: 1\nid: demo\nname: %s\ndescription: %s\ntrigger: %s\n---\n\nbody\n"
        name description trigger
      |> output_string oc;
      close_out oc;
      parse_skill path
    in
    let a = write ~name:"Demo" ~description:"old line" ~trigger:"manual" in
    (* Re-parsing the same bytes must report no drift: otherwise every reload
       would warn about every registered skill. *)
    let same = write ~name:"Demo" ~description:"old line" ~trigger:"manual" in
    Alcotest.(check (list string)) "unchanged" []
      (Par_code_skills.frontmatter_diff a same);
    let retitled = write ~name:"Demo 2" ~description:"old line" ~trigger:"manual" in
    Alcotest.(check (list string)) "name only" [ "name" ]
      (Par_code_skills.frontmatter_diff a retitled);
    let edited = write ~name:"Demo 2" ~description:"new line" ~trigger:"manual" in
    Alcotest.(check (list string)) "name + description"
      [ "name"; "description" ]
      (Par_code_skills.frontmatter_diff a edited));
  (* The trivial body-only edit is invisible to the frontmatter diff: the body
     is read from disk on every invocation, so it needs no restart warning. *)
  with_temp_base (fun base ->
    let write body =
      let path = Filename.concat base "skill.md" in
      let oc = open_out path in
      Printf.sprintf
        "---\nschema_version: 1\nid: demo\nname: Demo\ndescription: d\ntrigger: manual\n---\n\n%s\n"
        body
      |> output_string oc;
      close_out oc;
      parse_skill path
    in
    Alcotest.(check (list string)) "body only" []
      (Par_code_skills.frontmatter_diff (write "step 1") (write "step 2")))

let test_registry_empty_after_clear () =
  Par_code_skills.clear ();
  Alcotest.(check int) "no custom skills" 0
    (List.length (Par_code_skills.list_custom ()));
  Alcotest.(check bool) "no manual match" true
    (Par_code_skills.find_manual "demo" = None)

let test_local_shadows_remote () =
  with_temp_base (fun base ->
    let project = Filename.concat base "project" in
    let user = Filename.concat base "user" in
    let remote = Filename.concat base "remote" in
    List.iter (fun d -> Unix.mkdir d 0o700) [ project; user; remote ];
    make_skill project ~source:"skills" ~id:"shared" ~trigger:"manual" ~body:"project body";
    make_skill user ~source:"skills" ~id:"shared" ~trigger:"manual" ~body:"user body";
    let mk_remote id body =
      let dir = Filename.concat remote id in
      Unix.mkdir dir 0o700;
      write_file (Filename.concat dir "skill.md")
        (skill_md ~id ~trigger:"manual" ~body)
    in
    mk_remote "shared" "remote body";
    mk_remote "only-remote" "remote body";
    let entries, errs =
      Par_code_skills.scan
        ~project_dir:(Filename.concat project "skills")
        ~user_dir:(Filename.concat user "skills")
        ~remote_dir:remote ()
    in
    Alcotest.(check (list string)) "no parse errors" [] (List.map fst errs);
    let source_of id =
      List.find_map
        (fun (e : Par_code_skills.entry) ->
           if e.descriptor.id = id then Some (Par_code_skills.source_string e.source)
           else None)
        entries
    in
    Alcotest.(check (option string)) "project wins" (Some "project") (source_of "shared");
    Alcotest.(check (option string)) "remote only" (Some "remote") (source_of "only-remote");
    Alcotest.(check int) "three entries" 2 (List.length entries))

(* No Eio network context is installed in the test process, so a URL must be
   reported rather than crash; an empty source list is a no-op. *)
let test_sync_remote_without_env () =
  Alcotest.(check (pair (list string) (list (pair string string))))
    "empty source list" ([], []) (Par_code_skills.sync_remote []);
  let _, errs = Par_code_skills.sync_remote [ "http://127.0.0.1:9/skill.md" ] in
  match errs with
  | [ (url, reason) ] ->
    Alcotest.(check string) "url echoed" "http://127.0.0.1:9/skill.md" url;
    Alcotest.(check bool) "reports missing context" true
      (String.length reason > 0
       && (try
             ignore (Str.search_forward (Str.regexp "network") reason 0);
             true
           with Not_found -> false))
  | _ -> Alcotest.fail "expected exactly one fetch error"

let () =
  Alcotest.run "par_code_skills"    [ "discovery", [
        Alcotest.test_case "project skill" `Quick test_scan_finds_project_skill;
        Alcotest.test_case "project shadows user" `Quick test_project_shadows_user;
        Alcotest.test_case "parse error" `Quick test_parse_error_reported;
        Alcotest.test_case "empty body" `Quick test_empty_body_rejected;
      ];
      "contracts", [
        Alcotest.test_case "reserved commands" `Quick test_reserved_commands;
        Alcotest.test_case "frontmatter drift" `Quick test_frontmatter_diff;
        Alcotest.test_case "registry clear" `Quick test_registry_empty_after_clear;
      ];
      "remote", [
        Alcotest.test_case "local shadows remote" `Quick test_local_shadows_remote;
        Alcotest.test_case "no network context" `Quick test_sync_remote_without_env;
      ];
    ]
