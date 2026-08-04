open Par_code_session

let test_format_age_seconds () =
  let now = Unix.gettimeofday () in
  Alcotest.(check string) "30 seconds" "30s ago" (format_age (now -. 30.0))

let test_format_age_minutes () =
  let now = Unix.gettimeofday () in
  Alcotest.(check string) "5 minutes" "5m ago" (format_age (now -. 300.0))

let test_format_age_hours () =
  let now = Unix.gettimeofday () in
  Alcotest.(check string) "2 hours" "2h ago" (format_age (now -. 7200.0))

let test_format_age_days () =
  let now = Unix.gettimeofday () in
  Alcotest.(check string) "3 days" "3d ago" (format_age (now -. 259200.0))

let test_resolve_id_full_uuid () =
  let full = "abcdef0123456789abcdef0123456789abcdef01" in
  Alcotest.(check (result string string)) "full UUID passes through"
    (Ok full) (resolve_id full)

let test_resolve_id_short_full_uuid () =
  let full_uuid = "12345678-1234-1234-1234-123456789abc" in
  Alcotest.(check (result string string)) "36 char UUID passes through"
    (Ok full_uuid) (resolve_id full_uuid)

let test_resolve_id_no_match () =
  Alcotest.(check (result string string)) "no match"
    (Error "No session matches prefix 'zzzzzznosession'")
    (resolve_id "zzzzzznosession")

let () =
  Alcotest.run "par_session"
    [ "format_age", [
        Alcotest.test_case "seconds"  `Quick test_format_age_seconds;
        Alcotest.test_case "minutes"  `Quick test_format_age_minutes;
        Alcotest.test_case "hours"    `Quick test_format_age_hours;
        Alcotest.test_case "days"     `Quick test_format_age_days;
      ];
      "resolve_id", [
        Alcotest.test_case "full_uuid"       `Quick test_resolve_id_full_uuid;
        Alcotest.test_case "short_full_uuid" `Quick test_resolve_id_short_full_uuid;
        Alcotest.test_case "no_match"        `Quick test_resolve_id_no_match;
      ];
    ]
