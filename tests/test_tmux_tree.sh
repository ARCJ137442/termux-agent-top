#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
SCRIPT="$ROOT/agent-top.sh"
fixture_dir=$(mktemp -d)
trap 'rm -rf "$fixture_dir"' EXIT

tmux_fixture="$fixture_dir/tmux.ps"
cat >"$tmux_fixture" <<'EOF_FIXTURE'
100 1 1024 0.1 tmux tmux new-session
101 100 2048 0.2 bash bash -lc claude
102 101 8192 1.0 claude claude
103 102 1024 2.0 bun bun claude-child
104 103 512 0.5 rustc rustc --crate-name agent-child
105 100 2048 0.1 bash bash -lc unrelated
106 105 4096 0.4 node node unrelated-sibling
107 100 8192 1.1 claude claude
108 107 1024 2.1 bun bun claude-second-child
109 108 512 0.6 sh sh claude-grandchild
110 100 8192 1.2 codex codex
111 110 1024 2.2 node node codex-child
112 111 512 0.7 sh sh codex-grandchild
113 100 2048 0.3 python python unrelated-sibling
EOF_FIXTURE

fallback_fixture="$fixture_dir/fallback.ps"
cat >"$fallback_fixture" <<'EOF_FIXTURE'
200 1 8192 1.0 claude claude
201 200 1024 2.0 bun bun claude-child
202 201 512 0.5 sh sh claude-grandchild
203 1 8192 1.1 codex codex
204 203 1024 2.1 node node codex-child
205 204 512 0.6 sh sh codex-grandchild
206 1 4096 0.4 bash bash unrelated-sibling
207 206 512 0.2 node node unrelated-descendant
EOF_FIXTURE

tmux_output=$(COLUMNS=200 CODEX_TOP_TEST_PS_FILE="$tmux_fixture" "$SCRIPT" --once)

printf '%s\n' "$tmux_output" | grep -F 'CLAUDE: 2 agents + 4 child = 6 proc' >/dev/null
printf '%s\n' "$tmux_output" | grep -F 'CODEX: 1 agents + 2 child = 3 proc' >/dev/null

for pattern in \
  '100 ' \
  '102 ' \
  '103 ' \
  '104 ' \
  '107 ' \
  '108 ' \
  '109 ' \
  '110 ' \
  '111 ' \
  '112 '; do
  if ! printf '%s\n' "$tmux_output" | grep -E "^${pattern}" >/dev/null; then
    echo "FAIL: tmux fixture output missing process '${pattern% }'" >&2
    exit 1
  fi
done

for excluded_pid in 101 105 106 113; do
  if printf '%s\n' "$tmux_output" | grep -E "^${excluded_pid} " >/dev/null; then
    echo "FAIL: tmux fixture leaked non-agent sibling '$excluded_pid'" >&2
    exit 1
  fi
done

if ! printf '%s\n' "$tmux_output" | grep -E '^100 .*tmux new-session' >/dev/null; then
  echo 'FAIL: tmux ancestor should be retained as the conditional grouping root' >&2
  exit 1
fi

fallback_output=$(COLUMNS=200 CODEX_TOP_TEST_PS_FILE="$fallback_fixture" "$SCRIPT" --once)

printf '%s\n' "$fallback_output" | grep -F 'CLAUDE: 1 agents + 2 child = 3 proc' >/dev/null
printf '%s\n' "$fallback_output" | grep -F 'CODEX: 1 agents + 2 child = 3 proc' >/dev/null

for pattern in \
  '200 ' \
  '201 ' \
  '202 ' \
  '203 ' \
  '204 ' \
  '205 '; do
  if ! printf '%s\n' "$fallback_output" | grep -E "^${pattern}" >/dev/null; then
    echo "FAIL: fallback PID tree missing process '${pattern% }'" >&2
    exit 1
  fi
done

for excluded_pid in 206 207; do
  if printf '%s\n' "$fallback_output" | grep -E "^${excluded_pid} " >/dev/null; then
    echo "FAIL: fallback PID tree leaked unrelated process '$excluded_pid'" >&2
    exit 1
  fi
done

# 包装进程：祖先里有一个「comm 不是 tmux、但参数里出现 tmux 这个词」的进程。
#   100 tmux  ← 真正的集线器
#   101 sh -c tmux new-session ...  ← 只是启动 tmux 的命令，不是集线器
#   102 claude → 103 bash
# 这是曾经真实存在过的「agent 整行消失」：往上找 tmux 时用了「参数里含 tmux」
# 这个宽松判据，于是 102 被登记到 101 名下；可 101 的 comm 是 sh，永远进不了
# root_order，也就永远不会被打印 —— 结果 102 被子节点循环跳过，进程树里彻底
# 看不到它，而汇总行还在数它。判据必须和 hub_kind() 一致（只看 comm）。
wrapper_fixture="$fixture_dir/wrapper.ps"
cat >"$wrapper_fixture" <<'EOF_FIXTURE'
100 1 1024 0.1 tmux tmux new-session -d -s work
101 100 2048 0.2 sh sh -c tmux new-session -d work
102 101 8192 2.0 claude claude --output-format stream-json
103 102 1024 0.1 bash bash -c helper
EOF_FIXTURE

wrapper_output=$(COLUMNS=200 CODEX_TOP_TEST_PS_FILE="$wrapper_fixture" "$SCRIPT" --once)

printf '%s\n' "$wrapper_output" | grep -F 'CLAUDE: 1 agents + 1 child = 2 proc' >/dev/null
for pattern in '100 ' '102 ' '103 '; do
  if ! printf '%s\n' "$wrapper_output" | grep -E "^${pattern}" >/dev/null; then
    echo "FAIL: an agent below a tmux-looking wrapper must still be rendered (missing '${pattern% }')" >&2
    exit 1
  fi
done
if printf '%s\n' "$wrapper_output" | grep -E '^101 ' >/dev/null; then
  echo 'FAIL: the tmux-looking wrapper itself is not an agent and must not be rendered' >&2
  exit 1
fi

echo 'PASS: tmux conditional grouping and fallback PID tree fixtures look correct'
