#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
SCRIPT="$ROOT/agent-top.sh"
fixture_dir=$(mktemp -d)
trap 'rm -rf "$fixture_dir"' EXIT

# 照抄这台设备上的真实拓扑：
#   tmux → bash t3-serve → t3 serve → { claude (provider), node codex.js → 原生 codex, proot }
# 关键点：Android 上 comm 是 argv[0] 前 15 个字符，绝对路径启动的进程
# 全被截成 "/data/data/com."，所以身份只能从 args 里认。
fixture="$fixture_dir/t3.ps"
cat >"$fixture" <<'EOF_FIXTURE'
100 1 1024 0.1 tmux tmux new-session -d -s t3-serve
101 100 2700 0.2 bash bash /data/data/com.termux/files/home/bin/t3-serve --lan
102 101 205028 3.5 /data/data/com. /data/data/com.termux/files/home/.t3/runtime/versions/0.1.6/t3 serve
103 102 56484 2.8 /data/data/com. /data/data/com.termux/files/usr/glibc/lib/ld-linux-aarch64.so.1 --library-path /data/data/com.termux/files/usr/glibc/lib @anthropic-ai/claude-code/bin/claude --output-format stream-json --verbose
104 103 1024 0.1 /data/data/com. /data/data/com.termux/files/usr/bin/sh -c helper
105 102 4104 0.3 /data/data/com. /data/data/com.termux/files/usr/bin/node /data/data/com.termux/files/usr/lib/node_modules/@openai/codex/bin/codex.js app-server
106 105 2484 1.6 /data/data/com. /data/data/com.termux/files/usr/lib/node_modules/@openai/codex/node_modules/@openai/codex-linux-arm64/vendor/aarch64-unknown-linux-musl/bin/codex app-server
107 102 2628 0.2 /data/data/com. /data/data/com.termux/files/usr/bin/proot -0 -r /data/data/com.termux/files/usr/lib/termux/proot/rootfs /usr/bin/cloudflared tunnel run
108 1 56484 1.2 /data/data/com. /data/data/com.termux/files/usr/glibc/lib/ld-linux-aarch64.so.1 --library-path /data/data/com.termux/files/usr/glibc/lib @anthropic-ai/claude-code/bin/claude --output-format stream-json
EOF_FIXTURE

output=$(COLUMNS=200 CODEX_TOP_TEST_PS_FILE="$fixture" "$SCRIPT" --once)

row_of() {
  printf '%s\n' "$output" | grep -E "^$1 " | head -n 1
}

role_field() {
  # ROLE 是第 8 列：前 7 列都不含空格，去掉它们之后剩下的开头就是 ROLE。
  # 用 sed 而不是 awk 切列，因为 awk 会吃掉 ROLE 的前导缩进 —— 而"缩进两格"
  # 正是 t3 管辖的标记，不能在断言里被抹掉。
  printf '%s\n' "$1" | sed -E 's/^([[:space:]]*[^[:space:]]+){7} //' | cut -c1-9 | sed -E 's/[[:space:]]+$//'
}

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

# 1) t3 服务自己单独成一行
t3_row=$(row_of 102)
[ -n "$t3_row" ] || fail 't3 serve should be rendered as its own row'
[ "$(role_field "$t3_row")" = "T3" ] || fail 't3 serve row should carry the T3 role'
printf '%s\n' "$t3_row" | grep -F 't3 serve' >/dev/null || fail 't3 serve row should show the t3 command line'

# 2) t3 管辖的 Claude/Codex 挂在 T3 行下面，ROLE 向后缩进两格
claude_row=$(row_of 103)
[ -n "$claude_row" ] || fail 'the Claude managed by t3 should be rendered'
[ "$(role_field "$claude_row")" = "  CLAUDE" ] || fail 'the t3-managed Claude role should be indented by two spaces'
printf '%s\n' "$claude_row" | grep -F '|- ' >/dev/null || fail 'the t3-managed Claude should be nested under the T3 row'

codex_row=$(row_of 106)
[ -n "$codex_row" ] || fail 'the Codex managed by t3 should be rendered'
[ "$(role_field "$codex_row")" = "  CODEX" ] || fail 'the t3-managed Codex role should be indented by two spaces'

# 3) 不在 t3 下的 agent 不缩进（缩进就是"被 t3 管辖"的标记）
standalone_row=$(row_of 108)
[ -n "$standalone_row" ] || fail 'a standalone Claude should be rendered'
[ "$(role_field "$standalone_row")" = "CLAUDE" ] || fail 'a standalone Claude role should not be indented'

# 4) t3 行只列它管辖的 agent，中间层不泄漏
for excluded_pid in 101 105 107; do
  if printf '%s\n' "$output" | grep -E "^${excluded_pid} " >/dev/null; then
    fail "the t3 fixture leaked the non-agent wrapper '$excluded_pid'"
  fi
done

# 5) t3 跑在 tmux 里时，tmux 行仍然保留（会话上下文不丢）
tmux_row=$(row_of 100)
[ -n "$tmux_row" ] || fail 'the tmux host of t3 should still be rendered'
[ "$(role_field "$tmux_row")" = "TMUX" ] || fail 'the tmux row should carry the TMUX role'

# 6) 汇总口径不变：t3 下的 agent 照样算进 claude/codex 的计数
printf '%s\n' "$output" | grep -F 'CLAUDE: 2 agents + 1 child = 3 proc' >/dev/null ||
  fail 'the t3-managed Claude should be counted in the Claude summary'
printf '%s\n' "$output" | grep -F 'CODEX: 1 agents + 0 child = 1 proc' >/dev/null ||
  fail 'the t3-managed Codex should be counted in the Codex summary'

echo 'PASS: t3 managed agent grouping and role indentation look correct'
