let test_version () =
  Alcotest.(check string) "version is 0.2.0-dev" "0.2.0-dev" Par_code.version

let test_config_paths_independent_from_par () =
  let path = Par_code_config.config_path () in
  let dir = Par_code_config.config_dir () in
  Alcotest.(check bool) "config dir is ~/.par-code (not ~/.par)"
    true (Astring.String.is_infix ~affix:".par-code" dir);
  Alcotest.(check bool) "config path ends with .par-code/config.json"
    true (Astring.String.is_infix ~affix:".par-code/config.json" path);
  Alcotest.(check bool) "config dir does not collide with ~/.par"
    false (Astring.String.is_infix ~affix:".par/config" dir)

let test_config_roundtrip () =
  let cfg : Par_code_config.config =
    { Par_code_config.default with
      provider = "ollama";
      api_key = "sk-test-123";
      api_base = Some "http://localhost:11434/v1";
      model = "llama3";
      temperature = 0.5;
      max_iterations = 25; }
  in
  let json = Par_code_config.to_json cfg in
  match Par_code_config.of_json json with
  | Error e -> Alcotest.fail e
  | Ok cfg' ->
    Alcotest.(check string) "provider roundtrip" cfg.provider cfg'.provider;
    Alcotest.(check string) "api_key roundtrip" cfg.api_key cfg'.api_key;
    Alcotest.(check string) "model roundtrip" cfg.model cfg'.model;
    Alcotest.(check (float 0.01)) "temperature roundtrip" cfg.temperature cfg'.temperature;
    Alcotest.(check int) "max_iterations roundtrip" cfg.max_iterations cfg'.max_iterations;
    Alcotest.(check (option string)) "api_base roundtrip" cfg.api_base cfg'.api_base

let () =
  Alcotest.run "par-code"
    [ "version", [ Alcotest.test_case "version" `Quick test_version ];
      "config", [ Alcotest.test_case "paths independent from ~/.par" `Quick test_config_paths_independent_from_par;
                  Alcotest.test_case "JSON round-trip" `Quick test_config_roundtrip ] ]