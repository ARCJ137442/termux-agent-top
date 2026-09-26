#!/usr/bin/env sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
SCRIPT="$ROOT/agent-top.sh"
fixture=$(mktemp); library=$(mktemp); top=$(mktemp); bottom=$(mktemp)
trap 'rm -f "$fixture" "$library" "$top" "$bottom"' EXIT
cat >"$fixture" <<'EOF_FIXTURE'
3001 1 65536 1.0 claude claude
EOF_FIXTURE
i=1
while [ "$i" -le 24 ]; do
  pid=$((3001 + i)); parent=$((pid - 1))
  printf '%s %s 1024 0.1 node claude-descendant-%02d\n' "$pid" "$parent" "$i" >>"$fixture"
  i=$((i + 1))
done
sed '/^if \[ "\$RUN_ONCE" -eq 1 \]; then$/,$d' "$SCRIPT" >"$library"
CODEX_TOP_TEST_PS_FILE="$fixture" AGENT_TOP_ROOTS=claude LINES=18 COLUMNS=120 \
sh -c '
  library=$1; top=$2; bottom=$3; fixture=$4; set --; . "$library"
  PANEL_HEIGHT=18; PANEL_WIDTH=120; configure_layout
  frame=$(run_once)
  TREE_FOCUS=0; clip_frame_to_terminal_height "$frame" >"$top"
  TREE_FOCUS=999999; clip_frame_to_terminal_height "$frame" >"$bottom"
  TREE_FOCUS=0; handle_live_keypress j; test "$TREE_FOCUS" -eq 1
  handle_live_keypress u; test "$TREE_FOCUS" -eq 0
  handle_live_keypress G; test "$TREE_FOCUS" -eq 999999
  handle_live_keypress g; test "$TREE_FOCUS" -eq 0
' sh "$library" "$top" "$bottom" "$fixture"
grep -E '^PID[[:space:]]+PPID' "$top" >/dev/null
grep -F 'CLAUDE: 1 agents + 24 child = 25 proc' "$top" >/dev/null
grep -F 'claude-descendant-01' "$top" >/dev/null
if grep -F 'claude-descendant-24' "$top" >/dev/null; then echo 'FAIL: top focus shows last descendant' >&2; exit 1; fi
grep -E '^PID[[:space:]]+PPID' "$bottom" >/dev/null
grep -F 'CLAUDE: 1 agents + 24 child = 25 proc' "$bottom" >/dev/null
grep -E '^3025[[:space:]]' "$bottom" >/dev/null
echo 'PASS: live navigation keeps summary/header and reaches descendant tail'
