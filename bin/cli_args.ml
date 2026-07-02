let provider_arg =
  let open Cmdliner in
  Arg.(value & opt (some string) None &
    info [ "provider" ] ~docv:"PROVIDER"
      ~doc:"LLM provider: openai|anthropic|ollama|+custom (default: from config)")

let api_key_arg =
  let open Cmdliner in
  Arg.(value & opt (some string) None &
    info [ "api-key" ] ~docv:"KEY"
      ~doc:"API key for LLM provider (overrides config)")

let api_base =
  let open Cmdliner in
  Arg.(value & opt (some string) None &
    info [ "api-base" ] ~docv:"URL"
      ~doc:"Custom API base URL (overrides config)")

let model_name =
  let open Cmdliner in
  Arg.(value & opt (some string) None &
    info [ "model" ] ~docv:"NAME"
      ~doc:"Model name (overrides config)")

let persistence_arg =
  let open Cmdliner in
  Arg.(value & opt (some string) None &
    info [ "persistence" ] ~docv:"BACKEND"
      ~doc:"Storage backend: sqlite (default: sqlite)")

let db_uri =
  let open Cmdliner in
  Arg.(value & opt (some string) None &
    info [ "db-uri" ] ~docv:"URI"
      ~doc:"SQLite database path (default: ~/.par-code/par_code.db)")

let system_prompt_arg =
  let open Cmdliner in
  Arg.(value & opt (some string) None &
    info [ "system-prompt" ] ~docv:"PROMPT"
      ~doc:"Agent system prompt (overrides config)")

let max_iterations =
  let open Cmdliner in
  Arg.(value & opt (some int) None &
    info [ "max-iterations" ] ~docv:"N"
      ~doc:"Max ReAct iterations (overrides config)")

let temperature_arg =
  let open Cmdliner in
  Arg.(value & opt (some float) None &
    info [ "temperature" ] ~docv:"FLOAT"
      ~doc:"Temperature (overrides config)")

let max_tokens_arg =
  let open Cmdliner in
  Arg.(value & opt (some int) None &
    info [ "max-tokens" ] ~docv:"N"
      ~doc:"Max tokens per LLM response")

let top_p_arg =
  let open Cmdliner in
  Arg.(value & opt (some float) None &
    info [ "top-p" ] ~docv:"FLOAT"
      ~doc:"Top-p sampling parameter (0.0-1.0)")

let no_parallel_tools =
  let open Cmdliner in
  Arg.(value & flag &
    info [ "no-parallel-tools" ] ~doc:"Disable parallel tool execution")

let retention_days =
  let open Cmdliner in
  Arg.(value & opt (some float) None &
    info [ "retention-days" ] ~docv:"DAYS"
      ~doc:"Event retention in days, 0=never prune (overrides config)")

let continue_id_opt =
  let open Cmdliner.Arg in
  value & opt (some string) None
  & info ["c"; "continue"] ~docv:"SESSION"
      ~doc:"Resume the conversation with the given session id"

let resume_opt =
  let open Cmdliner.Arg in
  value & flag
  & info ["r"; "resume"] ~doc:"Resume the most recent session"

let question_arg =
  let open Cmdliner in
  Arg.(value & pos_all string [] &
    info [] ~docv:"QUESTION..."
      ~doc:"Question to ask (may contain spaces)")
