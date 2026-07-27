(* test_par_code_repl_plan_mode.ml — Integration tests for plan mode (v0.5.0).
 *
 * Cross-component coverage that unit tests in test_par_code_mode.ml and
 * test_par_code_plan_tools.ml miss:
 *   - mode switch → agent_id_for propagation
 *   - render_prompt real stdout output per mode
 *   - combined memory + plan-reference appendix logic (4 cases)
 *   - plan_enter/exit tool handler → mode → agent_id pipeline
 *   - /build persist → path → appendix-format chain
 *
 * NOT covered here (deferred to T16 manual smoke test):
 *   - /build slash command actually setting last_plan_path inside the REPL
 *     loop (the ref is local to [Par_code_repl.run])
 *   - /plan and /build printing their notice/success messages via Ui.render_*
 *   - The combined appendix actually reaching Runtime.invoke as
 *     ?system_prompt_appendix
 *   - Mode switch surviving across multiple input_line reads in the REPL
 *   These require stdin mocking / full REPL simulation, which is complex and
 *   low-value compared to the component contracts pinned here. *)

open Par

(* ── Helpers ─────────────────────────────────────────────────────────── *)

let string_contains s sub =
  let len_s = String.length s in
  let len_sub = String.length sub in
  let rec search i =
    if i + len_sub > len_s then false
    else if String.sub s i len_sub = sub then true
    else search (i + 1)
  in
  len_sub = 0 || search 0

(* Index of [sub] in [s], or -1 if absent. *)
let substring_pos sub s =
  let len = String.length sub in
  let slen = String.length s in
  let rec search i =
    if i + len > slen then -1
    else if String.sub s i len = sub then i
    else search (i + 1)
  in
  search 0

(* Reset mode to Build before each test to avoid cross-test contamination
 * from the module-level mutable state Par_code_mode.current. *)
let setup () = Par_code_mode.current := Par_code_mode.Build

(* Capture stdout of [f] by redirecting fd 1 to a pipe. Color is auto-off
 * because the pipe is not a tty (detect_color returns false), so output is
 * plain text with no ANSI escapes. *)
let capture_stdout (f : unit -> unit) : string =
  let read_fd, write_fd = Unix.pipe () in
  let saved = Unix.dup Unix.stdout in
  Unix.dup2 write_fd Unix.stdout;
  Unix.close write_fd;
  flush stdout;
  Fun.protect
    ~finally:(fun () ->
      flush stdout;
      Unix.dup2 saved Unix.stdout;
      Unix.close saved)
    (fun () -> f ());
  let buf = Buffer.create 256 in
  let chunk = Bytes.create 256 in
  let rec drain () =
    match Unix.read read_fd chunk 0 256 with
    | 0 -> ()
    | n -> Buffer.add_subbytes buf chunk 0 n; drain ()
  in
  drain ();
  Unix.close read_fd;
  Buffer.contents buf

(* Replicated from par_code_repl.ml loop (the plan_appendix / combined_appendix
 * construction around the Runtime.invoke call). This documents the
 * appendix-combination contract. If production changes how memory and plan
 * appendices combine, update these helpers IN LOCKSTEP — that is the point. *)
let format_plan_appendix (path : string) : string =
  Printf.sprintf
    "\n\n## Plan Reference\n\nYour plan was saved to `%s`.\n\
     Read it with `read_file` before implementing."
    path

let combine_appendices
    (memory_appendix : string option)
    (last_plan_path : string option)
    : string option =
  let plan_appendix = match last_plan_path with
    | Some path -> Some (format_plan_appendix path)
    | None -> None
  in
  match memory_appendix, plan_appendix with
  | None, None -> None
  | Some m, None -> Some m
  | None, Some p -> Some p
  | Some m, Some p -> Some (m ^ p)

(* Mock conversation builders (same pattern as test_par_code_plan_tools.ml). *)
let make_message (role : Types.message_role) (text : string) : Types.message =
  { role
  ; content_blocks = [Types.Text_block { text; cache_control = None }]
  ; tool_calls = None
  ; tool_call_id = None
  ; name = None
  }

let make_conv (msgs : (Types.message_role * string) list) : Types.conversation =
  { messages = List.map (fun (r, t) -> make_message r t) msgs
  ; metadata = []
  }

(* Run [f] inside a mock Eio context with a cancellation token, matching the
 * pattern in test_par_code_plan_tools.ml for exercising tool handlers. *)
