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

if ! printf '%s\n' "$output" | awk 'length($0) > 116 { exit 1 }'; then
  echo "FAIL: one-shot output should fit within the 116-column panel width" >&2
  exit 1
fi

narrow_output=$(COLUMNS=90 "$SCRIPT" --once)

if ! printf '%s\n' "$narrow_output" | awk 'length($0) > 90 { exit 1 }'; then
  echo "FAIL: one-shot output should adapt to narrow terminal widths" >&2
  exit 1
fi

if ! printf '%s\n' "$narrow_output" | grep -F "COMMAND" >/dev/null 2>&1; then
  echo "FAIL: narrow output should still include the process table header" >&2
  exit 1
fi

for metric_label in "CLAUDE:" "CODEX:"; do
  if ! printf '%s\n' "$narrow_output" | grep -F "$metric_label" >/dev/null 2>&1; then
    echo "FAIL: narrow output should preserve '$metric_label' in the summary area" >&2
    exit 1
  fi
done

for forbidden in "codex-top.sh"; do
  if printf '%s\n' "$output" | grep -F "$forbidden" >/dev/null 2>&1; then
    echo "FAIL: monitor should hide its own helper subtree ('$forbidden')" >&2
    exit 1
  fi
done

live_output_file=$(mktemp)
trap 'rm -f "$live_output_file"' EXIT INT TERM

set +e
timeout 1 sh "$SCRIPT" --interval 10 >"$live_output_file" 2>&1
live_status=$?
set -e

if [ "$live_status" -ne 0 ] && [ "$live_status" -ne 124 ] && [ "$live_status" -ne 143 ]; then
  echo "FAIL: unexpected live-mode exit status '$live_status'" >&2
  exit 1
fi

live_output=$(cat "$live_output_file")

for ansi_pattern in \
  "$(printf '\033[?1049h')" \
  "$(printf '\033[?25l')" \
  "$(printf '\033[H')" \
  "$(printf '\033[J')" \
  "$(printf '\033[?25h')" \
  "$(printf '\033[?1049l')"
do
  if ! printf '%s' "$live_output" | grep -F "$ansi_pattern" >/dev/null 2>&1; then
    echo "FAIL: missing live-mode ANSI sequence" >&2
    exit 1
  fi
done

if printf '%s' "$live_output" | grep -F "$(printf '\033[2J')" >/dev/null 2>&1; then
  echo "FAIL: live mode should avoid full-screen clear" >&2
  exit 1
fi

diff_output=$(
  CODEX_TOP_TEST_MODE=diff \
  CODEX_TOP_TEST_CYCLES=2 \
  sh "$SCRIPT" --interval 1
)

title_count=$(printf '%s' "$diff_output" | awk '
  BEGIN { count = 0 }
  {
    count += gsub(/TERMUX SYSTEM SNAPSHOT/, "&")
  }
  END { print count }
')

if [ "$title_count" -ne 1 ]; then
  echo "FAIL: diff mode should avoid redrawing unchanged title lines" >&2
  exit 1
fi

if ! printf '%s' "$diff_output" | grep -F "$(printf '\033[5;1H')" >/dev/null 2>&1; then
  echo "FAIL: diff mode should reposition cursor to the changed row" >&2
  exit 1
fi

echo "PASS: codex-top snapshot and live refresh behavior look correct"
