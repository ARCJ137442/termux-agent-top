#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
SCRIPT="$ROOT/agent-top.sh"
fixture=$(mktemp)
trap 'rm -f "$fixture"' EXIT
cat >"$fixture" <<'EOF_FIXTURE'
100 1 2048 0.5 tmux tmux new-session
101 100 4096 0.0 bash bash -lc claude
102 101 8192 1.0 ld-linux-aarch6 ld-linux-aarch6 @anthropic-ai/claude-code/bin/claude
103 102 1024 2.0 bun bun-termux claude-code
200 1 4096 0.5 codex-exomind codex-exomind
201 200 1024 2.0 node node scripts/e2e/run-nal-corpus.mjs --engine codex
202 1 4096 0.5 node node /data/data/com.termux/files/usr/bin/codex
203 202 1024 2.0 node node scripts/e2e/codex-child.mjs
EOF_FIXTURE

output=$(CODEX_TOP_TEST_PS_FILE="$fixture" "$SCRIPT" --once)

printf '%s\n' "$output" | grep -F 'CLAUDE: 1 proc' >/dev/null
printf '%s\n' "$output" | grep -F 'CODEX: 2 proc' >/dev/null
printf '%s\n' "$output" | grep -F 'CLAUDE' >/dev/null
printf '%s\n' "$output" | grep -F 'CODEX ' >/dev/null
if printf '%s\n' "$output" | grep -F 'CODEX-EXOMIND' >/dev/null; then
  echo 'FAIL: wrapper-specific Codex role leaked into display' >&2
  exit 1
fi
if printf '%s\n' "$output" | grep -F 'CODEX                          |- node' >/dev/null; then
  echo 'FAIL: Codex descendant was promoted to CODEX' >&2
  exit 1
fi
printf '%s\n' "$output" | grep -F 'CPU:' >/dev/null

echo 'PASS: agent identity fixture behavior looks correct'
