(* test_par_code_screen.ml — pure layout helpers of the full-screen UI. *)

let wide_chars_break_at_the_column_limit () =
  (* "模" is two columns wide, so a ten-column row holds five of them. *)
  let s = String.concat "" (List.init 12 (fun _ -> "模")) in
  let lines = Par_code_screen.wrap_text ~cols:10 s in
  Alcotest.(check int) "rows" 3 (List.length lines);
  Alcotest.(check string) "first row" "模模模模模" (List.nth lines 0);
  Alcotest.(check string) "last row" "模模" (List.nth lines 2)

let ascii_wraps_without_losing_characters () =
  let lines = Par_code_screen.wrap_text ~cols:10 (String.make 25 'a') in
  Alcotest.(check (list string)) "rows"
    [ "aaaaaaaaaa"; "aaaaaaaaaa"; "aaaaa" ] lines

let text_that_fits_stays_one_line () =
  Alcotest.(check (list string)) "one row" [ "hello" ]
    (Par_code_screen.wrap_text ~cols:40 "hello")

(* v0.15.5: rows break between words, not inside one. *)
let words_wrap_at_boundaries () =
  Alcotest.(check (list string)) "word rows"
    [ "hello world"; "foo bar" ]
    (Par_code_screen.wrap_text ~cols:11 "hello world foo bar")

let long_word_still_hard_splits () =
  Alcotest.(check (list string)) "hard split"
    [ "abcdefghij"; "klmnopqrst"; "uvwxyz" ]
    (Par_code_screen.wrap_text ~cols:10 "abcdefghijklmnopqrstuvwxyz")

(* A wrapped list item keeps its hang, the way a markdown renderer does. *)
let list_continuation_is_indented_under_text () =
  Alcotest.(check (list string)) "ordered hang"
    [ "1. alpha"; "   beta"; "   gamma"; "   delta" ]
    (Par_code_screen.wrap_text ~cols:12 "1. alpha beta gamma delta")

let bullet_continuation_is_indented_under_text () =
  Alcotest.(check (list string)) "bullet hang"
    [ "- one two"; "  three" ]
    (Par_code_screen.wrap_text ~cols:9 "- one two three")

let prose_continuation_has_no_hang () =
  Alcotest.(check (list string)) "plain rows"
    [ "alpha beta"; "gamma" ]
    (Par_code_screen.wrap_text ~cols:10 "alpha beta gamma")

(* A token longer than the remaining row uses that row rather than leaving it
   half empty (CJK runs have no spaces to break on). *)
let long_token_fills_the_current_row () =
  let cjk = String.concat "" (List.init 6 (fun _ -> "模")) in
  Alcotest.(check (list string)) "fills the row"
    [ "ab 模模模"; "模模模" ]
    (Par_code_screen.wrap_text ~cols:10 ("ab " ^ cjk))

(* Chinese typesetting: closing punctuation may not open a row. *)
let punctuation_does_not_open_a_row () =
  Alcotest.(check (list string)) "punctuation stays up"
    [ "模模模"; "模。模" ]
    (Par_code_screen.wrap_text ~cols:8 "模模模模。模")

(* A CJK run that does not fit the remaining space fills it rather than moving
   whole to the next row (Latin words still move whole). *)
let cjk_run_fills_the_remaining_space () =
  Alcotest.(check (list string)) "cjk fills"
    [ "ab 中文内"; "容。" ]
    (Par_code_screen.wrap_text ~cols:12 "ab 中文内容。")

let latin_word_moves_whole () =
  Alcotest.(check (list string)) "word moves"
    [ "ab"; "international" ]
    (Par_code_screen.wrap_text ~cols:13 "ab international")

(* A mixed token that starts in ASCII is a word, not a CJK run: it must not be
   split after its first letter. *)
let ascii_led_token_moves_whole () =
  Alcotest.(check (list string)) "mixed token stays"
    [ "ab"; "x86_64/arm64" ]
    (Par_code_screen.wrap_text ~cols:13 "ab x86_64/arm64")

