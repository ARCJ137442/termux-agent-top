#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
SCRIPT="$ROOT/agent-top.sh"
fixture_dir=$(mktemp -d)
trap 'rm -rf "$fixture_dir"' EXIT

fixture="$fixture_dir/processes.ps"
cat >"$fixture" <<'EOF_FIXTURE'
100 1 1024 0.0 tmux tmux new-session
101 100 2048 0.0 bash bash -lc codex
102 101 100000 10.0 codex-exomind codex-exomind
103 102 20000 1.0 node node /data/data/com.termux/files/usr/bin/node scripts/e2e/run-nal-corpus.mjs --engine codex
104 103 30000 2.0 sh sh helper
105 100 2048 0.0 bash bash -lc claude
106 105 100000 5.0 ld-linux-aarch64 ld-linux-aarch64 @anthropic-ai/claude-code/bin/claude
107 106 20000 1.0 bun bun claude-code
108 1 100000 1.0 claude-exomind claude-exomind
EOF_FIXTURE

location_map="$fixture_dir/locations.tsv"
cat >"$location_map" <<'EOF_LOCATIONS'
102	exp/stage1-glyph-disambig@termux-tools
106	main@termux-tools
108	main@jev-narsese-long-project-name
EOF_LOCATIONS

output=$(
  CODEX_TOP_TEST_PS_FILE="$fixture" \
  CODEX_TOP_TEST_LOCATION_FILE="$location_map" \
  "$SCRIPT" --once
)

child_line=$(printf '%s\n' "$output" | grep '^103 ')
if printf '%s\n' "$child_line" | grep -F 'CODEX' >/dev/null 2>&1; then
  echo 'FAIL: Codex helper command containing the word codex must remain a child' >&2
  exit 1
fi
if ! printf '%s\n' "$child_line" | grep -F '  child' >/dev/null 2>&1; then
  echo 'FAIL: child ROLE should be indented by two spaces' >&2
  exit 1
fi

if ! printf '%s\n' "$output" | grep -F '~/../usr/bin/node' >/dev/null 2>&1; then
  echo 'FAIL: Termux files paths should use the compact ~/../ prefix' >&2
  exit 1
fi

if ! printf '%s\n' "$output" | grep -F 'main@termux-tools' >/dev/null 2>&1; then
  echo 'FAIL: shorter LOCATION values should remain fully visible within the shared column width' >&2
  exit 1
fi

if ! printf '%s\n' "$output" | grep -F 'main@jev-narsese-long-projec..' >/dev/null 2>&1; then
  echo 'FAIL: shorter branches should use the shared LOCATION width for more folder characters' >&2
  exit 1
fi

if printf '%s\n' "$output" | grep -E '^101 ' >/dev/null 2>&1; then
  echo 'FAIL: tmux context should hide its unrelated wrapper siblings' >&2
  exit 1
fi

if ! printf '%s\n' "$output" | grep -E '^100 .*tmux new-session' >/dev/null 2>&1; then
  echo 'FAIL: tmux should remain as the context root for agent processes' >&2
  exit 1
fi

echo 'PASS: process presentation fixture behavior looks correct'
