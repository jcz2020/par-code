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

let () =
  Alcotest.run "par_screen"
    [ ( "wrap",
        [ Alcotest.test_case "wide_chars_break_at_the_column_limit" `Quick
            wide_chars_break_at_the_column_limit
        ; Alcotest.test_case "ascii_wraps_without_losing_characters" `Quick
            ascii_wraps_without_losing_characters
        ; Alcotest.test_case "text_that_fits_stays_one_line" `Quick
            text_that_fits_stays_one_line
        ] ) ]
