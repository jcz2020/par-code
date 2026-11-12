(* test_par_code_distill.ml — v0.9.0 W2: proposal parsing, validation, atomic write. *)

let rec rm_rf path =
  if Sys.file_exists path then
    if Sys.is_directory path then begin
      Sys.readdir path
      |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path
    end else
      Sys.remove path

let read_file path =
  let ic = open_in_bin path in
  let len = in_channel_length ic in
  let s = really_input_string ic len in
  close_in ic;
  s

let with_temp_base f =
  let base = Filename.temp_file "test_distill" "" in
  Sys.remove base;
  Unix.mkdir base 0o700;
  let skills = Filename.concat base "skills" in
  Unix.mkdir skills 0o700;
  Fun.protect ~finally:(fun () -> rm_rf base) (fun () -> f skills)

let proposal ?(id = "demo") ?(name = "Demo") ?(description = "demo skill")
    ?(body = "step 1\nstep 2") () : Par_code_distill.proposal =
  { Par_code_distill.id = id; name; description; body }

let contains hay needle =
  let n = String.length needle and h = String.length hay in
  let rec loop i = i + n <= h && (String.sub hay i n = needle || loop (i + 1)) in
  n = 0 || loop 0

let test_parse_valid () =
  let text = {|proposal:
```json
{"id":"demo","name":"Demo","description":"desc","body":"step 1\nstep 2"}
```
|} in
  match Par_code_distill.parse_proposal text with
  | Ok p ->
    Alcotest.(check string) "id" "demo" p.Par_code_distill.id;
    Alcotest.(check string) "name" "Demo" p.Par_code_distill.name;
    Alcotest.(check string) "description" "desc" p.Par_code_distill.description;
    Alcotest.(check string) "body" "step 1\nstep 2" p.Par_code_distill.body
  | Error msg -> Alcotest.fail ("parse failed: " ^ msg)

let test_parse_malformed () =
  match Par_code_distill.parse_proposal "not json" with
  | Ok _ -> Alcotest.fail "expected an error"
  | Error _ -> ()

let test_parse_missing_body () =
  match Par_code_distill.parse_proposal {|{"id":"demo","name":"Demo","description":"d"}|} with
  | Ok _ -> Alcotest.fail "expected an error"
  | Error _ -> ()

let test_valid_id () =
  Alcotest.(check bool) "normal" true (Par_code_distill.valid_id "demo-skill");
  Alcotest.(check bool) "digits" true (Par_code_distill.valid_id "v2-check");
  Alcotest.(check bool) "uppercase" false (Par_code_distill.valid_id "Demo");
  Alcotest.(check bool) "leading hyphen" false (Par_code_distill.valid_id "-demo");
  Alcotest.(check bool) "trailing hyphen" false (Par_code_distill.valid_id "demo-");
  Alcotest.(check bool) "empty" false (Par_code_distill.valid_id "");
  Alcotest.(check bool) "too long" false
    (Par_code_distill.valid_id (String.make 65 'a'))

let test_validate () =
  let p = proposal () in
  Alcotest.(check bool) "valid" true
    (match Par_code_distill.validate_proposal ~existing:[] ~force:false p with
     | Ok () -> true | Error _ -> false);
  Alcotest.(check bool) "existing without force" true
    (match Par_code_distill.validate_proposal ~existing:["demo"] ~force:false p with
     | Ok () -> false | Error _ -> true);
  Alcotest.(check bool) "existing with force" true
    (match Par_code_distill.validate_proposal ~existing:["demo"] ~force:true p with
     | Ok () -> true | Error _ -> false);
  Alcotest.(check bool) "reserved id" true
    (match Par_code_distill.validate_proposal ~existing:[]
             ~force:false (proposal ~id:"skills" ()) with
     | Ok () -> false | Error _ -> true);
  Alcotest.(check bool) "builtin skill id" true
    (match Par_code_distill.validate_proposal ~existing:[]
             ~force:false (proposal ~id:"summarizer" ()) with
     | Ok () -> false | Error _ -> true);
  Alcotest.(check bool) "empty description" true
    (match Par_code_distill.validate_proposal ~existing:[]
             ~force:false (proposal ~description:"" ()) with
     | Ok () -> false | Error _ -> true);
  Alcotest.(check bool) "oversized body" true
    (match Par_code_distill.validate_proposal ~existing:[]
             ~force:false (proposal ~body:(String.make (64 * 1024 + 1) 'x') ()) with
     | Ok () -> false | Error _ -> true)

