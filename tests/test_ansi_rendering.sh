#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
SCRIPT="$ROOT/agent-top.sh"

escape=$(printf '\033')
reverse=$(printf '\033[7m')
reset=$(printf '\033[0m')
green=$(printf '\033[92m')
orange=$(printf '\033[38;2;255;170;0m')
cyan=$(printf '\033[38;2;110;235;255m')
white=$(printf '\033[97m')
green_background=$(printf '\033[102m')
marker_prefix="${green}${reverse}|${reset}${green}"

visible_width() {
  printf '%s\n' "$1" | awk -v escape="$escape" '
    {
      line = $0;
      width = 0;
      position = 1;
      line_length = length(line);
      while (position <= line_length) {
        character = substr(line, position, 1);
        if (character == escape && substr(line, position + 1, 1) == "[") {
          position += 2;
          while (position <= line_length && substr(line, position, 1) != "m") position++;
          if (position <= line_length) position++;
        } else {
          width++;
          position++;
        }
      }
      print width;
    }
  '
}

strip_ansi() {
  printf '%s\n' "$1" | awk -v escape="$escape" '
    {
      line = $0;
      result = "";
      position = 1;
      line_length = length(line);
      while (position <= line_length) {
        character = substr(line, position, 1);
        if (character == escape && substr(line, position + 1, 1) == "[") {
          position += 2;
          while (position <= line_length && substr(line, position, 1) != "m") position++;
          if (position <= line_length) position++;
        } else {
          result = result character;
          position++;
        }
      }
      print result;
    }
  '
}

bar_prefix() {
  line="$1"
  percent="$2"
  stripped=$(strip_ansi "$line")
  printf '%s\n' "$stripped" | awk -v token="  ${percent}%" 'BEGIN { index_value = 0 } {
    index_value = index($0, token);
    if (index_value > 0) print substr($0, 1, index_value - 1);
    else print $0;
  }'
}

line_for() {
  resource="$1"
  line=$(printf '%s\n' "$2" | grep -E "^(\\| )?${resource}:" | head -n 1)
  case "$line" in
    '| '*) line=${line#\| } ;;
  esac
  printf '%s\n' "$line" | sed 's/[[:space:]]*|$//; s/[[:space:]]*$//'
}

for columns in 72 80 90; do
  styled_output=$(COLUMNS="$columns" CODEX_TOP_FORCE_STYLE=1 CODEX_TOP_TEST_MODE=diff "$SCRIPT" --once)
  plain_output=$(COLUMNS="$columns" CODEX_TOP_TEST_MODE=diff "$SCRIPT" --once)

  for resource in CPU Mem; do
    styled_line=$(line_for "$resource" "$styled_output")
    plain_line=$(line_for "$resource" "$plain_output")

    if ! printf '%s\n' "$styled_line" | grep -F -- "$marker_prefix" >/dev/null 2>&1; then
      echo "FAIL: $resource at COLUMNS=$columns must render green reverse-video | followed by independently green blocks" >&2
      exit 1
    fi

    if printf '%s\n' "$styled_line" | grep -F "$white" >/dev/null 2>&1 || \
       printf '%s\n' "$styled_line" | grep -F "$green_background" >/dev/null 2>&1; then
      echo "FAIL: $resource at COLUMNS=$columns must not use the rejected white-on-green marker protocol" >&2
      exit 1
    fi

    case "$resource" in
      CPU) percent='42.0' ;;
      Mem) percent='50.0' ;;
    esac
    styled_bar=$(bar_prefix "$styled_line" "$percent")
    plain_bar=$(bar_prefix "$plain_line" "$percent")
    styled_width=$(visible_width "$styled_bar")
    plain_width=$(visible_width "$plain_bar")
    if [ "$styled_width" -ne "$plain_width" ]; then
      echo "FAIL: ANSI styling changed visible $resource bar width at COLUMNS=$columns" >&2
      exit 1
    fi
    if [ "$styled_bar" != "$plain_bar" ]; then
      echo "FAIL: ANSI styling changed visible $resource bar cells at COLUMNS=$columns" >&2
      exit 1
    fi
  done

  if printf '%s\n' "$plain_output" | grep -F "$escape[" >/dev/null 2>&1; then
    echo "FAIL: plain output at COLUMNS=$columns must not contain ANSI CSI sequences" >&2
    exit 1
  fi
done

narrow_mem=$(line_for Mem "$(COLUMNS=80 CODEX_TOP_FORCE_STYLE=1 CODEX_TOP_TEST_MODE=diff "$SCRIPT" --once)")
if ! printf '%s\n' "$narrow_mem" | grep -F -- "${orange}${reverse}c${reset}" >/dev/null 2>&1; then
  echo 'FAIL: a one-cell Claude label must retain the theme/reverse/reset contract' >&2
  exit 1
fi
if ! printf '%s\n' "$narrow_mem" | grep -F -- "${cyan}${reverse}c${reset}" >/dev/null 2>&1; then
  echo 'FAIL: a one-cell Codex label must retain the theme/reverse/reset contract' >&2
  exit 1
fi

