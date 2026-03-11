#!/usr/bin/env sh
set -eu

ROOT="/data/data/com.termux/files/home/A137442/termux-tools"
SCRIPT="$ROOT/codex-top.sh"

if [ ! -x "$SCRIPT" ]; then
  echo "FAIL: missing executable script at $SCRIPT" >&2
  exit 1
fi

output=$("$SCRIPT" --once)

for pattern in "TERMUX SYSTEM SNAPSHOT" "CLAUDE" "CODEX" "PID"; do
  if ! printf '%s\n' "$output" | grep -F "$pattern" >/dev/null 2>&1; then
    echo "FAIL: missing pattern '$pattern'" >&2
    exit 1
  fi
done

for forbidden in "codex-top.sh" "test_codex_top.sh"; do
  if printf '%s\n' "$output" | grep -F "$forbidden" >/dev/null 2>&1; then
    echo "FAIL: monitor should hide its own helper subtree ('$forbidden')" >&2
    exit 1
  fi
done

echo "PASS: codex-top one-shot snapshot contains core sections"
