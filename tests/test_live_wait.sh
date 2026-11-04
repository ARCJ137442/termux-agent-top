#!/bin/sh
set -eu

# 「按键提前触发刷新」的验收判据。
#
# 背景：原来主循环每帧只读一次键，读不到就 sleep 到下一帧。于是
# **刷新周期和按键延迟是同一个数**：为了省 CPU 把刷新放慢到 5 秒，
# 按键也要等 5 秒才被看见。把超时交给内核（stty min 0 time N +
# 阻塞 dd）之后两者解耦：空闲照旧按 interval 刷新，按键一到 read(2)
# 立刻返回，循环马上渲染。
#
# 这里钉住三件事：
#   1. 毫秒 → stty time 单位（0.1 秒）的换算；
#   2. 等待期间读到的键会被 process_live_input() 消费（不能丢）；
#   3. 真实 pty 下，等待期间的按键确实让等待**提前**返回。
#
# 第 3 条需要 pty（stty 只对终端生效），用 `script` 提供；没有 script
# 时跳过，但前两条仍然必须通过。

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
SCRIPT="$ROOT/agent-top.sh"
work=$(mktemp -d)
script_copy="$work/lib.sh"
trap 'rm -rf "$work"' EXIT

sed '/^if \[ "\$RUN_ONCE" -eq 1 \]; then$/,$d' "$SCRIPT" >"$script_copy"

# ── 1) 毫秒 → stty time 单位 ────────────────────────────────────────────────
# time 的单位是 0.1 秒，向上取整（宁可多等一点也不能早退），并夹在 1..255。
COLUMNS=200 sh -c '
  source_file=$1; set --; . "$source_file"

  check() {
    key_wait_deciseconds "$1"
    if [ "$KEY_WAIT_DS" != "$2" ]; then
      printf "FAIL: key_wait_deciseconds(%s) = %s，应为 %s\n" "$1" "$KEY_WAIT_DS" "$2" >&2
      exit 1
    fi
  }

  check 1 1
  check 99 1
  check 100 1
  check 101 2
  check 1000 10
  check 1500 15
  check 2540 26
  check 25500 255
  check 30000 255
' sh "$script_copy"

# ── 2) 等待期间读到的键必须被消费 ───────────────────────────────────────────
COLUMNS=200 sh -c '
  source_file=$1; set --; . "$source_file"

  # 没有终端：read_live_keypress 会直接返回空，于是这条断言只可能
  # 由 WAIT_KEY 这条路径满足。
  TTY_INPUT_READY=0
  WAIT_KEY=j
  TREE_FOCUS=0
  process_live_input

  if [ "$TREE_FOCUS" -ne 1 ]; then
    echo "FAIL: 等待期间读到的键没有被 process_live_input 处理（j 应让 TREE_FOCUS=1）" >&2
    exit 1
  fi
  if [ -n "$WAIT_KEY" ]; then
    echo "FAIL: WAIT_KEY 用过之后必须清空，否则同一按键会被处理两次" >&2
    exit 1
  fi

  # 超时路径不能留下旧值
  WAIT_KEY=""
  TREE_FOCUS=0
  process_live_input
  if [ "$TREE_FOCUS" -ne 0 ]; then
    echo "FAIL: 没有按键时不应产生输入" >&2
    exit 1
  fi
' sh "$script_copy"

# ── 3) 真实 pty：按键让等待提前返回 ─────────────────────────────────────────
if command -v script >/dev/null 2>&1; then
  cat >"$work/inner.sh" <<'EOF_INNER'
#!/bin/sh
lib=$1
INTERVAL_MS=$2
set --
. "$lib"
TTY_INPUT_READY=1
RESIZE_PENDING=0
KEY_WAIT_SLICE_MS=1000
started=$(now_ms)
sleep_until_refresh 1 0
spent=$(( $(now_ms) - started ))
printf 'RESULT spent=%s key=%s\n' "$spent" "$WAIT_KEY"
EOF_INNER

  # 3a) 5 秒名义间隔，按键在 0.4 秒到达 → 必须远早于 5 秒返回
  out=$({ sleep 0.4; printf 'j'; sleep 2; } |
    script -qec "sh $work/inner.sh $script_copy 5000" /dev/null 2>/dev/null | tr -d '\r')
  line=$(printf '%s\n' "$out" | command grep 'RESULT ' | tail -1)
  spent=$(printf '%s' "$line" | sed -n 's/.*spent=\([0-9]*\).*/\1/p')
  key=$(printf '%s' "$line" | sed -n 's/.*key=\(.*\)$/\1/p')

  if [ -z "$spent" ]; then
    printf 'FAIL: pty 用例没有产出结果（script 不可用或子脚本失败）\n%s\n' "$out" >&2
    exit 1
  fi
  if [ "$key" != "j" ]; then
    printf "FAIL: 等待期间按下的 j 没有被捕获（得到 [%s]）\n" "$key" >&2
    exit 1
  fi
  if [ "$spent" -ge 2000 ]; then
    printf "FAIL: 按键在 0.4s 到达，但等待花了 %sms —— 说明按键没有打断等待\n" "$spent" >&2
    exit 1
  fi

  # 3b) 没有按键 → 必须等满名义间隔，且 WAIT_KEY 为空
  out=$({ sleep 3; } |
    script -qec "sh $work/inner.sh $script_copy 1000" /dev/null 2>/dev/null | tr -d '\r')
  line=$(printf '%s\n' "$out" | command grep 'RESULT ' | tail -1)
  spent=$(printf '%s' "$line" | sed -n 's/.*spent=\([0-9]*\).*/\1/p')
  key=$(printf '%s' "$line" | sed -n 's/.*key=\(.*\)$/\1/p')

  if [ -z "$spent" ]; then
    echo "FAIL: pty 超时用例没有产出结果" >&2
    exit 1
  fi
  if [ "$spent" -lt 900 ]; then
    printf "FAIL: 没有按键时等待只花了 %sms，短于名义间隔 1000ms\n" "$spent" >&2
    exit 1
  fi
  if [ -n "$key" ]; then
    printf "FAIL: 没有按键时 WAIT_KEY 应为空，得到 [%s]\n" "$key" >&2
    exit 1
  fi
else
  echo "SKIP: 没有 script，跳过 pty 用例（前两条已通过）"
fi

echo "live wait: all assertions passed"
