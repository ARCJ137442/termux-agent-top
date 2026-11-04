#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
SCRIPT="$ROOT/agent-top.sh"
fixture_dir=$(mktemp -d)
trap 'rm -rf "$fixture_dir"' EXIT

# 假 ps：模仿 procps ps 的行为 —— 没有 -ww 就按 $COLUMNS 截断命令行。
# 真机上这就是「终端一窄，整屏 agent 静默消失」的元凶：
# agent 的身份特征（@anthropic-ai/claude-code/bin/claude、.../codex）通常在第 80 列之后。
fake_bin="$fixture_dir/bin"
mkdir -p "$fake_bin"
cat >"$fake_bin/ps" <<'EOF_PS'
#!/bin/sh
wide=0
for arg in "$@"; do
  if [ "$arg" = "-ww" ]; then
    wide=1
  fi
done
if [ "$wide" -eq 1 ]; then
  printf '%s\n' "$FAKE_PS_ROWS"
  exit 0
fi
printf '%s\n' "$FAKE_PS_ROWS" | awk -v width="${COLUMNS:-80}" '{ print substr($0, 1, width) }'
EOF_PS
chmod +x "$fake_bin/ps"

FAKE_PS_ROWS='300 1 4096 1.0 S /data/data/com. /data/data/com.termux/files/usr/lib/node_modules/@anthropic-ai/claude-code/bin/claude --output-format stream-json --verbose --model some/model'
export FAKE_PS_ROWS

output=$(PATH="$fake_bin:$PATH" COLUMNS=60 "$SCRIPT" --once)

if ! printf '%s\n' "$output" | grep -F 'CLAUDE: 1 agents' >/dev/null; then
  echo 'FAIL: the process snapshot must not be truncated to the terminal width' >&2
  exit 1
fi

echo 'PASS: the process snapshot survives a narrow terminal width'
