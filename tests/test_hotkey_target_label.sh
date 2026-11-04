#!/bin/sh
set -eu

# k 的确认文案必须和树里的「只显示可执行名」同源。
#
# 背景：热键确认原先用 comm 做目标名。Android 上 comm 是 argv[0] 的前 15 个
# 字符，绝对路径启动的进程一律被截成 "/data/data/com."，于是第二下 k 之前
# 用户看到的是：
#
#   ARMED: press k again to kill /data/data/com.[28446] (82.2%)
#
# SIGKILL 不可撤销，这一刻的信息量必须足够确认目标。名字来源改成 argv[0]
# 的 basename（与 CMD SHORT 模式同一个规则），comm 只作为兜底。
#
# 这里钉住：
#   1. 绝对路径启动的进程，单目标确认名是 basename；
#   2. Ctrl+K 的批量名单用同一个名字（两个 awk 程序必须一致）；
#   3. 资格校验按新名字仍然通过 —— 否则第二下 k 会被闸门拒绝并重新武装；
#   4. 旧名字（comm）不再被当成目标身份。

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
SCRIPT="$ROOT/agent-top.sh"
work=$(mktemp -d)
script_copy="$work/lib.sh"
trap 'rm -rf "$work"' EXIT

sed '/^if \[ "\$RUN_ONCE" -eq 1 \]; then$/,$d' "$SCRIPT" >"$script_copy"

# 6 列夹具：pid ppid rss pcpu comm args...
cat >"$work/ps.txt" <<'EOF_PS'
900 1 10000 0.0 claude claude
901 900 5000 42.0 /data/data/com. /data/data/com.termux/files/usr/bin/rustc --crate-name foo
902 900 4000 1.0 node /usr/bin/node /usr/lib/node_modules/server.js
EOF_PS

COLUMNS=200 CODEX_TOP_TEST_PS_FILE="$work/ps.txt" sh -c '
  source_file=$1; set --; . "$source_file"

  MONITOR_PID=999999
  AGENT_TOP_ROOTS=""
  TEST_MODE=""
  TEST_PS_FILE=${CODEX_TOP_TEST_PS_FILE:?}

  # ── 1) 单目标：绝对路径进程的名字是 basename ──────────────────────────
  target=$(select_hotkey_target)
  [ -n "$target" ] || { echo "FAIL: 单目标选择没有产出" >&2; exit 1; }

  IFS="	" read -r target_pid target_cpu target_label <<EOF
$target
EOF
  if [ "$target_pid" != "901" ]; then
    printf "FAIL: 应选中 CPU 最高的 901，实际选了 %s\n" "$target_pid" >&2
    exit 1
  fi
  if [ "$target_label" != "rustc" ]; then
    printf "FAIL: 确认名应为 rustc，实际是 [%s] —— comm 截断又漏出来了\n" \
      "$target_label" >&2
    exit 1
  fi

  # ── 2) 批量名单用同一个名字 ─────────────────────────────────────────
  list_label=$(select_hotkey_targets | awk -F "	" "\$1 == \"901\" { print \$2 }")
  if [ "$list_label" != "rustc" ]; then
    printf "FAIL: Ctrl+K 名单里的名字是 [%s]，与单目标 [%s] 不一致\n" \
      "$list_label" "$target_label" >&2
    exit 1
  fi

  # 普通命令名不受影响（basename 与 comm 相同）
  node_label=$(select_hotkey_targets | awk -F "	" "\$1 == \"902\" { print \$2 }")
  if [ "$node_label" != "node" ]; then
    printf "FAIL: 902 的名字应为 node，实际 [%s]\n" "$node_label" >&2
    exit 1
  fi

  # ── 3) 资格校验按新名字通过 ─────────────────────────────────────────
  ARMED_COMMAND=$target_label
  if ! is_armed_target_eligible "$target_pid"; then
    echo "FAIL: 用确认名做资格校验失败 —— 第二下 k 会静默重新武装" >&2
    exit 1
  fi

  # ── 4) 旧名字不再被当成身份 ─────────────────────────────────────────
  ARMED_COMMAND=/data/data/com.
  if is_armed_target_eligible "$target_pid"; then
    echo "FAIL: 截断的 comm 仍被资格校验接受 —— 两处没有同源" >&2
    exit 1
  fi
' sh "$script_copy"

echo "hotkey target label: all assertions passed"
