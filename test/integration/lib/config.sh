#!/usr/bin/env bash
# Shared configuration for par-code integration tests.
# Sourced by harness.sh and every test file.

# Path to the par binary (override for installed binary testing)
PAR_BIN="${PAR_BIN:-_build/default/bin/main.exe}"

# Timeouts (seconds)
PROMPT_TIMEOUT=8
POLL_INTERVAL=0.1
CLI_TIMEOUT=10

# Integration root (parent of lib/)
INTEGRATION_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_ROOT="$(cd "$INTEGRATION_ROOT/../.." && pwd)"

# Dummy config for non-LLM tests (par needs config to start the REPL,
# but CLI subcommands like memory/plan/session don't need a real provider)
write_dummy_config() {
  mkdir -p "$HOME/.par"
  cat > "$HOME/.par/config.json" <<'JSON'
{"provider":"openai","api_key":"test-key-fake-not-real","model":"gpt-4o"}
JSON
}
