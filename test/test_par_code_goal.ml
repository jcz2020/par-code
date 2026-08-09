open Par_code_goal

let rm_rf path =
  let rec go p =
    if Sys.file_exists p then
      if Sys.is_directory p then begin
        Array.iter (fun e -> go (Filename.concat p e)) (Sys.readdir p);
        Unix.rmdir p
      end else Sys.remove p
  in
  try go path with Sys_error _ -> ()

let with_temp_cwd f =
  let tmp = Filename.concat (Filename.get_temp_dir_name ())
    (Printf.sprintf "par_goal_test_%d" (Random.int 1_000_000)) in
  Unix.mkdir tmp 0o755;
  let old = Sys.getcwd () in
  Sys.chdir tmp;
  Fun.protect ~finally:(fun () ->
    Sys.chdir old;
    rm_rf tmp) f

let test_set_goal () =
  with_temp_cwd (fun () ->
    current := None;
    set_goal ~objective:"fix all tests" ();
    Alcotest.(check bool) "goal is set" true (!current <> None);
    match !current with
    | Some g -> Alcotest.(check string) "objective" "fix all tests" g.objective
    | None -> Alcotest.fail "expected Some")

let test_clear_goal () =
  with_temp_cwd (fun () ->
    set_goal ~objective:"test" ();
    clear_goal ();
    Alcotest.(check bool) "cleared" true (!current = None))

let test_advance_step () =
  with_temp_cwd (fun () ->
    set_goal ~objective:"test" ();
    let s1 = advance_step () in
    let s2 = advance_step () in
    Alcotest.(check int) "first step" 1 s1;
    Alcotest.(check int) "second step" 2 s2)

let test_mark_status () =
  with_temp_cwd (fun () ->
    set_goal ~objective:"test" ();
    mark_status Met;
    (match !current with
     | Some g -> Alcotest.(check string) "status met" "met" (status_label g.status)
     | None -> Alcotest.fail "expected Some");
    mark_status Aborted;
    (match !current with
     | Some g -> Alcotest.(check string) "status aborted" "aborted" (status_label g.status)
     | None -> Alcotest.fail "expected Some"))

let test_save_load_roundtrip () =
  with_temp_cwd (fun () ->
    set_goal ~objective:"roundtrip test" ~max_steps:30 ();
    ignore (advance_step ());
    ignore (advance_step ());
    mark_status Paused;
    save_current_goal_to_disk ();
    current := None;
    let loaded = load_goal_from_disk () in
    match loaded with
    | Some g ->
      Alcotest.(check string) "objective" "roundtrip test" g.objective;
      Alcotest.(check int) "step_count" 2 g.step_count;
      Alcotest.(check int) "max_steps" 30 g.max_steps;
      Alcotest.(check string) "status" "paused" (status_label g.status)
    | None -> Alcotest.fail "expected loaded goal")

let test_load_no_file () =
  with_temp_cwd (fun () ->
    let loaded = load_goal_from_disk () in
    Alcotest.(check bool) "None when no file" true (loaded = None))

let test_custom_max_steps () =
  with_temp_cwd (fun () ->
    set_goal ~objective:"test" ~max_steps:10 ();
    match !current with
    | Some g -> Alcotest.(check int) "max_steps 10" 10 g.max_steps
    | None -> Alcotest.fail "expected Some")

let test_clear_removes_file () =
  with_temp_cwd (fun () ->
    set_goal ~objective:"temp" ();
    save_current_goal_to_disk ();
    Alcotest.(check bool) "file exists" true (Sys.file_exists goal_file_path);
    clear_goal ();
    Alcotest.(check bool) "file removed" false (Sys.file_exists goal_file_path))

let () =
  Alcotest.run "par_code_goal"
    [ "basic",
      [ Alcotest.test_case "set_goal" `Quick test_set_goal;
        Alcotest.test_case "clear_goal" `Quick test_clear_goal;
        Alcotest.test_case "advance_step" `Quick test_advance_step;
        Alcotest.test_case "mark_status" `Quick test_mark_status;
        Alcotest.test_case "custom_max_steps" `Quick test_custom_max_steps ];
      "persistence",
      [ Alcotest.test_case "save/load roundtrip" `Quick test_save_load_roundtrip;
        Alcotest.test_case "load no file returns None" `Quick test_load_no_file;
        Alcotest.test_case "clear removes file" `Quick test_clear_removes_file ] ]
