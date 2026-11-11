#!/usr/bin/env bash
# Runs scripts/validate-manifest over schema/examples:
# valid-*.json must pass, invalid-*.json must fail.
set -u
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
v="$root/scripts/validate-manifest"
fail=0 n=0
for f in "$root"/schema/examples/valid-*.json; do
  n=$((n+1))
  if "$v" "$f" >/dev/null 2>&1; then echo "ok   $(basename "$f")"; else echo "FAIL $(basename "$f") should be valid"; fail=1; fi
done
for f in "$root"/schema/examples/invalid-*.json; do
  n=$((n+1))
  "$v" "$f" >/dev/null 2>&1; rc=$?
  # exit 1 = invalid; anything else (0 valid, 2 tooling error) is a failure
  if [ "$rc" -eq 1 ]; then echo "ok   $(basename "$f")"; else echo "FAIL $(basename "$f") should be invalid (exit $rc)"; fail=1; fi
done
# usage errors must not look like success
if "$v" >/dev/null 2>&1; then echo "FAIL no-arg should fail"; fail=1; fi
if "$v" /nonexistent.json >/dev/null 2>&1; then echo "FAIL missing file should fail"; fail=1; fi
echo "$n examples checked"
exit $fail
