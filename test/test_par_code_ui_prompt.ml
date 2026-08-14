(* test_par_code_ui_prompt.ml — Tests for prompt_confirm flush + gate_response *)

(* -- Flush visibility (pipe-based, no fork) ------------------------------- *)

let test_flush_visible () =
  let (rd, wr) = Unix.pipe () in
  let oc = Unix.out_channel_of_descr wr in
  let backend = Par_code_ui.create_backend_out oc in
  Par_code_ui.render backend (Par_code_ui.text "TESTPROMPT");
  flush oc;
  let buf = Bytes.create 256 in
  let n = Unix.read rd buf 0 256 in
  Alcotest.(check bool) "bytes readable" true (n > 0);
  let content = Bytes.sub_string buf 0 n in
  Alcotest.(check string) "prompt content" "TESTPROMPT" content;
  Unix.close rd;
  close_out oc

let test_flush_no_trailing_newline () =
  let (rd, wr) = Unix.pipe () in
  let oc = Unix.out_channel_of_descr wr in
  let backend = Par_code_ui.create_backend_out oc in
  Par_code_ui.render backend (Par_code_ui.text "PROMPT");
  flush oc;
  let buf = Bytes.create 256 in
  let n = Unix.read rd buf 0 256 in
  let content = Bytes.sub_string buf 0 n in
  Alcotest.(check bool) "no newline at end" true
    (n > 0 && content.[n - 1] <> '\n');
  Unix.close rd;
  close_out oc

(* -- prompt_confirm via child process ------------------------------------ *)

let run_child_confirm ?(timeout=5.0) ~input_msg prompt =
  let (stdin_rd, stdin_wr) = Unix.pipe () in
  let (stdout_rd, stdout_wr) = Unix.pipe () in
  match Unix.fork () with
  | 0 ->
    Unix.close stdin_wr;
    Unix.close stdout_rd;
    (try ignore (Unix.setsid ()) with _ -> ());
    Unix.dup2 stdin_rd Unix.stdin;
    Unix.close stdin_rd;
    let oc = Unix.out_channel_of_descr stdout_wr in
    let backend = Par_code_ui.create_backend_out oc in
    let result = Par_code_ui.prompt_confirm ~backend prompt in
    let msg = match result with Some s -> s | None -> "NONE" in
    output_string oc msg;
    flush oc;
    close_out oc;
    exit 0
  | pid ->
    Unix.close stdin_rd;
    Unix.close stdout_wr;
    let buf = Bytes.create 4096 in
    let read_result () =
      let ready, _, _ = Unix.select [stdout_rd] [] [] timeout in
      if ready = [] then None
      else
        let n = Unix.read stdout_rd buf 0 4096 in
        if n = 0 then None
        else Some (Bytes.sub_string buf 0 n)
    in
    (* Step 1: read prompt bytes *)
    (match read_result () with
     | None ->
       ignore (Unix.kill pid Sys.sigkill);
       (try ignore (Unix.waitpid [] pid) with _ -> ());
       Unix.close stdout_rd;
       Alcotest.fail "timeout waiting for prompt"
     | Some _prompt_bytes -> ());
    (* Step 2: write input or close for EOF *)
    (match input_msg with
     | Some msg ->
       let bytes = Bytes.of_string msg in
       let len = Bytes.length bytes in
       let rec write_all off =
         if off < len then
           let n = Unix.write stdin_wr bytes off (len - off) in
           write_all (off + n)
       in
       write_all 0
     | None -> ());
    Unix.close stdin_wr;
    (* Step 3: read result *)
    let result = match read_result () with
      | Some s -> s
      | None ->
        (try ignore (Unix.kill pid Sys.sigkill) with _ -> ());
        (try ignore (Unix.waitpid [] pid) with _ -> ());
        Unix.close stdout_rd;
        Alcotest.fail "timeout waiting for result"
    in
    (try ignore (Unix.waitpid [] pid) with _ -> ());
    Unix.close stdout_rd;
    result

let test_confirm_y () =
  let result = run_child_confirm ~input_msg:(Some "y\n") "TEST [y/N] " in
  Alcotest.(check string) "y returns y" "y" result

let test_confirm_uppercase_Y () =
  let result = run_child_confirm ~input_msg:(Some "Y\n") "TEST [y/N] " in
  Alcotest.(check string) "Y returns y (lowercased)" "y" result

let test_confirm_n () =
  let result = run_child_confirm ~input_msg:(Some "n\n") "TEST [y/N] " in
  Alcotest.(check string) "n returns n" "n" result

let test_confirm_eof () =
  let result = run_child_confirm ~input_msg:None "TEST [y/N] " in
  Alcotest.(check string) "EOF returns NONE" "NONE" result

(* -- gate_response (pure function) --------------------------------------- *)

let test_gate_confirmed () =
  Par_code_mode.current := Par_code_mode.Plan;
  let json = Par_code_plan_tools.gate_response ~confirmed:true "/tmp/plan.md" in
  let open Yojson.Safe.Util in
  let mode = json |> member "mode" |> to_string in
  let saved = json |> member "plan_saved_to" |> to_string in
  Alcotest.(check string) "mode is build" "build" mode;
  Alcotest.(check string) "saved path" "/tmp/plan.md" saved;
  Alcotest.(check bool) "current switched to Build" true
    (!Par_code_mode.current = Par_code_mode.Build)

let test_gate_declined () =
  Par_code_mode.current := Par_code_mode.Plan;
  let json = Par_code_plan_tools.gate_response ~confirmed:false "/tmp/plan.md" in
  let open Yojson.Safe.Util in
  let mode = json |> member "mode" |> to_string in
  let reason = json |> member "reason" |> to_string in
  Alcotest.(check string) "mode is plan" "plan" mode;
  Alcotest.(check string) "reason" "switch_not_confirmed" reason;
  Alcotest.(check bool) "no user_declined field" true
    (Yojson.Safe.Util.member "user_declined" json = `Null);
  Alcotest.(check bool) "current stays Plan" true
    (!Par_code_mode.current = Par_code_mode.Plan)

let test_gate_declined_json_shape () =
  let json = Par_code_plan_tools.gate_response ~confirmed:false "/x.md" in
  let s = Yojson.Safe.to_string json in
  Alcotest.(check bool) "no user_declined in JSON" false
    (let has_key = function
       | `Assoc l -> List.exists (fun (k, _) -> k = "user_declined") l
       | _ -> false
     in has_key (Yojson.Safe.from_string s));
  Alcotest.(check bool) "has reason" true
    (let has_key = function
       | `Assoc l -> List.exists (fun (k, _) -> k = "reason") l
       | _ -> false
     in has_key (Yojson.Safe.from_string s))

(* -- Test runner ---------------------------------------------------------- *)

let () =
  Alcotest.run "par_code_ui_prompt"
    [ "flush", [
        Alcotest.test_case "prompt bytes visible"   `Quick test_flush_visible;
        Alcotest.test_case "no trailing newline"    `Quick test_flush_no_trailing_newline;
      ];
      "prompt_confirm", [
        Alcotest.test_case "y returns y"            `Quick test_confirm_y;
        Alcotest.test_case "Y returns y"            `Quick test_confirm_uppercase_Y;
        Alcotest.test_case "n returns n"            `Quick test_confirm_n;
        Alcotest.test_case "EOF returns None"       `Quick test_confirm_eof;
      ];
      "gate_response", [
        Alcotest.test_case "confirmed"              `Quick test_gate_confirmed;
        Alcotest.test_case "declined"               `Quick test_gate_declined;
        Alcotest.test_case "declined json shape"    `Quick test_gate_declined_json_shape;
      ];
    ]
