#!/usr/bin/env sh
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

tmux_output=$(CODEX_TOP_TEST_PS_FILE="$tmux_fixture" "$SCRIPT" --once)

printf '%s\n' "$tmux_output" | grep -F 'CLAUDE: 2 proc' >/dev/null
printf '%s\n' "$tmux_output" | grep -F 'CODEX: 1 proc' >/dev/null

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

fallback_output=$(CODEX_TOP_TEST_PS_FILE="$fallback_fixture" "$SCRIPT" --once)

printf '%s\n' "$fallback_output" | grep -F 'CLAUDE: 1 proc' >/dev/null
printf '%s\n' "$fallback_output" | grep -F 'CODEX: 1 proc' >/dev/null

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

echo 'PASS: tmux conditional grouping and fallback PID tree fixtures look correct'
