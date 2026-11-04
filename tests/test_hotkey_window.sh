#!/bin/sh
set -eu

# k 双击确认的窗口：验收判据。
#
# 窗口是「第二次 k 在多久之内仍算确认」，是整个热键唯一的容错 ↔ 安全旋钮。
# 太短 → 用户按了两下却没杀掉；而且过期后重新武装的提示文案与上一帧一字
# 不差，diff 渲染下屏幕上什么都不会变。太长 → 早先那次武装还活着，用户
# 后来随手一按就杀掉一个早已忘记的目标，SIGKILL 没有兜底。
#
# ── 为什么断言的是「固定窗口」而不是「窗口 > 帧周期」 ────────────────────
# 旧实现每帧只读一次键，所以第二下 k 最快也要等一个帧周期才被看见，那时
# 「窗口 > 帧周期」是硬约束；--interval 5 下窗口 5 秒会静默过期（实测 14 次
# 双击里 7 次）。
#
# 现在按键在等待期间随时被读到（read_live_keypress_wait），两下 k 之间只隔
# 一次渲染，与 --interval 无关。于是窗口跟着帧周期放大从「必要」变成
# 「危险」：--interval 30 会给出 32 秒，用户武装后忘了它，回来随手一按就
# 杀掉一个早就不在意的进程。窗口应该像快捷键的长按时间一样，是个固定的、
# 肌肉记忆尺度的数。
#
# 所以这里钉住：
#   1. 窗口与 --interval 无关（所有间隔下取同一个值）；
#   2. 它仍是个手势尺度（有界，不是「很久以后随手一按也算确认」）；
#   3. 武装时真的用了这个策略；
#   4. 端到端：窗口内第二下 k 必须真的执行 kill；
#   5. 端到端：窗口外第二下 k 必须**不杀**，而是重新武装。

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
SCRIPT="$ROOT/agent-top.sh"
work=$(mktemp -d)
script_copy="$work/lib.sh"
kill_log="$work/kills.log"
trap 'rm -rf "$work"' EXIT

sed '/^if \[ "\$RUN_ONCE" -eq 1 \]; then$/,$d' "$SCRIPT" >"$script_copy"

# ── 1)+2) 策略不变量：与帧周期无关，且仍是手势尺度 ─────────────────────────
COLUMNS=200 sh -c '
  source_file=$1; set --; . "$source_file"

  first=""
  for interval in 0 1 2 3 4 5 6 10 30 60; do
    INTERVAL_SECONDS=$interval
    window=$(armed_window_seconds)

    case "$window" in
      ""|*[!0-9]*)
        printf "FAIL: armed_window_seconds 必须返回一个非负整数秒（--interval %s 得到 %s）\n" \
          "$interval" "$window" >&2
        exit 1
        ;;
    esac

    if [ "$window" -lt 5 ]; then
      printf "FAIL: --interval %s 的窗口只有 %s 秒，容不下一次有意的双击\n" \
        "$interval" "$window" >&2
      exit 1
    fi

    if [ "$window" -gt 10 ]; then
      printf "FAIL: --interval %s 的窗口是 %s 秒，已经不像一次按键手势了\n" \
        "$interval" "$window" >&2
      exit 1
    fi

    if [ -z "$first" ]; then
      first=$window
    elif [ "$window" != "$first" ]; then
      printf "FAIL: 窗口跟着 --interval 变了（%s 秒 vs %s 秒）—— 它只应该跟按键手势有关\n" \
        "$first" "$window" >&2
      exit 1
    fi
  done
' sh "$script_copy"

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

# ── 假的 date：把「现在」钉在 FAKE_EPOCH ────────────────────────────────────
real_date=$(command -v date)
fake_bin="$work/bin"
mkdir -p "$fake_bin"
cat >"$fake_bin/date" <<EOF
#!/bin/sh
if [ "\$1" = "+%s" ]; then
  printf '%s\n' "\${FAKE_EPOCH:?FAKE_EPOCH not set}"
  exit 0
fi
exec "$real_date" "\$@"
EOF
chmod +x "$fake_bin/date"

# ── 4) 窗口内：第二下 k 必须真的杀掉 ────────────────────────────────────────
: >"$kill_log"
PATH="$fake_bin:$PATH" COLUMNS=200 sh -c '
  source_file=$1; kill_log=$2; set --; . "$source_file"
  INTERVAL_SECONDS=5
  TEST_MODE=hotkey_kill
  TEST_KILL_LOG=$kill_log

  FAKE_EPOCH=1000; export FAKE_EPOCH
  perform_hotkey_kill >/dev/null

  # 3 秒后：仍在 5 秒窗口内
  FAKE_EPOCH=1003; export FAKE_EPOCH
  perform_hotkey_kill >/dev/null

  case "$STATUS_MESSAGE" in
    KILLED*) exit 0 ;;
  esac
  printf "FAIL: 窗口内的第二下 k 没有执行 kill（状态：%s）\n" "$STATUS_MESSAGE" >&2
  exit 1
' sh "$script_copy" "$kill_log"

if ! command grep -q '^-9 4002$' "$kill_log"; then
  echo "FAIL: 窗口内的第二下 k 没有留下 kill 记录" >&2
  cat "$kill_log" >&2 || :
  exit 1
fi

# ── 5) 窗口外：第二下 k 必须不杀，而是重新武装 ──────────────────────────────
: >"$kill_log"
PATH="$fake_bin:$PATH" COLUMNS=200 sh -c '
  source_file=$1; kill_log=$2; set --; . "$source_file"
  INTERVAL_SECONDS=5
  TEST_MODE=hotkey_kill
  TEST_KILL_LOG=$kill_log

  FAKE_EPOCH=1000; export FAKE_EPOCH
  perform_hotkey_kill >/dev/null

  # 8 秒后：已经超出窗口 —— 必须重新武装，而不是杀掉
  FAKE_EPOCH=1008; export FAKE_EPOCH
  perform_hotkey_kill >/dev/null

  case "$STATUS_MESSAGE" in
    ARMED*) ;;
    *)
      printf "FAIL: 窗口外的第二下 k 应当重新武装（ARMED），实际状态：%s\n" "$STATUS_MESSAGE" >&2
      exit 1
      ;;
  esac
  [ -n "$ARMED_PID" ] || { echo "FAIL: 重新武装后 ARMED_PID 不能为空" >&2; exit 1; }
  exit 0
' sh "$script_copy" "$kill_log"

if [ -s "$kill_log" ]; then
  echo "FAIL: 窗口外的第二下 k 不应产生任何 kill 记录" >&2
  cat "$kill_log" >&2
  exit 1
fi

echo "hotkey window: all assertions passed"
