#!/usr/bin/env bash
set -euo pipefail

# Run all integration tests, report pass/fail tally, exit non-zero on any failure.
cd "$(dirname "$0")/../.."

_test_files=()
while IFS= read -r f; do
  _test_files+=("$f")
done < <(find test/integration/cli test/integration/repl -name '*_test.sh' 2>/dev/null | sort)

if [ ${#_test_files[@]} -eq 0 ]; then
  echo "No integration test files found."
  exit 0
fi

echo "Running ${#_test_files[@]} integration test file(s)..."
echo ""

_passed=0 _failed=0

for f in "${_test_files[@]}"; do
  echo "[$(basename "$f")]"
  if bash "$f" 2>&1; then
    _passed=$((_passed + 1))
  else
    _failed=$((_failed + 1))
  fi
  echo ""
done

echo "================================"
echo "Files: $_passed passed, $_failed failed"
[ "$_failed" -eq 0 ]
