#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
SCRIPT="$ROOT/agent-top.sh"
fixture_dir=$(mktemp -d)
trap 'rm -rf "$fixture_dir"' EXIT

fixture="$fixture_dir/processes.ps"
cat >"$fixture" <<'EOF_FIXTURE'
100 1 1024 0.0 tmux tmux new-session
101 100 2048 0.0 bash bash -lc claude
102 101 100000 10.0 claude claude
103 102 20000 5.0 node node helper.js
104 103 30000 7.0 sh sh worker
105 100 2048 0.0 bash bash -lc codex
106 105 200000 20.0 node node /data/data/com.termux/files/usr/bin/codex
107 106 50000 3.0 node node scripts/e2e/run-nal-corpus.mjs --engine codex
108 107 60000 4.0 sh sh worker
109 100 10000 0.0 python python unrelated-sibling
110 109 10000 0.0 node node unrelated-descendant
111 1 80000 0.0 claude-exomind claude-exomind
112 111 10000 2.0 node node claude-helper
EOF_FIXTURE

location_map="$fixture_dir/locations.tsv"
cat >"$location_map" <<'EOF_LOCATIONS'
102	exp/stage1-glyph-disambig@termux-tools
106	main@termux-tools
111	main@OpenNARS-304-TS
EOF_LOCATIONS

output=$(
  CODEX_TOP_TEST_MODE=diff \
  CODEX_TOP_TEST_PS_FILE="$fixture" \
  CODEX_TOP_TEST_LOCATION_FILE="$location_map" \
  CODEX_TOP_FORCE_STYLE=1 \
  "$SCRIPT" --once
)

if ! printf '%s\n' "$output" | grep -F 'CLAUDE: 2 agents + 3 child = 5 proc' >/dev/null 2>&1; then
  echo 'FAIL: Claude summary should separate roots and descendants without double counting' >&2
  exit 1
fi

if ! printf '%s\n' "$output" | grep -F 'CODEX: 1 agents + 2 child = 3 proc' >/dev/null 2>&1; then
  echo 'FAIL: Codex summary should separate roots and descendants without double counting' >&2
  exit 1
fi

claude_summary_line=$(printf '%s\n' "$output" | grep -n 'CLAUDE: 2 agents + 3 child = 5 proc' | cut -d: -f1 | head -n 1)
codex_summary_line=$(printf '%s\n' "$output" | grep -n 'CODEX: 1 agents + 2 child = 3 proc' | cut -d: -f1 | head -n 1)
if [ "$codex_summary_line" -ne $((claude_summary_line + 1)) ]; then
  echo 'FAIL: Claude and Codex summaries should each occupy their own line' >&2
  exit 1
fi

if ! printf '%s\n' "$output" | grep -F 'Agents: CPU 51.0%  0.51 cores  Mem 13.1%  537.1 MiB' >/dev/null 2>&1; then
  echo 'FAIL: combined agent summary should include complete-tree CPU and RSS' >&2
  exit 1
fi

if ! printf '%s\n' "$output" | grep -F 'CPU:' | grep -F 'claude' >/dev/null 2>&1; then
  echo 'FAIL: global CPU line should include the Claude composition segment' >&2
  exit 1
fi

if ! printf '%s\n' "$output" | grep -F 'Mem:' | grep -F 'cod' >/dev/null 2>&1; then
  echo 'FAIL: global memory line should include a truncated Codex composition label' >&2
  exit 1
fi

green_ansi=$(printf '\033[92m')
white_ansi=$(printf '\033[97m')
green_background_ansi=$(printf '\033[102m')
reset_ansi=$(printf '\033[0m')
block=$(printf '█')
if ! printf '%s\n' "$output" | awk -v green="$green_ansi" -v white="$white_ansi" -v green_background="$green_background_ansi" -v reset="$reset_ansi" -v block="$block" '
  /^Mem:/ {
    marker = white green_background "|" reset green;
    start = index($0, white green_background "|" reset);
    if (start == 0) exit 1;
    segment = substr($0, start);
    if (substr(segment, 1, length(marker)) != marker) exit 1;
    fill = substr(segment, length(marker) + 1);
    if (substr(fill, 1, length(block)) != block) exit 1;
    reset_at = index(fill, reset);
    if (reset_at <= length(block)) exit 1;
    filled = substr(fill, 1, reset_at - 1);
    if (filled !~ /^█+$/) exit 1;
    found = 1;
  }
  END { exit !found }
'; then
  echo 'FAIL: the other segment must render as a white-on-green | marker followed by green blocks with explicit resets' >&2
  exit 1
fi

if ! printf '%s\n' "$output" | grep -F 'exp/stage1-glyph-disambig@te..' >/dev/null 2>&1; then
  echo 'FAIL: LOCATION should show the longest branch, two directory characters, and the .. truncation marker' >&2
  exit 1
fi

echo 'PASS: resource composition fixture behavior looks correct'
