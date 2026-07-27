open Par_code_mode

let setup () = current := Build

let test_switch_returns_previous () =
  setup ();
  let prev = switch Plan in
  Alcotest.(check string) "previous was Build" "build" (label prev)

let test_switch_same_mode () =
  setup ();
  ignore (switch Plan);
  let prev2 = switch Build in
  Alcotest.(check string) "previous was Plan" "plan" (label prev2)

let test_agent_id_for_plan () =
  Alcotest.(check string) "plan agent id" "planner" (agent_id_for Plan)

let test_agent_id_for_build () =
  Alcotest.(check string) "build agent id" "par" (agent_id_for Build)

let test_label_plan () =
  Alcotest.(check string) "label Plan" "plan" (label Plan)

let test_label_build () =
  Alcotest.(check string) "label Build" "build" (label Build)

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
    (Printf.sprintf "par_mode_test_%d" (Random.int 1_000_000)) in
  Unix.mkdir tmp 0o755;
  let old = Sys.getcwd () in
  Sys.chdir tmp;
  Fun.protect ~finally:(fun () ->
    Sys.chdir old;
    rm_rf tmp) f

let test_save_load_roundtrip_plan () =
  with_temp_cwd (fun () ->
    setup ();
    ignore (switch Plan);
    save_current_mode_to_disk ();
    Alcotest.(check bool) "file exists" true (Sys.file_exists mode_file_path);
    let loaded = load_mode_from_disk () in
    Alcotest.(check bool) "loaded Plan" true (loaded = Some Plan))

let test_save_load_roundtrip_build () =
  with_temp_cwd (fun () ->
    setup ();
    save_current_mode_to_disk ();
    let loaded = load_mode_from_disk () in
    Alcotest.(check bool) "loaded Build" true (loaded = Some Build))

let test_load_no_file_returns_none () =
  with_temp_cwd (fun () ->
    let loaded = load_mode_from_disk () in
    Alcotest.(check bool) "None when no file" true (loaded = None))

let test_load_corrupted_returns_none () =
  with_temp_cwd (fun () ->
    Unix.mkdir ".par" 0o755;
    let oc = open_out mode_file_path in
    output_string oc "garbage";
    close_out oc;
    let loaded = load_mode_from_disk () in
    Alcotest.(check bool) "None for corrupted" true (loaded = None))

let test_save_creates_par_dir () =
  with_temp_cwd (fun () ->
    setup ();
    ignore (switch Build);
    save_current_mode_to_disk ();
    Alcotest.(check bool) ".par created" true (Sys.file_exists ".par");
    Alcotest.(check bool) "mode file created" true (Sys.file_exists mode_file_path))

let () =
  Alcotest.run "par_code_mode"
    [ "switch", [ Alcotest.test_case "returns previous" `Quick test_switch_returns_previous;
                  Alcotest.test_case "same mode round-trip" `Quick test_switch_same_mode ];
      "agent_id_for", [ Alcotest.test_case "plan" `Quick test_agent_id_for_plan;
                        Alcotest.test_case "build" `Quick test_agent_id_for_build ];
      "label", [ Alcotest.test_case "plan" `Quick test_label_plan;
                 Alcotest.test_case "build" `Quick test_label_build ];
      "persistence", [ Alcotest.test_case "save/load roundtrip plan" `Quick test_save_load_roundtrip_plan;
                       Alcotest.test_case "save/load roundtrip build" `Quick test_save_load_roundtrip_build;
                       Alcotest.test_case "load no file returns None" `Quick test_load_no_file_returns_none;
                       Alcotest.test_case "load corrupted returns None" `Quick test_load_corrupted_returns_none;
                       Alcotest.test_case "save creates .par dir" `Quick test_save_creates_par_dir ] ]
