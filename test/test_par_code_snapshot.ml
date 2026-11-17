(* test_par_code_snapshot.ml — v0.13.0 W2 snapshots.

   Runs real git in a temp directory: the whole point is that it copes with files
   a shell command created or deleted, which a mock could not show. *)

let rec rm_rf path =
  if Sys.file_exists path then
    if Sys.is_directory path then begin
      Sys.readdir path
      |> Array.iter (fun n -> rm_rf (Filename.concat path n));
      Unix.rmdir path
    end else Sys.remove path

let write_file path content =
  let oc = open_out path in
  output_string oc content;
  close_out oc

let read_file path =
  let ic = open_in_bin path in
  let n = in_channel_length ic in
  let s = really_input_string ic n in
  close_in ic;
  s

let with_workspace f =
  let root = Filename.temp_file "snap_test" "" in
  Sys.remove root;
  Unix.mkdir root 0o700;
  Fun.protect ~finally:(fun () -> rm_rf root) (fun () -> f root)

let test_capture_and_restore () =
  with_workspace (fun root ->
      (* Real lifecycle: snapshot before the turn, the turn then edits, then
         /undo puts the pre-turn state back. *)
      write_file (Filename.concat root "a.txt") "one";
      (match Par_code_snapshot.capture ~root ~reason:"before turn 1" with
       | Error e -> Alcotest.failf "capture: %s" e
       | Ok sha -> Alcotest.(check bool) "recorded" true (sha <> ""));
      write_file (Filename.concat root "a.txt") "two";
      write_file (Filename.concat root "b.txt") "new file";
      (match Par_code_snapshot.undo ~root ~index:0 with
       | Error e -> Alcotest.failf "undo: %s" e
       | Ok _ -> ());
      Alcotest.(check string) "content restored" "one"
        (read_file (Filename.concat root "a.txt"));
      Alcotest.(check bool) "added file removed" false
        (Sys.file_exists (Filename.concat root "b.txt")))

let test_undo_is_reversible () =
  with_workspace (fun root ->
      write_file (Filename.concat root "f.txt") "v1";
      (match Par_code_snapshot.capture ~root ~reason:"before turn 1" with
       | Ok _ -> () | Error e -> Alcotest.failf "capture: %s" e);
      (* the turn rewrites the file; nothing snapshots it yet *)
      write_file (Filename.concat root "f.txt") "v2";
      (match Par_code_snapshot.undo ~root ~index:0 with
       | Ok _ -> () | Error e -> Alcotest.failf "undo: %s" e);
      Alcotest.(check string) "back to v1" "v1"
        (read_file (Filename.concat root "f.txt"));
      (* the pre-undo state was recorded, so one more undo returns to it *)
      (match Par_code_snapshot.undo ~root ~index:0 with
       | Ok _ -> () | Error e -> Alcotest.failf "undo 2: %s" e);
      Alcotest.(check string) "undo of undo" "v2"
        (read_file (Filename.concat root "f.txt")))

let test_no_changes_is_empty () =
  with_workspace (fun root ->
      write_file (Filename.concat root "x.txt") "same";
      (match Par_code_snapshot.capture ~root ~reason:"first" with
       | Ok _ -> () | Error e -> Alcotest.failf "capture: %s" e);
      match Par_code_snapshot.capture ~root ~reason:"again" with
      | Error e -> Alcotest.failf "capture 2: %s" e
      | Ok sha -> Alcotest.(check string) "no snapshot" "" sha)

let test_ignored_paths_survive () =
  with_workspace (fun root ->
      write_file (Filename.concat root "keep.txt") "v1";
      (match Par_code_snapshot.capture ~root ~reason:"v1" with
       | Ok _ -> () | Error e -> Alcotest.failf "capture: %s" e);
      Unix.mkdir (Filename.concat root "_build") 0o700;
      write_file (Filename.concat (Filename.concat root "_build") "out.bin") "junk";
      write_file (Filename.concat root "keep.txt") "v2";
      (match Par_code_snapshot.capture ~root ~reason:"v2" with
       | Ok _ -> () | Error e -> Alcotest.failf "capture: %s" e);
      (match Par_code_snapshot.undo ~root ~index:0 with
       | Ok _ -> () | Error e -> Alcotest.failf "undo: %s" e);
      Alcotest.(check bool) "ignored dir survives" true
        (Sys.file_exists (Filename.concat (Filename.concat root "_build") "out.bin")))

let () =
  Alcotest.run "par_code_snapshot"
    [ "snapshots", [
        Alcotest.test_case "capture and restore" `Quick test_capture_and_restore;
        Alcotest.test_case "undo is reversible" `Quick test_undo_is_reversible;
        Alcotest.test_case "no change, no snapshot" `Quick test_no_changes_is_empty;
        Alcotest.test_case "ignored paths survive" `Quick test_ignored_paths_survive;
      ];
    ]