let with_test_token (f : Types.cancellation_token -> unit) =
  Eio_mock.Backend.run (fun () ->
    Eio.Switch.run (fun sw ->
      let tok = Cancellation.create_token sw in
      f tok
    )
  )

let with_temp_dir (f : string -> unit) =
  let tmpfile = Filename.temp_file "par_plan_int_test_" "" in
  Sys.remove tmpfile;
  Unix.mkdir tmpfile 0o755;
  let rec rm_rf p =
    if Sys.file_exists p then
      if Sys.is_directory p then begin
        Array.iter (fun e -> rm_rf (Filename.concat p e)) (Sys.readdir p);
        Unix.rmdir p
      end else Sys.remove p
  in
  Fun.protect ~finally:(fun () -> rm_rf tmpfile) (fun () -> f tmpfile)

(* ── Mode dispatch integration ──────────────────────────────────────── *)

(* switch changes the module-level current; agent_id_for must reflect it.
 * This mirrors exactly what par_code_repl.ml does on every turn:
 *   Runtime.invoke ~agent_id:(Par_code_mode.agent_id_for !current) ... *)
let test_switch_to_plan_changes_agent_id () =
  setup ();
  let _ = Par_code_mode.switch Par_code_mode.Plan in
  let aid = Par_code_mode.agent_id_for !Par_code_mode.current in
  Alcotest.(check string) "agent_id is planner after switch to Plan"
    "planner" aid

let test_switch_to_build_changes_agent_id () =
  setup ();
  let _ = Par_code_mode.switch Par_code_mode.Plan in
  let _ = Par_code_mode.switch Par_code_mode.Build in
  let aid = Par_code_mode.agent_id_for !Par_code_mode.current in
  Alcotest.(check string) "agent_id is par after switch to Build" "par" aid

let test_switch_returns_previous_mode () =
  setup ();
  let _ = Par_code_mode.switch Par_code_mode.Plan in
  let prev = Par_code_mode.switch Par_code_mode.Build in
  Alcotest.(check bool) "previous was Plan" true
    (prev = Par_code_mode.Plan)

(* End-to-end: label tracks the current mode through multiple switches —
 * this is what render_prompt reads to decide "(plan) " vs "(build) ". *)
let test_label_matches_current_after_switch () =
  setup ();
  let _ = Par_code_mode.switch Par_code_mode.Plan in
  Alcotest.(check string) "label is plan" "plan"
    (Par_code_mode.label !Par_code_mode.current);
  let _ = Par_code_mode.switch Par_code_mode.Build in
  Alcotest.(check string) "label is build" "build"
    (Par_code_mode.label !Par_code_mode.current)

(* ── render_prompt integration (real stdout capture) ────────────────── *)

(* Calls the real Par_code_ui.render_prompt and captures what hits stdout.
 * Verifies the user-visible mode label appears. *)
let test_render_prompt_plan_contains_label () =
  setup ();
  let output = capture_stdout (fun () ->
    let b = Par_code_ui.create_backend () in
    Par_code_ui.render_prompt b Par_code_mode.Plan
  ) in
  Alcotest.(check bool) "contains (plan)" true (string_contains output "(plan)")

let test_render_prompt_build_contains_label () =
  setup ();
  let output = capture_stdout (fun () ->
    let b = Par_code_ui.create_backend () in
    Par_code_ui.render_prompt b Par_code_mode.Build
  ) in
  Alcotest.(check bool) "contains (build)" true (string_contains output "(build)")

let test_render_prompt_contains_par_prompt () =
  setup ();
  let output = capture_stdout (fun () ->
    let b = Par_code_ui.create_backend () in
    Par_code_ui.render_prompt b Par_code_mode.Build
  ) in
  Alcotest.(check bool) "contains 'par> ' prompt" true
    (string_contains output "par> ")

(* Plan prompt must not leak the build label — guards against a regression
 * where the match arm defaults to "(build) ". *)
let test_render_prompt_plan_excludes_build_label () =
  setup ();
  let output = capture_stdout (fun () ->
    let b = Par_code_ui.create_backend () in
    Par_code_ui.render_prompt b Par_code_mode.Plan
  ) in
  Alcotest.(check bool) "does not contain (build)" false
    (string_contains output "(build)")

(* ── Combined appendix logic ────────────────────────────────────────── *)

let test_combine_neither_returns_none () =
  let result = combine_appendices None None in
  Alcotest.(check bool) "None when neither present" true (result = None)

