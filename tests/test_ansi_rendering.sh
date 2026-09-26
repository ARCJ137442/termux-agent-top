#!/usr/bin/env sh
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

echo 'PASS: ANSI rendering contract and visible-width invariants hold'
