#!/bin/sh
set -eu

# 视图开关（f 折叠 / c 短命令）与渐进披露的帮助行。
#
# 这两组行为都是「纯状态」：开关本身只有 0/1，帮助行只有亮/灭。
# 正因如此它们更容易被后续改动悄悄弄坏（比如忘了把新状态传进渲染的 awk），
# 所以这里既断言状态翻转，也断言**渲染结果真的跟着变**。

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
SCRIPT="$ROOT/agent-top.sh"
script_copy=$(mktemp)
fixture=$(mktemp)
trap 'rm -f "$script_copy" "$fixture"' EXIT

cat >"$fixture" <<'EOF_FIXTURE'
3001 1 65536 12.5 claude claude --output-format stream-json
3002 3001 1024 0.5 node node /data/data/com.termux/files/home/proj/build.js --watch
3003 3002 512 0.2 sh /bin/sh -c npm run build
3004 3003 256 0.1 gcc gcc -c main.c
EOF_FIXTURE

sed '/^if \[ "\$RUN_ONCE" -eq 1 \]; then$/,$d' "$SCRIPT" >"$script_copy"

# ── 1) 开关状态与按键 ────────────────────────────────────────────────────
COLUMNS=200 AGENT_TOP_ROOTS=claude sh -c '
  source_file=$1; fixture=$2; set --; . "$source_file"
  [ "$TREE_FOLD" -eq 0 ] || { echo "FAIL: fold must default to off" >&2; exit 1; }
  [ "$COMMAND_SHORT" -eq 0 ] || { echo "FAIL: short command must default to off" >&2; exit 1; }

  handle_live_keypress f
  [ "$TREE_FOLD" -eq 1 ] || { echo "FAIL: f must turn folding on" >&2; exit 1; }
  case "$STATUS_MESSAGE" in *"FOLD ON"*) : ;; *) echo "FAIL: f must announce the fold mode" >&2; exit 1;; esac
  handle_live_keypress f
  [ "$TREE_FOLD" -eq 0 ] || { echo "FAIL: a second f must turn folding back off" >&2; exit 1; }

  handle_live_keypress c
  [ "$COMMAND_SHORT" -eq 1 ] || { echo "FAIL: c must switch to short commands" >&2; exit 1; }
  case "$STATUS_MESSAGE" in *"CMD SHORT"*) : ;; *) echo "FAIL: c must announce the command mode" >&2; exit 1;; esac
  handle_live_keypress c
  [ "$COMMAND_SHORT" -eq 0 ] || { echo "FAIL: a second c must restore full commands" >&2; exit 1; }
' sh "$script_copy" "$fixture"

# 环境变量是外部输入，只认 0/1，不能把 "yes" 之类带进算术比较
COLUMNS=200 AGENT_TOP_ROOTS=claude AGENT_TOP_FOLD=yes AGENT_TOP_CMD= AGENT_TOP_TEST_PS_FILE="$fixture" \
  "$SCRIPT" --once >/dev/null || { echo 'FAIL: a malformed AGENT_TOP_FOLD must not crash the script' >&2; exit 1; }

# ── 2) 折叠真的少画行 ────────────────────────────────────────────────────
full_tree=$(COLUMNS=200 AGENT_TOP_ROOTS=claude CODEX_TOP_TEST_PS_FILE="$fixture" "$SCRIPT" --once)
folded_tree=$(COLUMNS=200 AGENT_TOP_ROOTS=claude AGENT_TOP_FOLD=1 CODEX_TOP_TEST_PS_FILE="$fixture" "$SCRIPT" --once)

printf '%s\n' "$full_tree" | grep -E '^3004 ' >/dev/null ||
  { echo 'FAIL: the full tree must show the deepest descendant' >&2; exit 1; }
if printf '%s\n' "$folded_tree" | grep -E '^3004 ' >/dev/null; then
  echo 'FAIL: folded mode must hide descendants deeper than one level' >&2
  exit 1
fi
printf '%s\n' "$folded_tree" | grep -E '^3002 ' >/dev/null ||
  { echo 'FAIL: folded mode must keep the direct children' >&2; exit 1; }
