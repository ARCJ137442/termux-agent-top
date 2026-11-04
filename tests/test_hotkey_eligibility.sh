#!/bin/sh
set -eu

# 杀进程热键的不变式：
#
#   「k 选中的目标，必须属于 Ctrl+K 的资格集合」
#
# 为什么单独立一个测试文件：k 和 Ctrl+K 是**两段独立的树遍历**，
# 各自判定「谁是根」「谁可以被杀」。真杀之前还有一道闸门
# is_armed_target_eligible，它按 Ctrl+K 那份名单复核。于是只要两份
# 判据出现分歧，就会产生一个非常难懂的故障：
#
#   k 选出一个「不在名单里」的目标 → 闸门拒绝 → 不杀，直接重新武装
#   → 下一帧输入没变，还选同一个 → 再按 k 还是 REARMED
#
# 用户的观感是「按 k 武装了，再按 k 什么都没发生，提示还一模一样」。
# 在 diff 渲染下连一个字节都不变，屏幕上完全看不出发生过什么。
#
# 2026-11-04 实测到的分歧有两处：
#   1. 根集合：k 那边把 comm=="tmux" 也算根，Ctrl+K 那边不算；
#   2. 子孙守卫：k 那边没有 is_agent_root 判断，于是「嵌套 agent 根」
#      自己会被选中，而它恰恰是 Ctrl+K 唯一会跳过的东西。
# 下面用一个**属性断言**钉住不变式本身，而不是钉住这两个具体形态 ——
# 这类「两处判据各写一遍」的缺陷会换着花样复发。

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
SCRIPT="$ROOT/agent-top.sh"
work=$(mktemp -d)
script_copy="$work/lib.sh"
fixture="$work/ps"
trap 'rm -rf "$work"' EXIT

sed '/^if \[ "\$RUN_ONCE" -eq 1 \]; then$/,$d' "$SCRIPT" >"$script_copy"

# ── 夹具 ────────────────────────────────────────────────────────────────────
# A：tmux 不在任何 agent 根之下，它下面的 bash 占着最高 CPU。
#    只有把 tmux 当根的那一侧才够得着它。
cat >"$fixture.a" <<'EOF_FIXTURE'
9001 1 65536 10.0 claude claude --output-format stream-json
9002 1 1024 1.0 tmux tmux
9003 9001 512 5.0 rustc rustc -c main.c
9004 9002 512 90.0 bash bash -l
EOF_FIXTURE

# B：嵌套 agent 根（claude 里跑 codex）。9101 既是 agent 根，
#    又是 9100 的子孙；9102 同时挂在两条根路径下面。
cat >"$fixture.b" <<'EOF_FIXTURE'
9100 1 65536 10.0 claude claude --output-format stream-json
9101 9100 1024 80.0 node node /usr/bin/codex
9102 9101 512 3.0 bash bash -l
9103 9100 512 5.0 rustc rustc -c main.c
EOF_FIXTURE

# C：干净的单根三子孙，作为对照 —— 这里本来就应该通过。
cat >"$fixture.c" <<'EOF_FIXTURE'
9200 1 65536 10.0 claude claude --output-format stream-json
9201 9200 1024 12.0 rustc rustc -c main.c
9202 9200 1024 34.0 gcc gcc -c other.c
9203 9201 512 3.0 sh sh -c make
EOF_FIXTURE

# ── 属性断言：候选 ⊆ 资格 ───────────────────────────────────────────────────
check_fixture() {
  fixture_file="$1"
  label="$2"

  COLUMNS=200 AGENT_TOP_ROOTS=claude,codex CODEX_TOP_TEST_PS_FILE="$fixture_file" \
    sh -c '
      source_file=$1; label=$2; set --; . "$source_file"
      MONITOR_PID=999999

      candidates=$(select_hotkey_targets)
      armed=$(select_hotkey_target)

      # 资格集合里不允许出现重复 PID：重复会让 Ctrl+K 的报数虚高
      # （同一个进程被 kill 两次，第二次通常仍返回 0）。
      declared=$(printf "%s\n" "$candidates" | awk -F "\t" "NF { print \$1 }")
      distinct=$(printf "%s\n" "$declared" | sort -u)
      if [ "$(printf "%s\n" "$declared" | command grep -c .)" != "$(printf "%s\n" "$distinct" | command grep -c .)" ]; then
        printf "FAIL: [%s] Ctrl+K 名单里有重复 PID\n%s\n" "$label" "$candidates" >&2
        exit 1
      fi

      # 没有候选是允许的（夹具里可能一个合格目标都没有）
      [ -n "$armed" ] || exit 0

      armed_pid=$(printf "%s" "$armed" | cut -f1)
      armed_comm=$(printf "%s" "$armed" | cut -f3)

      if ! printf "%s\n" "$candidates" | awk -F "\t" -v p="$armed_pid" -v c="$armed_comm" "
            \$1 == p && \$2 == c { found = 1 }
            END { exit !found }
          "; then
        printf "FAIL: [%s] k 选中的目标不在 Ctrl+K 的资格集合里\n" "$label" >&2
        printf "      k 选中   : %s\n" "$armed" >&2
        printf "      Ctrl+K   : %s\n" "$(printf "%s" "$candidates" | tr "\n" " ")" >&2
        printf "      后果     : 闸门拒绝 → 不杀 → 重新武装 → 再按 k 还是 REARMED\n" >&2
        exit 1
      fi
    ' sh "$script_copy" "$label"
}

check_fixture "$fixture.a" "tmux 分支"
check_fixture "$fixture.b" "嵌套 agent 根"
check_fixture "$fixture.c" "单根对照"

# ── 具体回归：tmux 里的高 CPU 进程不得被 k 选中 ─────────────────────────────
COLUMNS=200 AGENT_TOP_ROOTS=claude,codex CODEX_TOP_TEST_PS_FILE="$fixture.a" \
  sh -c '
    source_file=$1; set --; . "$source_file"
    MONITOR_PID=999999
    armed=$(select_hotkey_target)
    pid=$(printf "%s" "$armed" | cut -f1)
    [ "$pid" != "9004" ] || {
      echo "FAIL: k 不得选中 agent 根之外的 tmux 子树进程（9004）" >&2; exit 1; }
  ' sh "$script_copy"

# ── 具体回归：嵌套 agent 根不得被杀死 ───────────────────────────────────────
COLUMNS=200 AGENT_TOP_ROOTS=claude,codex CODEX_TOP_TEST_PS_FILE="$fixture.b" \
  sh -c '
    source_file=$1; set --; . "$source_file"
    MONITOR_PID=999999
    armed=$(select_hotkey_target)
    pid=$(printf "%s" "$armed" | cut -f1)
    [ "$pid" != "9101" ] || {
      echo "FAIL: k 不得把嵌套 agent 根本身当作可杀目标（9101）" >&2; exit 1; }
  ' sh "$script_copy"

echo "hotkey eligibility: all assertions passed"