let test_parse_args () =
  let check name expected_got =
    match Par_code_distill.parse_args name with
    | Ok a -> expected_got a
    | Error msg -> Alcotest.failf "parse_args %S failed: %s" name msg
  in
  check "turn the release checklist into a skill" (fun a ->
    Alcotest.(check bool) "no user" false a.Par_code_distill.user;
    Alcotest.(check bool) "no force" false a.Par_code_distill.force;
    Alcotest.(check bool) "no target" true (a.Par_code_distill.target_id = None);
    Alcotest.(check string) "request kept"
      "turn the release checklist into a skill" a.Par_code_distill.request);
  check "--user --force ship it" (fun a ->
    Alcotest.(check bool) "user" true a.Par_code_distill.user;
    Alcotest.(check bool) "force" true a.Par_code_distill.force;
    Alcotest.(check string) "request" "ship it" a.Par_code_distill.request);
  check "--id release-notes --force rewrite" (fun a ->
    Alcotest.(check bool) "target" true
      (a.Par_code_distill.target_id = Some "release-notes");
    Alcotest.(check bool) "force" true a.Par_code_distill.force;
    Alcotest.(check string) "request" "rewrite" a.Par_code_distill.request);
  check "--id=release-notes rewrite" (fun a ->
    Alcotest.(check bool) "target" true
      (a.Par_code_distill.target_id = Some "release-notes");
    Alcotest.(check string) "request" "rewrite" a.Par_code_distill.request);
  (* A dangling --id must not fall through as request text. *)
  (match Par_code_distill.parse_args "rewrite --id" with
   | Ok _ -> Alcotest.fail "expected an error for a missing --id value"
   | Error _ -> ());
  (match Par_code_distill.parse_args "--id --force rewrite" with
   | Ok a when a.Par_code_distill.target_id <> None ->
     Alcotest.fail "--force must not be consumed as the --id value"
   | Ok _ -> ()
   | Error _ -> ());
  (match Par_code_distill.parse_args "x --id=" with
   | Ok _ -> Alcotest.fail "expected an error for an empty --id= value"
   | Error _ -> ())

let test_pin_target_id () =
  let p = proposal ~id:"model-pick" () in
  Alcotest.(check string) "no pin keeps the model id" "model-pick"
    (Par_code_distill.pin_target_id None p).Par_code_distill.id;
  Alcotest.(check string) "pin wins over the model id" "release-notes"
    (Par_code_distill.pin_target_id (Some "release-notes") p).Par_code_distill.id;
  (* Everything except the id comes from the model. *)
  let pinned = Par_code_distill.pin_target_id (Some "release-notes") p in
  Alcotest.(check string) "name kept" "Demo" pinned.Par_code_distill.name

let test_write_and_read () =
  with_temp_base (fun base ->
    let p = proposal () in
    match Par_code_distill.write_skill ~base_dir:base ~force:false p with
    | Error msg -> Alcotest.fail ("write failed: " ^ msg)
    | Ok (path, backup) ->
      Alcotest.(check bool) "no backup" true (backup = None);
      Alcotest.(check bool) "file exists" true (Sys.file_exists path);
      let user = Filename.concat (Filename.dirname base) "user" in
      (try Unix.mkdir user 0o700 with
       | Unix.Unix_error (Unix.EEXIST, _, _) -> ());
      let entries, errs =
        Par_code_skills.scan ~project_dir:base ~user_dir:user ()
      in
      Alcotest.(check int) "one entry" 1 (List.length entries);
      Alcotest.(check int) "no parse errors" 0 (List.length errs);
      let e = List.hd entries in
      Alcotest.(check string) "id" "demo" e.Par_code_skills.descriptor.id;
      Alcotest.(check bool) "manual trigger" true
        (e.Par_code_skills.descriptor.trigger = Par.Types.Manual);
      (match Par_code_skills.read_body e with
       | Ok body -> Alcotest.(check string) "body round-trip" "step 1\nstep 2" body
       | Error msg -> Alcotest.fail ("read_body failed: " ^ msg)))

let test_write_existing_backup () =
  with_temp_base (fun base ->
    let p1 = proposal ~body:"step 1" () in
    (match Par_code_distill.write_skill ~base_dir:base ~force:false p1 with
     | Ok _ -> ()
     | Error msg -> Alcotest.fail ("first write failed: " ^ msg));
    let p2 = proposal ~body:"step 3" () in
    (match Par_code_distill.write_skill ~base_dir:base ~force:false p2 with
     | Ok _ -> Alcotest.fail "overwrite without force should fail"
     | Error _ -> ());
    match Par_code_distill.write_skill ~base_dir:base ~force:true p2 with
    | Error msg -> Alcotest.fail ("forced write failed: " ^ msg)
    | Ok (_path, backup) ->
      (match backup with
       | None -> Alcotest.fail "expected a backup"
       | Some b ->
         Alcotest.(check bool) "backup exists" true (Sys.file_exists b);
         Alcotest.(check bool) "backup has old body" true
           (contains (read_file b) "step 1")))

let () =
  Alcotest.run "par_code_distill"
    [ "parse", [
        Alcotest.test_case "valid" `Quick test_parse_valid;
        Alcotest.test_case "malformed" `Quick test_parse_malformed;
        Alcotest.test_case "missing body" `Quick test_parse_missing_body;
      ];
      "validation", [
        Alcotest.test_case "id rules" `Quick test_valid_id;
        Alcotest.test_case "proposal rules" `Quick test_validate;
        Alcotest.test_case "parse args" `Quick test_parse_args;
        Alcotest.test_case "pinned id" `Quick test_pin_target_id;
      ];
      "write", [
        Alcotest.test_case "write and read" `Quick test_write_and_read;
        Alcotest.test_case "force backup" `Quick test_write_existing_backup;
      ];
    ]
