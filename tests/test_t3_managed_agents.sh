#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
SCRIPT="$ROOT/agent-top.sh"
fixture_dir=$(mktemp -d)
trap 'rm -rf "$fixture_dir"' EXIT

# 照抄这台设备上的真实拓扑：
#   tmux(100) → bash t3-serve(101) → t3 serve(102) → { claude(103), node codex.js(105), 原生 codex(106), proot(107) }
#   tmux(110) → claude(111)                     ← 直接挂在 tmux 下的 agent
#   独立的 claude(108)
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
110 1 1024 0.1 tmux tmux new-session -d -s work
111 110 56484 1.1 /data/data/com. /data/data/com.termux/files/usr/glibc/lib/ld-linux-aarch64.so.1 --library-path /data/data/com.termux/files/usr/glibc/lib @anthropic-ai/claude-code/bin/claude --output-format stream-json
EOF_FIXTURE

output=$(COLUMNS=200 CODEX_TOP_TEST_PS_FILE="$fixture" "$SCRIPT" --once)
styled_output=$(COLUMNS=200 CODEX_TOP_FORCE_STYLE=1 CODEX_TOP_TEST_PS_FILE="$fixture" "$SCRIPT" --once)

escape=$(printf '\033')
reset=$(printf '\033[0m')
hosted_color=$(printf '\033[38;2;185;125;255m')
claude_color=$(printf '\033[38;2;255;170;0m')

row_of() {
  printf '%s\n' "$1" | grep -E "^$2 " | head -n 1
}

role_field() {
  # ROLE 是第 8 列：前 7 列都不含空格，去掉它们之后剩下的开头就是 ROLE。
  # 用 sed 而不是 awk 切列，因为 awk 会吃掉 ROLE 的前导缩进 ——
  # 而"缩进"正是要断言的东西（现在约定：归属不靠缩进，靠颜色）。
  printf '%s\n' "$1" | sed -E 's/^([[:space:]]*[^[:space:]]+){7} //' | cut -c1-9 | sed -E 's/[[:space:]]+$//'
}

role_color_of() {
  # 取 ROLE 标签紧邻其前的颜色码：先定位标签，再回退到上一个 reset 之后的那一段。
  printf '%s\n' "$1" | awk -v label="$2" -v reset="$reset" -v escape="$escape" '
    {
      line = $0;
      pos = index(line, label);
      if (pos == 0) {
        print "";
        exit;
      }
      prefix = substr(line, 1, pos - 1);
      last = 0;
      search = 1;
      while (1) {
        found = index(substr(prefix, search), reset);
        if (found == 0) break;
        last = search + found - 1;
        search = last + length(reset);
      }
      segment = (last > 0) ? substr(prefix, last + length(reset)) : prefix;
      color = "";
      position = 1;
      while (position <= length(segment)) {
        if (substr(segment, position, 1) == escape) {
          end = index(substr(segment, position), "m");
          if (end == 0) break;
          color = substr(segment, position, end);
          position += end;
        } else {
          position++;
        }
      }
      print color;
      exit;
    }'
}

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

# 1) t3 服务自己单独成一行
t3_row=$(row_of "$output" 102)
[ -n "$t3_row" ] || fail 't3 serve should be rendered as its own row'
[ "$(role_field "$t3_row")" = "T3" ] || fail 't3 serve row should carry the T3 role'
printf '%s\n' "$t3_row" | grep -F 't3 serve' >/dev/null || fail 't3 serve row should show the t3 command line'

# 2) t3 管辖的 Claude/Codex 挂在 T3 行下面，ROLE 不缩进（归属靠颜色，不靠缩进）
claude_row=$(row_of "$output" 103)
[ -n "$claude_row" ] || fail 'the Claude managed by t3 should be rendered'
[ "$(role_field "$claude_row")" = "CLAUDE" ] || fail 'the t3-managed Claude role should not be indented'
printf '%s\n' "$claude_row" | grep -F '|- ' >/dev/null || fail 'the t3-managed Claude should be nested under the T3 row'

codex_row=$(row_of "$output" 106)
[ -n "$codex_row" ] || fail 'the Codex managed by t3 should be rendered'
[ "$(role_field "$codex_row")" = "CODEX" ] || fail 'the t3-managed Codex role should not be indented'

# 3) 颜色区分归属：宿主管辖的用宿主色，独立的用类型色
styled_t3=$(row_of "$styled_output" 102)
styled_claude=$(row_of "$styled_output" 103)
styled_codex=$(row_of "$styled_output" 106)
styled_standalone=$(row_of "$styled_output" 108)

[ "$(role_color_of "$styled_t3" 'T3')" = "$hosted_color" ] || fail 'the T3 row should wear the host color'
[ "$(role_color_of "$styled_claude" 'CLAUDE')" = "$hosted_color" ] || fail 'the t3-managed Claude should wear the host color'
[ "$(role_color_of "$styled_codex" 'CODEX')" = "$hosted_color" ] || fail 'the t3-managed Codex should wear the host color'
[ "$(role_color_of "$styled_standalone" 'CLAUDE')" = "$claude_color" ] || fail 'a standalone Claude should keep its own type color'

# 4) 不在 t3 下的 agent 用类型色，不缩进
standalone_row=$(row_of "$output" 108)
[ -n "$standalone_row" ] || fail 'a standalone Claude should be rendered'
[ "$(role_field "$standalone_row")" = "CLAUDE" ] || fail 'a standalone Claude role should not be indented'

# 5) t3 行只列它管辖的 agent，中间层不泄漏
for excluded_pid in 101 105 107; do
  if printf '%s\n' "$output" | grep -E "^${excluded_pid} " >/dev/null; then
    fail "the t3 fixture leaked the non-agent wrapper '$excluded_pid'"
  fi
done

# 6) 没有 Claude/Codex 子进程的 tmux 不显示；
#    直接挂着 agent 的 tmux 照旧显示，agent 挂在它下面
if printf '%s\n' "$output" | grep -E '^100 ' >/dev/null; then
  fail 'a tmux session without direct Claude/Codex children must not be rendered'
fi
tmux_row=$(row_of "$output" 110)
[ -n "$tmux_row" ] || fail 'a tmux session with direct Claude/Codex children should still be rendered'
[ "$(role_field "$tmux_row")" = "TMUX" ] || fail 'the tmux row should carry the TMUX role'
tmux_agent_row=$(row_of "$output" 111)
[ -n "$tmux_agent_row" ] || fail 'the agent under a tmux session should be rendered'
printf '%s\n' "$tmux_agent_row" | grep -F '|- ' >/dev/null || fail 'the agent should be nested under its tmux row'

# 7) 汇总口径不变：t3 下的 agent 照样算进 claude/codex 的计数
printf '%s\n' "$output" | grep -F 'CLAUDE: 3 agents + 1 child = 4 proc' >/dev/null ||
  fail 'the t3-managed Claude should be counted in the Claude summary'
printf '%s\n' "$output" | grep -F 'CODEX: 1 agents + 0 child = 1 proc' >/dev/null ||
  fail 'the t3-managed Codex should be counted in the Codex summary'

echo 'PASS: t3 managed agent grouping and role coloring look correct'
