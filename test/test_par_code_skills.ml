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
    (List.mem "daily-standup" Par_code_skills.reserved_commands)

let test_registry_empty_after_clear () =
  Par_code_skills.clear ();
  Alcotest.(check int) "no custom skills" 0
    (List.length (Par_code_skills.list_custom ()));
  Alcotest.(check bool) "no manual match" true
    (Par_code_skills.find_manual "demo" = None)

let () =
  Alcotest.run "par_code_skills"
    [ "discovery", [
        Alcotest.test_case "project skill" `Quick test_scan_finds_project_skill;
        Alcotest.test_case "project shadows user" `Quick test_project_shadows_user;
        Alcotest.test_case "parse error" `Quick test_parse_error_reported;
        Alcotest.test_case "empty body" `Quick test_empty_body_rejected;
      ];
      "contracts", [
        Alcotest.test_case "reserved commands" `Quick test_reserved_commands;
        Alcotest.test_case "registry clear" `Quick test_registry_empty_after_clear;
      ];
    ]
