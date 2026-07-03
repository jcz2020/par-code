let test_version () =
  Alcotest.(check string) "version is 0.2.1" "0.2.1" Par_code_version.version

let test_version_info_prefix () =
  Alcotest.(check bool) "version_info starts with 'par '"
    true (Astring.String.is_prefix ~affix:"par " Par_code_version.version_info)

let test_config_paths () =
  let path = Par_code_config.config_path () in
  let dir = Par_code_config.config_dir () in
  let db = Par_code_config.db_path () in
  Alcotest.(check bool) "config dir is ~/.par"
    true (Astring.String.is_infix ~affix:".par" dir);
  Alcotest.(check bool) "config path ends with .par/config.json"
    true (Astring.String.is_infix ~affix:".par/config.json" path);
  Alcotest.(check bool) "db path ends with par.db"
    true (Astring.String.is_suffix ~affix:"par.db" db);
  Alcotest.(check bool) "config dir is not the old ~/.par-code"
    false (Astring.String.is_infix ~affix:".par-code" dir)

let test_agent_id () =
  Alcotest.(check string) "agent_id is par" "par" Par_code_setup.agent_id

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
  Alcotest.run "par"
    [ "version", [ Alcotest.test_case "version" `Quick test_version;
                   Alcotest.test_case "version_info prefix" `Quick test_version_info_prefix ];
      "identity", [ Alcotest.test_case "agent_id" `Quick test_agent_id ];
      "config", [ Alcotest.test_case "paths are ~/.par" `Quick test_config_paths;
                  Alcotest.test_case "JSON round-trip" `Quick test_config_roundtrip ] ]