(* The streaming path hands the row over as several styled runs (the list
   marker, the bold label, the text). Wrapping must keep the space between the
   marker and the label, and hang the continuation under the label. *)
let styled_list_row_keeps_marker_space () =
  let bold = Par_code_ui.style ~bold:true () in
  let rows =
    Par_code_screen.wrap_runs ~cols:40
      [ ("1. ", Par_code_ui.no_style); ("产品定位", bold);
        ("：一个开源的终端 AI 编码 agent", Par_code_ui.no_style) ]
  in
  let row_text r = String.concat "" (List.map fst r) in
  Alcotest.(check (list string)) "marker and hang"
    [ "1. 产品定位：一个开源的终端 AI 编码"; "   agent" ]
    (List.map row_text rows)

(* v0.15.1: the fold arithmetic. Head + hidden + tail must always add up to the
   block size, and a block at or under the threshold is shown whole. *)
let short_block_is_shown_whole () =
  Alcotest.(check (triple int int int)) "eight lines" (8, 0, 0)
    (Par_code_screen.fold_plan 8);
  Alcotest.(check (triple int int int)) "three lines" (3, 0, 0)
    (Par_code_screen.fold_plan 3)

let long_block_keeps_head_and_tail () =
  Alcotest.(check (triple int int int)) "nine lines" (4, 2, 3)
    (Par_code_screen.fold_plan 9);
  Alcotest.(check (triple int int int)) "twenty lines" (4, 13, 3)
    (Par_code_screen.fold_plan 20)

let fold_adds_up () =
  List.iter
    (fun n ->
       let h, hidden, t = Par_code_screen.fold_plan n in
       Alcotest.(check int) (Printf.sprintf "sum for %d" n) n (h + hidden + t))
    [ 9; 10; 17; 40; 200 ]

(* v0.15.4: the tail of a split mouse report must never become typed text. *)
let mouse_tail_is_dropped () =
  let check name expected input =
    Alcotest.(check string) name expected (Par_code_screen.drop_mouse_tail input)
  in
  check "bare sgr body" "" "<35;12;4M";
  check "after text" "abc" "abc<35;12;4M";
  check "with escape" "" "\x1b[<35;12;4M";
  check "bracket prefix" "" "[<35;12;4M";
  check "release marker" "hi" "hi<0;3;1m";
  check "ordinary text" "a1;b2;c3x" "a1;b2;c3x";
  check "plain word" "hello" "hello"

(* v0.15.7: the status bar must not promise Esc interrupts while a modal owns
   the keyboard. *)
let test_hint_modal () =
  let h =
    Par_code_screen.status_right_hint ~modal_open:true ~busy:"3s"
      ~turn_active:true ~has_input:false ~left_w:10 ~width:80
  in
  Alcotest.(check string) "modal hint" "esc deny \xc2\xb7 ctrl-c cancel " h

let test_hint_running () =
  let h =
    Par_code_screen.status_right_hint ~modal_open:false ~busy:"3s"
      ~turn_active:true ~has_input:false ~left_w:10 ~width:80
  in
  Alcotest.(check string) "running hint" "esc interrupt " h

let test_hint_queue () =
  let h =
    Par_code_screen.status_right_hint ~modal_open:false ~busy:"3s"
      ~turn_active:true ~has_input:true ~left_w:10 ~width:80
  in
  Alcotest.(check string) "queue hint" "enter queue \xc2\xb7 esc interrupt " h

let test_hint_idle () =
  let h =
    Par_code_screen.status_right_hint ~modal_open:false ~busy:""
      ~turn_active:false ~has_input:false ~left_w:10 ~width:80
  in
  Alcotest.(check string) "no hint when idle" "" h

(* v0.15.7: a scrolled-up viewport must stay on the same top line when
   streaming or a resize changes the frame; the bottom keeps following. *)
