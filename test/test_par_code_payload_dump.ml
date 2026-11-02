open Par
open Par_code_repl_io

let tmp_seq = ref 0

(* Unique per process and per call. A millisecond-resolution timestamp alone
   collides when two tests create their temp dir inside the same millisecond,
   which makes the suite fail by timing luck rather than by a real defect. *)
let make_temp_dir () =
  let base = Filename.get_temp_dir_name () in
  let rec attempt () =
    incr tmp_seq;
    let dir = Filename.concat base
      (Printf.sprintf "par_test_payload_%d_%d" (Unix.getpid ()) (!tmp_seq)) in
    try
      Unix.mkdir dir 0o755;
      dir
    with
    | Unix.Unix_error (Unix.EEXIST, _, _) -> attempt ()
  in
  attempt ()

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

(* --- write path (added by the v0.7.4 pre-release audit) ------------------ *)
(* [debug_dir] reads $HOME at call time and [create_backend_out] captures the
   notice, so the dump path itself is testable without touching production code.
   Before this, only [prune_payload_files] was covered -- the write and truncate
   path had zero coverage. *)

let contains_substring hay needle =
  let n = String.length needle in
  let rec go i =
    i + n <= String.length hay && (String.sub hay i n = needle || go (i + 1))
  in
  n > 0 && go 0

let with_home f =
  let saved = Sys.getenv_opt "HOME" in
  let home = make_temp_dir () in
  Unix.putenv "HOME" home;
  let restore () = match saved with
    | Some h -> Unix.putenv "HOME" h
    | None -> Unix.putenv "HOME" ""
  in
  match f home with
  | r -> restore (); r
  | exception exn -> restore (); raise exn

let user_msg ~text () : Types.message =
  { role = Types.User;
    content_blocks = [ Types.Text_block { text; cache_control = None } ];
    tool_calls = None; tool_call_id = None; name = None;
    reasoning_content = None }

let debug_dir_in home = Filename.concat (Filename.concat home ".par") "debug"

let dumps_in home =
  let dir = debug_dir_in home in
  if not (Sys.file_exists dir) then []
  else
    Sys.readdir dir |> Array.to_list
    |> List.filter (fun f ->
      String.length f > 13 && String.sub f 0 8 = "payload-"
      && String.ends_with ~suffix:".json" f)
    |> List.sort compare

let read_all path =
  let ic = open_in_bin path in
  let n = in_channel_length ic in
  let s = really_input_string ic n in
  close_in ic; s

let with_par_home f =
  with_home (fun home ->
    Unix.mkdir (Filename.concat home ".par") 0o755;
    let notice = Filename.concat home "notice.txt" in
    let nc = open_out_bin notice in
    match f ~ui:(Par_code_ui.create_backend_out nc) ~home ~notice with
    | r -> close_out nc; r
    | exception exn -> close_out nc; raise exn)

let test_write_path_creates_readable_payload () =
  with_par_home (fun ~ui ~home ~notice ->
    let conv : Types.conversation =
      { messages = [ user_msg ~text:"hello" (); user_msg ~text:"world" () ];
        metadata = [] } in
    dump_payload_debug ui conv;
    match dumps_in home with
    | [ name ] ->
      let content = read_all (Filename.concat (debug_dir_in home) name) in
      Alcotest.(check int) "one entry per message" 2
        (match Yojson.Safe.from_string content with
         | `List l -> List.length l
         | _ -> Alcotest.fail "payload root is not a JSON list");
      Alcotest.(check bool) "notice mentions the dump" true
        (contains_substring (read_all notice) "payload dumped to")
    | other ->
      Alcotest.failf "expected exactly 1 payload dump, got %d" (List.length other))

let test_write_path_truncates_oversized_payload () =
  with_par_home (fun ~ui ~home ~notice:_ ->
    let big = String.make (1024 * 1024 + 16) 'x' in
    let conv : Types.conversation =
      { messages = [ user_msg ~text:big (); user_msg ~text:big (); user_msg ~text:big () ];
        metadata = [] } in
    dump_payload_debug ui conv;
    match dumps_in home with
    | [ name ] ->
      let content = read_all (Filename.concat (debug_dir_in home) name) in
      let parses =
        try ignore (Yojson.Safe.from_string content); true
        with Yojson.Json_error _ -> false
      in
      Alcotest.(check bool) "oversized payload is cut (no longer valid JSON)" false parses;
      Alcotest.(check bool) "carries the truncation marker" true
        (contains_substring content "\"_truncated\":true");
      Alcotest.(check bool) "reports the original size" true
        (contains_substring content "\"original_bytes\"");
      Alcotest.(check bool) "stays under the 2 MB cap plus marker" true
        (String.length content <= max_payload_dump_bytes + 200)
    | other ->
      Alcotest.failf "expected exactly 1 payload dump, got %d" (List.length other))

let test_two_dumps_in_same_second_do_not_collide () =
  with_par_home (fun ~ui ~home ~notice:_ ->
    let conv : Types.conversation =
      { messages = [ user_msg ~text:"same second" () ]; metadata = [] } in
    dump_payload_debug ui conv;
    dump_payload_debug ui conv;
    Alcotest.(check int) "both dumps survive" 2 (List.length (dumps_in home)))

let test_never_raises_when_dir_uncreatable () =
  (* HOME points at a regular file, so $HOME/.par/debug can never be created.
     The dump is best-effort by contract: no raise, no control-flow change. *)
  let saved = Sys.getenv_opt "HOME" in
  let blocker = Filename.concat (make_temp_dir ()) "not-a-dir" in
  let oc = open_out_bin blocker in output_string oc "x"; close_out oc;
  Unix.putenv "HOME" blocker;
  let restore () = match saved with
    | Some h -> Unix.putenv "HOME" h
    | None -> Unix.putenv "HOME" ""
  in
  let conv : Types.conversation =
    { messages = [ user_msg ~text:"unwritable" () ]; metadata = [] } in
  (match dump_payload_debug (Par_code_ui.create_backend ()) conv with
   | () -> ()
   | exception exn ->
     restore ();
     Alcotest.failf "dump raised: %s" (Printexc.to_string exn));
  restore ()

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
      "write_path", [
        Alcotest.test_case "creates readable payload" `Quick test_write_path_creates_readable_payload;
        Alcotest.test_case "truncates oversized payload" `Quick test_write_path_truncates_oversized_payload;
        Alcotest.test_case "same-second dumps do not collide" `Quick test_two_dumps_in_same_second_do_not_collide;
        Alcotest.test_case "never raises when dir uncreatable" `Quick test_never_raises_when_dir_uncreatable;
      ];
    ]
