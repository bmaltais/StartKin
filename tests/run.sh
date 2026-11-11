#!/usr/bin/env bash
# Test runner. Plain bash, no bats (it is not installed on every Omarchy box; see docs/engine.md).
# Runs every tests/test_*.sh in its own bash process; each defines functions named test_* and calls run_tests.
#   tests/run.sh [FILE...]
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

files=("$@")
((${#files[@]})) || files=(tests/test_*.sh)
bad=0
for f in "${files[@]}"; do
  printf '%s\n' "$f"
  bash "$f" || bad=1
done
if ((bad)); then echo "tests: FAILED" >&2; exit 1; fi
echo "tests: ok"
