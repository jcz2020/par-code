let test_version () =
  Alcotest.(check string) "version is 0.1.0-dev" "0.1.0-dev" Par_code.version

let () =
  Alcotest.run "par-code"
    [ "version", [ Alcotest.test_case "version" `Quick test_version ] ]
