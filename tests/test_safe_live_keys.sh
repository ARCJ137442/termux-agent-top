#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
script_copy=$(mktemp)
kill_log=$(mktemp)
trap 'rm -f "$script_copy" "$kill_log"' EXIT
sed '/^if \[ "\$RUN_ONCE" -eq 1 \]; then$/,$d' "$ROOT/agent-top.sh" >"$script_copy"
CODEX_TOP_TEST_MODE=hotkey_kill CODEX_TOP_TEST_KILL_LOG="$kill_log" sh -c '
  source_file=$1; kill_file=$2; set --; . "$source_file"
  handle_live_keypress k
  [ ! -s "$kill_file" ] || { echo "FAIL: first k killed without confirmation" >&2; exit 1; }
  case "$STATUS_MESSAGE" in *"ARMED"*|*"press k again"*) : ;; *) echo "FAIL: missing armed status" >&2; exit 1;; esac
  handle_live_keypress k
  grep -F -- "-9 4002" "$kill_file" >/dev/null || { echo "FAIL: second k did not kill armed child" >&2; exit 1; }
' sh "$script_copy" "$kill_log"

: >"$kill_log"
CODEX_TOP_TEST_MODE=hotkey_kill_fail CODEX_TOP_TEST_KILL_LOG="$kill_log" sh -c '
  source_file=$1; kill_file=$2; set --; . "$source_file"
  handle_live_keypress k
  handle_live_keypress k
  case "$STATUS_MESSAGE" in *"KILL FAILED rustc[4002]"*) : ;; *) echo "FAIL: failed confirmation status" >&2; exit 1;; esac
  grep -F -- "-9 4002" "$kill_file" >/dev/null
  : >"$kill_file"
  handle_live_keypress k
  ARMED_UNTIL=0
  handle_live_keypress k
  [ ! -s "$kill_file" ] || { echo "FAIL: expired arm killed child" >&2; exit 1; }
' sh "$script_copy" "$kill_log"

: >"$kill_log"
CODEX_TOP_TEST_MODE=hotkey_kill_all CODEX_TOP_TEST_KILL_LOG="$kill_log" sh -c '
  source_file=$1; kill_file=$2; set --; . "$source_file"
  handle_live_keypress "$(printf "\013")"
  grep -F -- "-9 4002" "$kill_file" >/dev/null
  grep -F -- "-9 4003" "$kill_file" >/dev/null
  ! grep -F -- "-9 3001" "$kill_file" >/dev/null
' sh "$script_copy" "$kill_log"

echo 'PASS: safe kill confirmation and bulk protection'
