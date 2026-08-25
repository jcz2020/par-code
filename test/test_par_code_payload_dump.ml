open Par_code_repl

let make_temp_dir () =
  let base = Filename.get_temp_dir_name () in
  let dir = Filename.concat base
    (Printf.sprintf "par_test_payload_%d" (int_of_float (Unix.gettimeofday () *. 1000.))) in
  Unix.mkdir dir 0o755;
  dir

let rm_rf dir =
  let entries = Sys.readdir dir in
  Array.iter (fun f ->
    (try Sys.remove (Filename.concat dir f) with Sys_error _ -> ())
  ) entries;
  (try Unix.rmdir dir with Unix.Unix_error _ -> ())

let touch_file path mtime =
  let oc = open_out path in
  output_string oc "{}";
  close_out oc;
  Unix.utimes path mtime mtime

let list_names dir =
  Sys.readdir dir |> Array.to_list |> List.sort compare

let test_empty_dir () =
  let dir = make_temp_dir () in
  (match prune_payload_files ~dir ~keep:5 with
   | [] -> ()
   | _ -> Alcotest.fail "expected empty list from empty dir");
  rm_rf dir

let test_no_payload_files () =
  let dir = make_temp_dir () in
  let oc = open_out (Filename.concat dir "other.json") in
  output_string oc "x"; close_out oc;
  (match prune_payload_files ~dir ~keep:5 with
   | [] -> ()
   | _ -> Alcotest.fail "expected empty when no payload files");
  rm_rf dir

let test_keeps_all_when_under_limit () =
  let dir = make_temp_dir () in
  for i = 1 to 3 do
    touch_file (Filename.concat dir (Printf.sprintf "payload-%d.json" i))
      (float_of_int (1000 + i))
  done;
  let kept = prune_payload_files ~dir ~keep:5 in
  Alcotest.(check int) "kept 3" 3 (List.length kept);
  Alcotest.(check int) "dir has 3" 3 (List.length (list_names dir));
  rm_rf dir

let test_prunes_oldest () =
  let dir = make_temp_dir () in
  for i = 1 to 8 do
    touch_file (Filename.concat dir (Printf.sprintf "payload-%d.json" i))
      (float_of_int (1000 + i))
  done;
  let kept = prune_payload_files ~dir ~keep:5 in
  Alcotest.(check int) "kept 5" 5 (List.length kept);
  Alcotest.(check int) "dir has 5" 5 (List.length (list_names dir));
  let names = list_names dir in
  List.iter (fun expected ->
    Alcotest.(check bool) (expected ^ " present") true (List.mem expected names)
  ) [ "payload-4.json"; "payload-5.json"; "payload-6.json";
      "payload-7.json"; "payload-8.json" ];
  rm_rf dir

let test_prunes_to_exact_count () =
  let dir = make_temp_dir () in
  for i = 1 to 10 do
    touch_file (Filename.concat dir (Printf.sprintf "payload-%d.json" i))
      (float_of_int (1000 + i))
  done;
  let _ = prune_payload_files ~dir ~keep:5 in
  Alcotest.(check int) "exactly 5" 5 (List.length (list_names dir));
  rm_rf dir

let test_keep_1 () =
  let dir = make_temp_dir () in
  for i = 1 to 4 do
    touch_file (Filename.concat dir (Printf.sprintf "payload-%d.json" i))
      (float_of_int (1000 + i))
  done;
  let _ = prune_payload_files ~dir ~keep:1 in
  let names = list_names dir in
  Alcotest.(check int) "kept 1" 1 (List.length names);
  Alcotest.(check bool) "newest kept" true (List.mem "payload-4.json" names);
  rm_rf dir

let test_nonexistent_dir () =
  let kept = prune_payload_files ~dir:"/tmp/par_test_no_such_dir_99999" ~keep:5 in
  Alcotest.(check int) "empty on error" 0 (List.length kept)

let test_ignores_non_payload () =
  let dir = make_temp_dir () in
  touch_file (Filename.concat dir "payload-1.json") 1001.0;
  touch_file (Filename.concat dir "payload-2.json") 1002.0;
  touch_file (Filename.concat dir "checkpoint.json") 1003.0;
  touch_file (Filename.concat dir "payload-3.json") 1004.0;
  let _ = prune_payload_files ~dir ~keep:2 in
  let names = list_names dir in
  Alcotest.(check bool) "checkpoint survives" true (List.mem "checkpoint.json" names);
  Alcotest.(check int) "2 payload + 1 other" 3 (List.length names);
  rm_rf dir

let () =
  Alcotest.run "par_payload_dump"
    [ "prune_empty", [
        Alcotest.test_case "empty dir" `Quick test_empty_dir;
        Alcotest.test_case "no payload files" `Quick test_no_payload_files;
      ];
      "prune_under_limit", [
        Alcotest.test_case "keeps all when under limit" `Quick test_keeps_all_when_under_limit;
      ];
      "prune_over_limit", [
        Alcotest.test_case "prunes oldest" `Quick test_prunes_oldest;
        Alcotest.test_case "exact count" `Quick test_prunes_to_exact_count;
        Alcotest.test_case "keep 1" `Quick test_keep_1;
      ];
      "prune_edge_cases", [
        Alcotest.test_case "nonexistent dir" `Quick test_nonexistent_dir;
        Alcotest.test_case "ignores non-payload files" `Quick test_ignores_non_payload;
      ];
    ]