let test_combine_memory_only () =
  let result = combine_appendices (Some "\n\n## Project Memory\n\nfacts") None in
  match result with
  | None -> Alcotest.fail "expected Some"
  | Some s ->
    Alcotest.(check bool) "contains Project Memory section" true
      (string_contains s "## Project Memory");
    Alcotest.(check bool) "does not contain Plan Reference" false
      (string_contains s "## Plan Reference")

let test_combine_plan_only () =
  let result = combine_appendices None (Some "/tmp/x/plans/foo.md") in
  match result with
  | None -> Alcotest.fail "expected Some"
  | Some s ->
    Alcotest.(check bool) "contains Plan Reference section" true
      (string_contains s "## Plan Reference");
    Alcotest.(check bool) "contains the path" true
      (string_contains s "/tmp/x/plans/foo.md");
    Alcotest.(check bool) "mentions read_file" true
      (string_contains s "read_file")

let test_combine_both_concatenated () =
  let result =
    combine_appendices (Some "\n\n## Project Memory\n\nfacts")
                       (Some "/tmp/x/plans/bar.md")
  in
  match result with
  | None -> Alcotest.fail "expected Some"
  | Some s ->
    Alcotest.(check bool) "contains Project Memory section" true
      (string_contains s "## Project Memory");
    Alcotest.(check bool) "contains Plan Reference section" true
      (string_contains s "## Plan Reference")

(* Memory appendix must appear before plan-reference section in the combined
 * string — the production code does [m ^ p], not [p ^ m]. This pins that. *)
let test_combine_memory_before_plan () =
  let result =
    combine_appendices (Some "\n\n## Project Memory\n\nfact")
                       (Some "/tmp/x/plans/y.md")
  in
  match result with
  | None -> Alcotest.fail "expected Some"
  | Some s ->
    let mem_pos = substring_pos "## Project Memory" s in
    let plan_pos = substring_pos "## Plan Reference" s in
    Alcotest.(check bool) "memory section found" true (mem_pos >= 0);
    Alcotest.(check bool) "plan section found" true (plan_pos >= 0);
    Alcotest.(check bool) "memory appears before plan" true (mem_pos < plan_pos)

(* ── Plan tools + mode pipeline ─────────────────────────────────────── *)