printf '%s\n' "$folded_tree" | grep -F 'CLAUDE: 1 agents + 3 child = 4 proc' >/dev/null ||
  { echo 'FAIL: folding must only affect the tree, not the summary counts' >&2; exit 1; }

# ── 3) 短命令只留可执行名 ────────────────────────────────────────────────
short_tree=$(COLUMNS=200 AGENT_TOP_ROOTS=claude AGENT_TOP_CMD=1 CODEX_TOP_TEST_PS_FILE="$fixture" "$SCRIPT" --once)

if printf '%s\n' "$short_tree" | grep -F 'build.js' >/dev/null; then
  echo 'FAIL: short command mode must not print the arguments' >&2
  exit 1
fi
printf '%s\n' "$short_tree" | grep -E '^3002 .*\|- node *$' >/dev/null ||
  { echo 'FAIL: short command mode should show the executable basename' >&2; exit 1; }
printf '%s\n' "$short_tree" | grep -E '^3001 .*\bclaude *$' >/dev/null ||
  { echo 'FAIL: an agent row should show its own program name in short mode' >&2; exit 1; }
# 全量模式保留参数；路径会被 compact_home_path 缩成 ~/proj/...
printf '%s\n' "$full_tree" | grep -F '~/proj/build.js --watch' >/dev/null ||
  { echo 'FAIL: full command mode must keep the arguments' >&2; exit 1; }

# ── 4) 帮助行渐进披露 ────────────────────────────────────────────────────
COLUMNS=200 AGENT_TOP_ROOTS=claude sh -c '
  source_file=$1; set --; . "$source_file"

  # 默认：没有操作，帮助行不占位
  [ -z "$(live_help_text)" ] || { echo "FAIL: the help line must stay hidden until asked for" >&2; exit 1; }

  # 按键后：亮起来，并且真的列出按键表
  handle_live_keypress j
  [ "$HELP_TTL" -gt 0 ] || { echo "FAIL: a keypress must reveal the help line" >&2; exit 1; }
  case "$(live_help_text)" in
    *"f fold"*"c cmd"*) : ;;
    *) echo "FAIL: the revealed help line must list the view toggles" >&2; exit 1 ;;
  esac

  # 若干帧之后自己淡出
  i=0
  while [ "$i" -lt "$HELP_TTL_FRAMES" ]; do tick_help_message; i=$((i + 1)); done
  [ "$HELP_TTL" -eq 0 ] || { echo "FAIL: the help line must fade out on its own" >&2; exit 1; }

  # 但视图开关的状态是常驻的：模式开着就必须一直看得见
  TREE_FOLD=1
  COMMAND_SHORT=1
  [ "$(live_help_text)" = "[F][C] " ] ||
    { echo "FAIL: the active view modes must stay visible after the help fades" >&2; exit 1; }
' sh "$script_copy"

# ── 5) 帧节拍按实际耗时补偿 ──────────────────────────────────────────────
COLUMNS=200 AGENT_TOP_ROOTS=claude sh -c '
  source_file=$1; set --; . "$source_file"
  INTERVAL_MS=1000

  # 渲染已经超过名义间隔：不再补睡，立刻进入下一帧
  started=$(now_ms)
  sleep_until_refresh 1 1500
  spent=$(( $(now_ms) - started ))
  [ "$spent" -lt 400 ] || { echo "FAIL: an over-budget frame must not sleep again (spent ${spent}ms)" >&2; exit 1; }

  # 渲染花了 900ms：只补剩下的 100ms，而不是再睡满 1s
  started=$(now_ms)
  sleep_until_refresh 1 900
  spent=$(( $(now_ms) - started ))
  [ "$spent" -lt 700 ] || { echo "FAIL: the sleep must compensate for render time (spent ${spent}ms)" >&2; exit 1; }

  # 完全没渲染耗时：这一帧仍然要等满一个间隔
  started=$(now_ms)
  sleep_until_refresh 0.3 0
  spent=$(( $(now_ms) - started ))
  [ "$spent" -ge 200 ] || { echo "FAIL: a zero-cost frame must still honour the interval (spent ${spent}ms)" >&2; exit 1; }
' sh "$script_copy"

echo 'PASS: view toggles, progressive help disclosure and frame pacing behave as specified'
