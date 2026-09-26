#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
SCRIPT="$ROOT/agent-top.sh"
fixture=$(mktemp)
log=$(mktemp)
trap 'rm -f "$fixture" "$log"' EXIT
cat >"$fixture" <<'EOF_FIXTURE'
100 1 2048 0.5 tmux tmux new-session
101 100 4096 0.0 bash bash -lc claude
102 101 8192 1.0 /data/data/com. /data/data/com.termux/files/usr/bin/bash /data/data/com.termux/files/usr/bin/claude-exomind
103 102 1024 2.0 bun bun-termux claude-code
200 100 4096 0.5 node node /data/data/com.termux/files/usr/bin/codex
201 200 1024 2.0 node node scripts/e2e/run-nal-corpus.mjs --engine codex
EOF_FIXTURE

output=$(CODEX_TOP_TEST_PS_FILE="$fixture" CODEX_TOP_TEST_PS_LOG="$log" "$SCRIPT" --once)

if [ "$(wc -l <"$log" | awk '{print $1}')" -ne 1 ]; then
  echo 'FAIL: one frame should collect one full process snapshot' >&2
  exit 1
fi
printf '%s\n' "$output" | grep -F 'CLAUDE: 1 agents + 1 child = 2 proc' >/dev/null
printf '%s\n' "$output" | grep -F 'CODEX: 1 agents + 1 child = 2 proc' >/dev/null
printf '%s\n' "$output" | grep -F 'CLAUDE' >/dev/null
if printf '%s\n' "$output" | grep -F 'CODEX                          |- node' >/dev/null; then
  echo 'FAIL: Codex child was promoted to an Agent' >&2
  exit 1
fi

echo 'PASS: shared process snapshot behavior looks correct'
