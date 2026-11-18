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
        ] ) ]
