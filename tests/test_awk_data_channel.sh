#!/bin/sh
set -eu

# awk 数据通道：外部数据必须走 ENVIRON，不能走 -v。
#
# 为什么单独立一个测试文件：gawk 的 `-v` 按 C 字符串规则翻译转义序列
# （\n \t \b \f \r \v \\ \" \ooo …），而 `-v` 在本脚本里同时承担着
# 「传配置」和「传数据」两个角色。
#
#   传配置（数字、脚本自带常量）—— 安全。
#   传数据（进程 argv、目录名、分支名、整帧文本）—— 数据被改写：
#     'a\nb'   --v-->  "a<LF>b"    4 字节变 3 字节，语义全变
#     'a\\b'   --v-->  "a\b"
#     'proj\q' --v-->  "projq"     + 一条 stderr warning
#
# 环境块是数据通道，gawk 不翻译它。下面每一条都在钉住这个边界。
# 判据不是「用了 -v 就有毒」：本脚本用 -v 传 ANSI 常量（裸 ESC 字节）
# 是安全的，因为 gawk 只翻译反斜杠序列，不碰控制字节。

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
SCRIPT="$ROOT/agent-top.sh"
script_copy=$(mktemp)
fixture=$(mktemp)
locations=$(mktemp)
trap 'rm -f "$script_copy" "$fixture" "$locations"' EXIT

sed '/^if \[ "\$RUN_ONCE" -eq 1 \]; then$/,$d' "$SCRIPT" >"$script_copy"

# ── 1) 结构断言：数据类变量不得再出现在 -v 上 ──────────────────────────────
# 这一条钉住「类」，不只钉住下面几个具体例子。
if command grep -nE -- '-v (value|text|content|left|right|list|location_map|previous_frame|current_frame|target_command|home_prefix)=' "$SCRIPT"; then
  echo "FAIL: 外部数据不得经 awk -v 传入（gawk 会翻译其中的转义序列）" >&2
  echo "      改用  VAR=\"\$data\" awk 'BEGIN{ v = ENVIRON[\"VAR\"] ... }'" >&2
  exit 1
fi

# ── 2) 函数级：数据原样穿过 shell↔awk 边界 ────────────────────────────────
COLUMNS=200 AGENT_TOP_ROOTS=claude sh -c '
  source_file=$1; set --; . "$source_file"

  check() { # check <标签> <实际> <期望>
    if [ "$2" != "$3" ]; then
      printf "FAIL: %s\n  实际 = %s\n  期望 = %s\n" "$1" "$2" "$3" >&2
      exit 1
    fi
  }

  # 路径：反斜杠是 Windows 路径和转义序列的公共来源
  check "compact_home_path 必须保留反斜杠" \
    "$(compact_home_path "C:\\new\\table")" "C:\\new\\table"

  # 通用字段填充
  check "render_text_field 必须保留载荷" \
    "$(render_text_field "a\\nb" 8)" "$(printf "%-8s" "a\\nb")"

  # LOCATION：目录名可以合法地带反斜杠
  check "render_process_location_field 必须保留载荷" \
    "$(render_process_location_field "proj\\name" 14)" "$(printf "%-14s" "proj\\name")"

  # COMMAND：截断逻辑仍要生效（取 width-3 个字符再补 "..."），且不能把载荷切坏
  check "render_process_command_field 截断后必须保留载荷" \
    "$(render_process_command_field "x\\tyyyyy" 6)" "$(printf "%-6s" "x\\t...")"
  check "render_process_command_field 未溢出时原样输出" \
    "$(render_process_command_field "x\\ty" 6)" "$(printf "%-6s" "x\\ty")"

  # 宽度计算：awk length() 数的是「解转义之后」的字符数，会算少
  check "text_width 必须数真实载荷" "$(text_width "a\\nb")" "4"

  # 冒号/反斜杠混排：\q 是未知转义，gawk 会吞掉反斜杠并打 warning
  check "未知转义不得被静默吞掉" \
    "$(render_text_field "proj\\qdir" 12)" "$(printf "%-12s" "proj\\qdir")"
' sh "$script_copy"

# ── 3) 帧差分：行寻址不能因为载荷里的转义而错位 ────────────────────────────
# 两帧只有第 3 行不同，且该行含一个反斜杠转义。
# 若走 -v，awk 会把它当成两行，于是写出 ESC[3;1H 和 ESC[4;1H 两行，
# 第 3 行只剩半个数据、第 4 行被污染 —— 而真实帧只有 4 行。
diff_out=$(
  COLUMNS=200 AGENT_TOP_ROOTS=claude sh -c '
    source_file=$1; set --; . "$source_file"
    previous_frame=$(printf "L1\\nL2\\nx\\nL4")
    current_frame=$(printf "L1\\nL2\\na\\\\nb\\nL4")
    render_frame_diff "$previous_frame" "$current_frame"
  ' sh "$script_copy"
)

expected_diff=$(printf '\033[3;1H\033[2Ka\\nb')
if [ "$diff_out" != "$expected_diff" ]; then
  printf "FAIL: 帧差分行寻址错位\n  实际 = %s\n  期望 = %s\n" \
    "$(printf '%s' "$diff_out" | od -An -c | head -3)" \
    "$(printf '%s' "$expected_diff" | od -An -c | head -3)" >&2
  exit 1
fi

# ── 4) 杀进程资格比对：comm 含反斜杠时不得误判为「不合格」───────────────
cat >"$fixture" <<'EOF_FIXTURE'
5000 1 65536 5.0 claude claude
5001 5000 1024 1.0 proj\nme proj\nme
EOF_FIXTURE

COLUMNS=200 AGENT_TOP_ROOTS=claude CODEX_TOP_TEST_PS_FILE="$fixture" sh -c '
  source_file=$1; fixture=$2; set --; . "$source_file"

  listed=$(select_hotkey_targets)
  case "$listed" in
    *"proj\\nme"*) : ;;
    *) printf "FAIL: select_hotkey_targets 必须原样输出 comm（实际=%s）\n" "$listed" >&2; exit 1 ;;
  esac

  ARMED_COMMAND="proj\\nme"
  if ! is_armed_target_eligible 5001; then
    echo "FAIL: comm 含反斜杠时资格比对失败 —— k,k 会永远 REARMED 杀不掉" >&2
    exit 1
  fi
' sh "$script_copy" "$fixture"

# ── 5) 端到端：LOCATION 列的目录名带反斜杠时要能显示出来 ────────────────────
cat >"$fixture" <<'EOF_FIXTURE'
6001 1 65536 12.5 claude claude --output-format stream-json
EOF_FIXTURE
printf '6001\tproj\\name\n' >"$locations"

tree_out=$(
  COLUMNS=200 AGENT_TOP_ROOTS=claude \
  CODEX_TOP_TEST_PS_FILE="$fixture" CODEX_TOP_TEST_LOCATION_FILE="$locations" \
  timeout 60 sh "$SCRIPT" --once 2>/dev/null || :
)

case "$tree_out" in
  *'proj\name'*) : ;;
  *)
    echo "FAIL: 含反斜杠的 LOCATION 没有原样渲染（-v location_map 把它拆成了两行）" >&2
    printf '%s\n' "$tree_out" | command grep -n '6001' >&2 || :
    exit 1
    ;;
esac

echo "awk data channel: all assertions passed"
