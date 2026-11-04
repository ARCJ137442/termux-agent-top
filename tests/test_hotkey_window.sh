#!/bin/sh
set -eu

# k 双击确认的窗口：验收判据。
#
# 背景（2026-11-04 实测）：按键每帧只读一次，所以「第二下 k」与「第一下」
# 的最小间隔就是一个帧周期。原来的窗口写死成 5 秒、按整秒判定，于是
# --interval 5（实测帧周期 5.23–5.64 s）下第二次 k 经常落在窗口外：
# 不杀、重新武装、提示文案与上一帧一字不差 —— diff 渲染下屏幕上
# 一个字节都不会变化，用户完全看不出发生过什么。14 次双击里 7 次静默过期。
#
# 这里断言的是**硬约束**，不是口味：
#   1. 窗口必须严格大于一个帧周期（否则设计上做不到）；
#   2. 窗口仍然有界（确认手势得是手势，不能变成「很久以后随手一按就杀」）；
#   3. 武装时真的用了这个策略（而不是某个写死的常数）；
#   4. 端到端：--interval 5 下，一帧之后按下的第二下 k 必须真的执行 kill。
#
# 第 1/2 条对任何合理的策略都成立（固定秒数、跟随帧周期、几乎不失效都行）。
# 如果你选择改掉 armed_window_seconds() 的接口（例如改成按帧计），
# 这个文件需要一起改 —— 那是允许的，只要上面四条仍然被断言覆盖。

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
SCRIPT="$ROOT/agent-top.sh"
work=$(mktemp -d)
script_copy="$work/lib.sh"
kill_log="$work/kills.log"
trap 'rm -rf "$work"' EXIT

sed '/^if \[ "\$RUN_ONCE" -eq 1 \]; then$/,$d' "$SCRIPT" >"$script_copy"

# ── 1)+2) 策略不变量 ────────────────────────────────────────────────────────
for interval in 1 2 3 4 5 6 10 30; do
  COLUMNS=200 sh -c '
    source_file=$1; interval=$2; set --; . "$source_file"
    INTERVAL_SECONDS=$interval
    window=$(armed_window_seconds)

    case "$window" in
      ""|*[!0-9]*)
        printf "FAIL: armed_window_seconds 必须返回一个非负整数秒（得到 %s）\n" "$window" >&2
        exit 1
        ;;
    esac

    if [ "$window" -le "$interval" ]; then
      printf "FAIL: --interval %s 的窗口只有 %s 秒，不长于一个帧周期 —— 第二次 k 必然过期\n" \
        "$interval" "$window" >&2
      exit 1
    fi

    if [ "$window" -gt 60 ]; then
      printf "FAIL: --interval %s 的窗口是 %s 秒，双臂确认已经不成其为手势了\n" \
        "$interval" "$window" >&2
      exit 1
    fi
  ' sh "$script_copy" "$interval"
done

# ── 3) 武装时真的用了策略 ───────────────────────────────────────────────────
COLUMNS=200 sh -c '
  source_file=$1; set --; . "$source_file"
  INTERVAL_SECONDS=5
  TEST_MODE=hotkey_kill

  perform_hotkey_kill >/dev/null

  [ -n "$ARMED_PID" ] || { echo "FAIL: 第一次 k 必须完成武装" >&2; exit 1; }

  expected=$(armed_window_seconds)
  actual=$((ARMED_UNTIL - ARMED_AT))
  if [ "$actual" != "$expected" ]; then
    printf "FAIL: 武装用的窗口是 %s 秒，策略给出的是 %s 秒 —— 说明窗口没走 armed_window_seconds()\n" \
      "$actual" "$expected" >&2
    exit 1
  fi
' sh "$script_copy"

# ── 4) 端到端：一帧之后的第二下 k 必须真的杀掉 ──────────────────────────────
# 用假 date 把时间钉住：interval 5 的实测帧周期是 5.23–5.64 s，
# 这里让第二下按键落在第 6 秒（保守取值），正好复现原来的过期窗口 5→6 s。
real_date=$(command -v date)
fake_bin="$work/bin"
mkdir -p "$fake_bin"
cat >"$fake_bin/date" <<EOF
#!/bin/sh
# 只接管 +%s，其余原样转给真实 date。
if [ "\$1" = "+%s" ]; then
  printf '%s\n' "\${FAKE_EPOCH:?FAKE_EPOCH not set}"
  exit 0
fi
exec "$real_date" "\$@"
EOF
chmod +x "$fake_bin/date"

: >"$kill_log"
PATH="$fake_bin:$PATH" COLUMNS=200 sh -c '
  source_file=$1; kill_log=$2; set --; . "$source_file"
  INTERVAL_SECONDS=5
  TEST_MODE=hotkey_kill
  TEST_KILL_LOG=$kill_log

  FAKE_EPOCH=1000; export FAKE_EPOCH
  perform_hotkey_kill >/dev/null

  FAKE_EPOCH=1006; export FAKE_EPOCH
  perform_hotkey_kill >/dev/null

  case "$STATUS_MESSAGE" in
    KILLED*) exit 0 ;;
  esac
  printf "FAIL: --interval 5 下，一帧之后的第二下 k 没有执行 kill（状态：%s）\n" \
    "$STATUS_MESSAGE" >&2
  exit 1
' sh "$script_copy" "$kill_log"

if ! command grep -q '^-9 4002$' "$kill_log"; then
  echo "FAIL: 第二下 k 没有留下 kill 记录" >&2
  cat "$kill_log" >&2 || :
  exit 1
fi

echo "hotkey window: all assertions passed"
