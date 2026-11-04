#!/bin/sh
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

# 带样式时同样的两件事必须成立。
#
# 这是一个真实回归过的 bug：找表头的探针写成 /^PID[[:space:]]+PPID/，
# 而带样式时表头前面挂着 ESC[7m —— 正则永远不匹配，于是 header=0，
# 裁剪函数走「只打印前 N 行」的兜底分支，TREE_FOCUS 也被夹成 0，
# j/u/g/G 全部失效（实时模式总是带样式，所以用户看到的是滚动彻底不工作）。
# 断言必须跑在 STYLE_ENABLED=1 下，否则这条路径根本没被执行。
styled_top=$(mktemp); styled_bottom=$(mktemp)
trap 'rm -f "$fixture" "$library" "$top" "$bottom" "$styled_top" "$styled_bottom"' EXIT
CODEX_TOP_FORCE_STYLE=1 CODEX_TOP_TEST_PS_FILE="$fixture" AGENT_TOP_ROOTS=claude LINES=18 COLUMNS=120 \
sh -c '
  library=$1; top=$2; bottom=$3; set --; . "$library"
  PANEL_HEIGHT=18; PANEL_WIDTH=120; configure_layout
  [ "$STYLE_ENABLED" -eq 1 ] || { echo "FAIL: this case must run with styling on" >&2; exit 1; }
  frame=$(run_once)
  TREE_FOCUS=0; clip_frame_to_terminal_height "$frame" >"$top"
  TREE_FOCUS=999999; clamp_tree_focus "$frame"
  [ "$TREE_FOCUS" -gt 0 ] || { echo "FAIL: tree focus must not be clamped to 0 when styled" >&2; exit 1; }
  clip_frame_to_terminal_height "$frame" >"$bottom"
' sh "$library" "$styled_top" "$styled_bottom"
# 带样式时表头前面挂着反显码，所以这里刻意不加行首锚点：
# 「能不能找到表头」正是被带样式的 escape 前缀破坏掉的东西。
grep -F 'PID    PPID' "$styled_top" >/dev/null ||
  { echo 'FAIL: a styled frame must still expose the tree header' >&2; exit 1; }
grep -F 'claude-descendant-01' "$styled_top" >/dev/null
# 滚到底时最后一行是焦点行，前面带着反显高亮码（ESC[7m）—— 所以这里显式带上
# 那个前缀来断言，而不是用 ^3025：那一行本来就不在行首。
# （也不按命令名断言：链到第 24 层时缩进把命令名挤出了 COMMAND 列，只剩 "..."）
grep -F "$(printf '\033[7m')3025 " "$styled_bottom" >/dev/null ||
  { echo 'FAIL: a styled frame must be able to scroll to the descendant tail' >&2; exit 1; }

echo 'PASS: live navigation keeps summary/header and reaches descendant tail (plain and styled)'