(* Calling the plan_enter tool handler flips mode to Plan, and agent_id_for
 * on the resulting !current must yield "planner". This is the exact sequence
 * PAR's ReAct loop triggers when the LLM calls plan_enter. *)
let test_plan_enter_then_agent_id_is_planner () =
  setup ();
  with_test_token (fun tok ->
    let _ = Par_code_plan_tools.plan_enter_handler `Null tok in
    let aid = Par_code_mode.agent_id_for !Par_code_mode.current in
    Alcotest.(check string) "agent_id is planner after plan_enter"
      "planner" aid;
    Alcotest.(check bool) "mode is Plan" true
      (!Par_code_mode.current = Par_code_mode.Plan)
  )

(* Calling plan_exit flips mode back to Build, and agent_id_for yields "par". *)
let test_plan_exit_then_agent_id_is_par () =
  setup ();
  Par_code_mode.current := Par_code_mode.Plan;
  with_test_token (fun tok ->
    let _ = Par_code_plan_tools.plan_exit_handler `Null tok in
    let aid = Par_code_mode.agent_id_for !Par_code_mode.current in
    Alcotest.(check string) "agent_id is par after plan_exit" "par" aid;
    Alcotest.(check bool) "mode is Build" true
      (!Par_code_mode.current = Par_code_mode.Build)
  )

(* previous_mode field in the handler JSON tracks the actual prior state. *)
let test_plan_enter_returns_previous_in_pipeline () =
  setup ();
  with_test_token (fun tok ->
    let r1 = Par_code_plan_tools.plan_enter_handler `Null tok in
    (match r1 with
     | Types.Success json ->
       let prev =
         json |> Yojson.Safe.Util.member "previous_mode"
              |> Yojson.Safe.Util.to_string
       in
       Alcotest.(check string) "first enter previous is build" "build" prev
     | _ -> Alcotest.fail "expected Success on first plan_enter");
    let r2 = Par_code_plan_tools.plan_enter_handler `Null tok in
    (match r2 with
     | Types.Success json ->
       let prev =
         json |> Yojson.Safe.Util.member "previous_mode"
              |> Yojson.Safe.Util.to_string
       in
       Alcotest.(check string) "second enter previous is plan" "plan" prev
     | _ -> Alcotest.fail "expected Success on second plan_enter")
  )

(* ── /build persist → appendix chain (replicated contract) ──────────── *)

(* End-to-end: persist_plan_file writes a real file and returns a path; the
 * plan-appendix formatter then produces a string that references that exact
 * path. This is the contract /build relies on inside the REPL loop. *)
let test_persist_then_appendix_reflects_path () =
  with_temp_dir (fun tmpdir ->
    let old_cwd = Sys.getcwd () in
    Sys.chdir tmpdir;
    Fun.protect ~finally:(fun () -> Sys.chdir old_cwd) (fun () ->
      let conv = make_conv
        [ (Types.User, "plan the feature")
        ; (Types.Assistant, "## Goal\nBuild it\n\n## Steps\n1. Thing")
        ]
      in
      match Par_code_plan_tools.persist_plan_file conv with
      | None -> Alcotest.fail "persist_plan_file returned None"
      | Some path ->
        Alcotest.(check bool) "file exists on disk" true
          (Sys.file_exists path);
        let appendix = format_plan_appendix path in
        Alcotest.(check bool) "appendix contains full path" true
          (string_contains appendix path);
        Alcotest.(check bool) "appendix mentions read_file" true
          (string_contains appendix "read_file");
        let combined = combine_appendices None (Some path) in
        (match combined with
         | Some s ->
           Alcotest.(check bool) "combined has Plan Reference" true
             (string_contains s "## Plan Reference")
         | None -> Alcotest.fail "expected Some combined appendix")
    )
  )

(* When there's no assistant message, persist returns None and the appendix
 * combination must produce no plan section. Guards against a regression
 * where an empty/None plan path still yields a plan appendix. *)
let test_persist_none_then_no_plan_appendix () =
  with_temp_dir (fun tmpdir ->
    let old_cwd = Sys.getcwd () in
    Sys.chdir tmpdir;
    Fun.protect ~finally:(fun () -> Sys.chdir old_cwd) (fun () ->
      let conv = make_conv [ (Types.User, "no assistant reply yet") ] in
      (match Par_code_plan_tools.persist_plan_file conv with
       | None ->
         let combined = combine_appendices None None in
         Alcotest.(check bool) "no appendix when nothing persisted" true
           (combined = None)
       | Some _ -> Alcotest.fail "expected None for user-only conversation")
    )
  )

(* ── Test registration ──────────────────────────────────────────────── *)

let () =
  Alcotest.run "par_repl_plan_mode"
    [ "mode_dispatch", [
        Alcotest.test_case "switch to plan changes agent_id" `Quick
          test_switch_to_plan_changes_agent_id;
        Alcotest.test_case "switch to build changes agent_id" `Quick
          test_switch_to_build_changes_agent_id;
        Alcotest.test_case "switch returns previous mode" `Quick
          test_switch_returns_previous_mode;
        Alcotest.test_case "label matches current after switch" `Quick
          test_label_matches_current_after_switch;
      ];
      "render_prompt", [
        Alcotest.test_case "plan mode contains (plan)" `Quick
          test_render_prompt_plan_contains_label;
        Alcotest.test_case "build mode contains (build)" `Quick
          test_render_prompt_build_contains_label;
        Alcotest.test_case "contains 'par> ' prompt" `Quick
          test_render_prompt_contains_par_prompt;
        Alcotest.test_case "plan excludes (build) label" `Quick
          test_render_prompt_plan_excludes_build_label;
      ];
      "combined_appendix", [
        Alcotest.test_case "neither returns None" `Quick
          test_combine_neither_returns_none;
        Alcotest.test_case "memory only" `Quick
          test_combine_memory_only;
        Alcotest.test_case "plan only" `Quick
          test_combine_plan_only;
        Alcotest.test_case "both concatenated" `Quick
          test_combine_both_concatenated;
        Alcotest.test_case "memory appears before plan" `Quick
          test_combine_memory_before_plan;
      ];
      "plan_tools_pipeline", [
        Alcotest.test_case "plan_enter then agent_id is planner" `Quick
          test_plan_enter_then_agent_id_is_planner;
        Alcotest.test_case "plan_exit then agent_id is par" `Quick
          test_plan_exit_then_agent_id_is_par;
        Alcotest.test_case "plan_enter returns previous in pipeline" `Quick
          test_plan_enter_returns_previous_in_pipeline;
      ];
      "persist_chain", [
        Alcotest.test_case "persist then appendix reflects path" `Quick
          test_persist_then_appendix_reflects_path;
        Alcotest.test_case "persist none then no plan appendix" `Quick
          test_persist_none_then_no_plan_appendix;
      ];
    ]