let test_scroll_anchor () =
  let check name expected =
    Alcotest.(check int) name expected
  in
  check "bottom follows new output" 0
    (Par_code_screen.scroll_after_layout ~scroll:0 ~total:130 ~body:20
       ~prev_total:100 ~prev_body:20);
  check "middle keeps the same top" 15
    (Par_code_screen.scroll_after_layout ~scroll:10 ~total:105 ~body:20
       ~prev_total:100 ~prev_body:20);
  check "top stays at the top" 85
    (Par_code_screen.scroll_after_layout ~scroll:80 ~total:105 ~body:20
       ~prev_total:100 ~prev_body:20);
  check "taller body keeps the same top" 8
    (Par_code_screen.scroll_after_layout ~scroll:10 ~total:100 ~body:22
       ~prev_total:100 ~prev_body:20);
  check "shorter body keeps the same top" 12
    (Par_code_screen.scroll_after_layout ~scroll:10 ~total:100 ~body:18
       ~prev_total:100 ~prev_body:20);
  check "shrinking content clamps at the bottom" 0
    (Par_code_screen.scroll_after_layout ~scroll:10 ~total:90 ~body:20
       ~prev_total:100 ~prev_body:20)

let () =
  Alcotest.run "par_screen"
    [ ( "fold",
        [ Alcotest.test_case "short_block_is_shown_whole" `Quick
            short_block_is_shown_whole
        ; Alcotest.test_case "long_block_keeps_head_and_tail" `Quick
            long_block_keeps_head_and_tail
        ; Alcotest.test_case "fold_adds_up" `Quick fold_adds_up
        ] )
    ; ( "wrap",
        [ Alcotest.test_case "wide_chars_break_at_the_column_limit" `Quick
            wide_chars_break_at_the_column_limit
        ; Alcotest.test_case "ascii_wraps_without_losing_characters" `Quick
            ascii_wraps_without_losing_characters
        ; Alcotest.test_case "text_that_fits_stays_one_line" `Quick
            text_that_fits_stays_one_line
        ; Alcotest.test_case "words_wrap_at_boundaries" `Quick
            words_wrap_at_boundaries
        ; Alcotest.test_case "long_word_still_hard_splits" `Quick
            long_word_still_hard_splits
        ; Alcotest.test_case "list_continuation_is_indented_under_text" `Quick
            list_continuation_is_indented_under_text
        ; Alcotest.test_case "bullet_continuation_is_indented_under_text" `Quick
            bullet_continuation_is_indented_under_text
        ; Alcotest.test_case "prose_continuation_has_no_hang" `Quick
            prose_continuation_has_no_hang
        ; Alcotest.test_case "long_token_fills_the_current_row" `Quick
            long_token_fills_the_current_row
        ; Alcotest.test_case "punctuation_does_not_open_a_row" `Quick
            punctuation_does_not_open_a_row
        ; Alcotest.test_case "cjk_run_fills_the_remaining_space" `Quick
            cjk_run_fills_the_remaining_space
        ; Alcotest.test_case "latin_word_moves_whole" `Quick
            latin_word_moves_whole
        ; Alcotest.test_case "ascii_led_token_moves_whole" `Quick
            ascii_led_token_moves_whole
        ; Alcotest.test_case "styled_list_row_keeps_marker_space" `Quick
            styled_list_row_keeps_marker_space
        ] )
    ; ( "mouse",
        [ Alcotest.test_case "tail_is_dropped" `Quick mouse_tail_is_dropped ] )
    ; ( "status_hint",
        [ Alcotest.test_case "modal" `Quick test_hint_modal
        ; Alcotest.test_case "running" `Quick test_hint_running
        ; Alcotest.test_case "queue" `Quick test_hint_queue
        ; Alcotest.test_case "idle" `Quick test_hint_idle
        ] )
    ; ( "scroll",
        [ Alcotest.test_case "anchor_keeps_top_line" `Quick
            test_scroll_anchor
        ] ) ]