# ── ROLE 列的字节序 ──────────────────────────────────────────────────────
# ROLE 列是固定 9 格，渲染协议：
#   [主题色] + 9 个可见格 + [reset]
# 其中「可见格」的前两格可以是缩进 —— 缩进属于颜色段内部（空格本身不着色，
# 但仍然在 span 里），所以断言必须落在「紧贴标签之前的字节」上。
#
# t3 服务自己那一行没有主题色：ROLE = "T3" 是纯文本，不带 color/reset。
fixture_dir=$(mktemp -d)
trap 'rm -rf "$fixture_dir"' EXIT
cat >"$fixture_dir/t3.ps" <<'EOF_FIXTURE'
100 1 1024 0.1 tmux tmux new-session -d -s t3-serve
102 101 205028 3.5 /data/data/com. /data/data/com.termux/files/home/.t3/runtime/versions/0.1.6/t3 serve
103 102 56484 2.8 /data/data/com. /data/data/com.termux/files/usr/glibc/lib/ld-linux-aarch64.so.1 --library-path /data/data/com.termux/files/usr/glibc/lib @anthropic-ai/claude-code/bin/claude --output-format stream-json --verbose
106 102 4104 0.3 /data/data/com. /data/data/com.termux/files/usr/lib/node_modules/@openai/codex/node_modules/@openai/codex-linux-arm64/vendor/aarch64-unknown-linux-musl/bin/codex app-server
108 1 56484 1.2 /data/data/com. /data/data/com.termux/files/usr/glibc/lib/ld-linux-aarch64.so.1 --library-path /data/data/com.termux/files/usr/glibc/lib @anthropic-ai/claude-code/bin/claude --output-format stream-json
EOF_FIXTURE

styled_tree=$(COLUMNS=200 CODEX_TOP_FORCE_STYLE=1 CODEX_TOP_TEST_PS_FILE="$fixture_dir/t3.ps" "$SCRIPT" --once)
plain_tree=$(COLUMNS=200 CODEX_TOP_TEST_PS_FILE="$fixture_dir/t3.ps" "$SCRIPT" --once)

# 紧贴标签之前的字节 —— 取「最后一个 reset 之后」到标签之间的那一段，
# 也就是 ROLE 字段自己带的那一段（上一格进度条的 reset 之前的不算）
bytes_before() {
  printf '%s\n' "$1" | awk -v label="$2" -v reset="$reset" '
    {
      line = $0;
      pos = index(line, label);
      if (pos > 0) {
        prefix = substr(line, 1, pos - 1);
        last = 0;
        search = 1;
        while (1) {
          found = index(substr(prefix, search), reset);
          if (found == 0) break;
          last = search + found - 1;
          search = last + length(reset);
        }
        if (last > 0) print substr(prefix, last + length(reset));
        else print prefix;
        exit;
      }
    }'
}

row_for() {
  printf '%s\n' "$1" | grep -E "^$2 " | head -n 1
}

t3_styled_row=$(row_for "$styled_tree" 102)
t3_plain_row=$(row_for "$plain_tree" 102)
hosted_claude_row=$(row_for "$styled_tree" 103)
hosted_codex_row=$(row_for "$styled_tree" 106)
standalone_claude_row=$(row_for "$styled_tree" 108)

if [ -z "$t3_styled_row" ] || [ -z "$hosted_claude_row" ] || [ -z "$hosted_codex_row" ] || [ -z "$standalone_claude_row" ]; then
  echo 'FAIL: the T3 fixture rows must all be rendered' >&2
  exit 1
fi

# 1) t3 服务自己的 ROLE 字段是纯文本：标签之前不得出现任何 CSI 序列
#    （上一格进度条自己的 reset 结束符是允许的，它不属于 ROLE 字段）
t3_before=$(bytes_before "$t3_styled_row" 'T3')
if [ -z "$t3_before" ]; then
  echo 'FAIL: the T3 role label could not be located in its row' >&2
  exit 1
fi
case "$t3_before" in
  *"${escape}["*)
    echo 'FAIL: the T3 role label must be plain text without a color span' >&2
    exit 1
    ;;
esac

# 2) 被 t3 管辖的 agent：主题色 → 两格缩进 → 标签，顺序不能反
claude_before=$(bytes_before "$hosted_claude_row" 'CLAUDE')
case "$claude_before" in
  *"${orange}  ")
    ;;
  *)
    echo "FAIL: a T3-hosted Claude role must render theme color, then the two-space indent, then the label" >&2
    exit 1
    ;;
esac

codex_before=$(bytes_before "$hosted_codex_row" 'CODEX')
case "$codex_before" in
  *"${cyan}  ")
    ;;
  *)
    echo "FAIL: a T3-hosted Codex role must render theme color, then the two-space indent, then the label" >&2
    exit 1
    ;;
esac

# 3) 不被 t3 管辖的 agent：没有缩进，颜色直接贴住标签
standalone_before=$(bytes_before "$standalone_claude_row" 'CLAUDE')
case "$standalone_before" in
  *"${orange}")
    ;;
  *)
    echo 'FAIL: a standalone Claude role must not be indented' >&2
    exit 1
    ;;
esac

# 4) 去掉 ANSI 之后，styled 与 plain 的行必须逐字相同
for pid in 102 103 106 108; do
  styled_row=$(row_for "$styled_tree" "$pid")
  plain_row=$(row_for "$plain_tree" "$pid")
  if [ "$(strip_ansi "$styled_row")" != "$plain_row" ]; then
    echo "FAIL: ANSI styling changed the visible content of row $pid" >&2
    exit 1
  fi
done

echo 'PASS: ANSI rendering contract and visible-width invariants hold'
