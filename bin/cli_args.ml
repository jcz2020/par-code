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
      ~doc:"SQLite database path (default: ~/.par/par.db)")

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

let upgrade_check_arg =
  let open Cmdliner in
  Arg.(value & flag &
    info ["check"] ~doc:"Print current vs latest version; exit 0 if up-to-date, 1 if behind")

let upgrade_to_arg =
  let open Cmdliner in
  Arg.(value & opt (some string) None &
    info ["to"] ~docv:"VERSION" ~doc:"Upgrade/downgrade to a specific version (e.g., v0.2.5)")

let upgrade_uninstall_arg =
  let open Cmdliner in
  Arg.(value & flag &
    info ["uninstall"] ~doc:"Remove the par binary and update cache (preserves config.json and par.db)")

let upgrade_purge_arg =
  let open Cmdliner in
  Arg.(value & flag &
    info ["purge"] ~doc:"Remove ALL of ~/.par/ including config and sessions (implies --uninstall; prompts y/N)")

(* Memory subcommand args *)

let memory_kind_arg =
  let open Cmdliner in
  Arg.(value & opt (some string) None &
    info ["kind"] ~docv:"KIND"
      ~doc:"Memory kind: preference|convention|insight|gotcha|task_map")

let memory_summary_arg =
  let open Cmdliner in
  Arg.(value & opt (some string) None &
    info ["summary"] ~docv:"TEXT"
      ~doc:"One-line summary for the memory index")

let memory_content_arg =
  let open Cmdliner in
  Arg.(value & opt (some string) None &
    info ["content"] ~docv:"TEXT"
      ~doc:"Full memory content text")

let memory_limit_arg =
  let open Cmdliner in
  Arg.(value & opt int 50 &
    info ["limit"; "n"] ~docv:"N"
      ~doc:"Maximum number of results (default: 50)")

let memory_id_arg =
  let open Cmdliner in
  Arg.(required & pos 0 (some int) None &
    info [] ~docv:"ID" ~doc:"Memory entry ID")

let memory_query_arg =
  let open Cmdliner in
  Arg.(required & pos 0 (some string) None &
    info [] ~docv:"QUERY" ~doc:"Full-text search query")

let memory_older_than_arg =
  let open Cmdliner in
  Arg.(value & opt float 90.0 &
    info ["older-than"] ~docv:"DAYS"
      ~doc:"Prune memories unused for more than N days (default: 90)")

let memory_output_arg =
  let open Cmdliner in
  Arg.(value & opt string "stdout" &
    info ["o"; "output"] ~docv:"PATH"
      ~doc:"Output file path (default: stdout)")
