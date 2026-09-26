#!/usr/bin/env sh
set -eu

INTERVAL_SECONDS=1
FPS_LABEL=""
RUN_ONCE=0
SUMMARY_ONLY=0
MONITOR_PID=$$
LIVE_SCREEN_ACTIVE=0
LOOP_ITERATION=0
PREVIOUS_FRAME=""
TEST_MODE="${CODEX_TOP_TEST_MODE:-}"
TEST_CYCLES="${CODEX_TOP_TEST_CYCLES:-0}"
FORCE_STYLE="${CODEX_TOP_FORCE_STYLE:-0}"
GLOBAL_CPU_PERCENT=0.0
GLOBAL_CPU_RAW_PERCENT=0.0
CLAUDE_CPU_PERCENT=0.0
CODEX_CPU_PERCENT=0.0
OTHER_CPU_PERCENT=0.0
CLAUDE_RSS_KB=0
CODEX_RSS_KB=0
AGENT_TOTAL_RSS_KB=0
AGENT_ROOT_SUMMARY=""
TEST_PS_FILE="${CODEX_TOP_TEST_PS_FILE:-}"
TEST_PS_LOG="${CODEX_TOP_TEST_PS_LOG:-}"
TEST_LOCATION_FILE="${CODEX_TOP_TEST_LOCATION_FILE:-}"
FRAME_PROCESS_SNAPSHOT=""
FRAME_LOCATION_MAP=""
FRAME_LOCATION_WIDTH=7
DEFAULT_PANEL_WIDTH=300
MIN_PANEL_WIDTH=72
SUMMARY_BAR_WIDTH=20
RESOURCE_BAR_MAX_WIDTH=50
RESOURCE_LABEL_WIDTH=6
RESOURCE_PERCENT_FIELD_WIDTH=6
CPU_BAR_WIDTH=10
MEM_BAR_WIDTH=10
PROCESS_MEM_BAR_FIELD_WIDTH=$MEM_BAR_WIDTH
PROCESS_CPU_BAR_FIELD_WIDTH=$CPU_BAR_WIDTH
DEFAULT_PROCESS_LOCATION_WIDTH=20
MIN_PROCESS_COMMAND_WIDTH=7
PROCESS_BASE_FIXED_WIDTH=$((6 + 1 + 6 + 1 + 7 + 1 + 6 + 1 + PROCESS_MEM_BAR_FIELD_WIDTH + 1 + 6 + 1 + PROCESS_CPU_BAR_FIELD_WIDTH + 1 + 9 + 1))
PROCESS_LOCATION_WIDTH=$DEFAULT_PROCESS_LOCATION_WIDTH
PROCESS_FIXED_WIDTH=$((PROCESS_BASE_FIXED_WIDTH + PROCESS_LOCATION_WIDTH + 1))
PANEL_WIDTH=$DEFAULT_PANEL_WIDTH
PANEL_HEIGHT=0
PANEL_INNER_WIDTH=$((PANEL_WIDTH - 4))
PROCESS_COMMAND_WIDTH=$((PANEL_WIDTH - PROCESS_FIXED_WIDTH))
STYLE_ENABLED=0
RESIZE_PENDING=0
TTY_INPUT_READY=0
TTY_STATE=""
STATUS_MESSAGE=""
STATUS_TTL=0
STATUS_TTL_FRAMES=3
ARMED_PID=""
ARMED_CPU=""
ARMED_COMMAND=""
ARMED_UNTIL=0
TREE_FOCUS=0
EXIT_REQUESTED=0
TEST_KILL_LOG="${CODEX_TOP_TEST_KILL_LOG:-}"
CTRL_K_CHAR="$(printf '\013')"
ANSI_REVERSE="$(printf '\033[7m')"
ANSI_RESET="$(printf '\033[0m')"
ANSI_BOLD="$(printf '\033[1m')"
ANSI_NO_BOLD="$(printf '\033[22m')"
ANSI_BRIGHT_ORANGE="$(printf '\033[38;2;255;170;0m')"
ANSI_BRIGHT_CLAUDE="$ANSI_BRIGHT_ORANGE"
ANSI_BRIGHT_CODEX="$(printf '\033[38;2;110;235;255m')"
ANSI_BRIGHT_RED="$(printf '\033[91m')"
ANSI_BRIGHT_GREEN="$(printf '\033[92m')"
ANSI_BRIGHT_YELLOW="$(printf '\033[93m')"
ANSI_GREEN="$(printf '\033[32m')"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --once)
      RUN_ONCE=1
      ;;
    --summary-only)
      SUMMARY_ONLY=1
      ;;
    --interval)
      shift
      INTERVAL_SECONDS="${1:-1}"
      ;;
    *)
      echo "usage: $0 [--once] [--summary-only] [--interval seconds]" >&2
      exit 1
      ;;
  esac
  shift
done

if ! awk -v interval="$INTERVAL_SECONDS" 'BEGIN {
  if (interval ~ /^([0-9]+([.][0-9]*)?|[.][0-9]+)$/ && interval + 0 >= 0) {
    exit 0;
  }
  exit 1;
}'; then
  echo "interval must be a non-negative number" >&2
  exit 1
fi

FPS_LABEL=$(
  awk -v interval="$INTERVAL_SECONDS" 'BEGIN {
    if (interval + 0 == 0) {
      print "max";
      exit;
    }

    fps = 1.0 / interval;
    text = sprintf("%.3f", fps);
    sub(/0+$/, "", text);
    sub(/[.]$/, "", text);
    print text;
  }'
)

if [ "$FORCE_STYLE" = "1" ] || [ -t 1 ]; then
  STYLE_ENABLED=1
fi

detect_terminal_columns() {
  if [ "$TEST_MODE" = "resize" ]; then
    if [ "$LOOP_ITERATION" -le 1 ]; then
      printf '%s\n' 110
    else
      printf '%s\n' 80
    fi
    return
  fi

  if [ -n "${COLUMNS:-}" ]; then
    printf '%s\n' "$COLUMNS"
    return
  fi

  stty size 2>/dev/null | awk 'NF >= 2 { print $2; exit }'
}

detect_terminal_rows() {
  if [ "$TEST_MODE" = "resize" ]; then
    if [ "$LOOP_ITERATION" -le 1 ]; then
      printf '%s\n' 14
    else
      printf '%s\n' 6
    fi
    return
  fi

  if [ -n "${LINES:-}" ]; then
    printf '%s\n' "$LINES"
    return
  fi

  stty size 2>/dev/null | awk 'NF >= 2 { print $1; exit }'
}

configure_layout() {
  terminal_columns=$(detect_terminal_columns)
  terminal_rows=$(detect_terminal_rows)

  case "$terminal_columns" in
    ''|*[!0-9]*)
      PANEL_WIDTH=$DEFAULT_PANEL_WIDTH
      ;;
    *)
      PANEL_WIDTH=$terminal_columns
      if [ "$PANEL_WIDTH" -gt "$DEFAULT_PANEL_WIDTH" ]; then
        PANEL_WIDTH=$DEFAULT_PANEL_WIDTH
      fi
      if [ "$PANEL_WIDTH" -lt "$MIN_PANEL_WIDTH" ]; then
        PANEL_WIDTH=$MIN_PANEL_WIDTH
      fi
      ;;
  esac

  case "$terminal_rows" in
    ''|*[!0-9]*)
      PANEL_HEIGHT=0
      ;;
    *)
      PANEL_HEIGHT=$terminal_rows
      ;;
  esac

  PANEL_INNER_WIDTH=$((PANEL_WIDTH - 4))
  configure_process_location_layout
}

configure_process_location_layout() {
  PROCESS_LOCATION_WIDTH=$FRAME_LOCATION_WIDTH
  if [ "$PROCESS_LOCATION_WIDTH" -lt 7 ]; then
    PROCESS_LOCATION_WIDTH=7
  fi
  PROCESS_FIXED_WIDTH=$((PROCESS_BASE_FIXED_WIDTH + PROCESS_LOCATION_WIDTH + 1))
  PROCESS_COMMAND_WIDTH=$((PANEL_WIDTH - PROCESS_FIXED_WIDTH))
  if [ "$PROCESS_COMMAND_WIDTH" -lt "$MIN_PROCESS_COMMAND_WIDTH" ]; then
    max_location_width=$((PANEL_WIDTH - PROCESS_BASE_FIXED_WIDTH - MIN_PROCESS_COMMAND_WIDTH - 1))
    if [ "$max_location_width" -lt 0 ]; then
      max_location_width=0
    fi
    PROCESS_LOCATION_WIDTH=$max_location_width
    PROCESS_FIXED_WIDTH=$((PROCESS_BASE_FIXED_WIDTH + PROCESS_LOCATION_WIDTH + 1))
    PROCESS_COMMAND_WIDTH=$((PANEL_WIDTH - PROCESS_FIXED_WIDTH))
  fi
  if [ "$PROCESS_COMMAND_WIDTH" -lt 1 ]; then
    PROCESS_COMMAND_WIDTH=1
  fi
}

configure_layout

is_fixture_mode() {
  case "$TEST_MODE" in
    diff|diff_title|resize|risk_warn|risk_hot|risk_crit|risk_cpu_hot|risk_cpu_crit|disk_warn|disk_hot|hotkey_kill|hotkey_no_target|hotkey_kill_fail|hotkey_kill_all|hotkey_kill_all_no_target|hotkey_kill_all_partial_fail)
      return 0
      ;;
  esac

  return 1
}

process_snapshot() {
  if [ -n "$TEST_PS_LOG" ]; then
    printf '%s\n' snapshot >>"$TEST_PS_LOG"
  fi
  if [ -n "$TEST_PS_FILE" ]; then
    awk '{
      pid = $1; parent = $2; rss = $3; cpu = $4; command = $5
      $1 = ""; $2 = ""; $3 = ""; $4 = ""; $5 = ""
      sub(/^[[:space:]]+/, "", $0)
      print pid, parent, rss, cpu, "S", command, $0
    }' "$TEST_PS_FILE"
    return
  fi
  ps -eo pid=,ppid=,rss=,pcpu=,stat=,comm=,args=
}

snapshot_lines() {
  printf '%s\n' "$FRAME_PROCESS_SNAPSHOT"
}

compact_home_path() {
  text="$1"
  awk -v text="$text" -v home_prefix="$HOME" -v termux_prefix="/data/data/com.termux/files" '
    function replace_prefix(value, prefix, replacement,    pos, before, after, result) {
      result = "";
      while ((pos = index(value, prefix)) > 0) {
        before = (pos == 1 ? "" : substr(value, pos - 1, 1));
        after = substr(value, pos + length(prefix), 1);
        if ((pos == 1 || before ~ /[[:space:]"=]/) && (after == "" || after == "/" || after ~ /[[:space:]]/)) {
          result = result substr(value, 1, pos - 1) replacement;
          value = substr(value, pos + length(prefix));
        } else {
          result = result substr(value, 1, pos);
          value = substr(value, pos + 1);
        }
      }
      return result value;
    }
    BEGIN {
      text = replace_prefix(text, home_prefix, "~");
      text = replace_prefix(text, termux_prefix, "~/..");
      print text;
    }
  '
}

collect_agent_locations() {
  if [ -n "$TEST_LOCATION_FILE" ] && [ -r "$TEST_LOCATION_FILE" ]; then
    cat "$TEST_LOCATION_FILE"
    return
  fi
  if [ -n "$TEST_PS_FILE" ]; then
    return
  fi

  snapshot_lines | awk -v root_list="$AGENT_ROOT_LIST" '
    function trim(s) {
      sub(/^[[:space:]]+/, "", s);
      sub(/[[:space:]]+$/, "", s);
      return s;
    }
    function agent_kind_for(comm_val, args_val) {
      if (comm_val == "claude" || comm_val == "claude-exomind") return "claude";
      if (args_val ~ /(^|[[:space:]])[^[:space:]]*\/claude-exomind([[:space:]]|$)/) return "claude";
      if (args_val ~ /(^|[[:space:]])[^[:space:]]*@anthropic-ai\/claude-code\/bin\/claude([[:space:]]|$)/) return "claude";
      if (comm_val == "codex" || comm_val == "codex-exomind") return "codex";
      if ((comm_val == "MainThread" || comm_val == "node") && args_val ~ /(^|[[:space:]])[^[:space:]]*\/codex([[:space:]]|$)/) return "codex";
      return "";
    }
    function basename_path(path,    value, pos) {
      value = path;
      sub(/\/$/, "", value);
      pos = match(value, /[^\/]+$/);
      return pos == 0 ? "" : substr(value, RSTART, RLENGTH);
    }
    function dq_quote(text,    result, i, ch) {
      result = "\"";
      for (i = 1; i <= length(text); i++) {
        ch = substr(text, i, 1);
        if (ch == "\\" || ch == "\"" || ch == "$" || ch == "`") result = result "\\" ch;
        else result = result ch;
      }
      return result "\"";
    }
    function location_for(pid,    cmd, cwd, folder, branch) {
      if (pid in location_cache) return location_cache[pid];
      cmd = "readlink /proc/" pid "/cwd 2>/dev/null";
      cwd = "";
      if ((cmd | getline cwd) <= 0) {
        close(cmd);
        location_cache[pid] = "";
        return "";
      }
      close(cmd);
      cwd = trim(cwd);
      if (cwd == "") {
        location_cache[pid] = "";
        return "";
      }
      folder = basename_path(cwd);
      branch = "";
      cmd = "git -C " dq_quote(cwd) " symbolic-ref --short HEAD 2>/dev/null";
      if ((cmd | getline branch) > 0) branch = trim(branch);
      close(cmd);
      location_cache[pid] = branch != "" ? branch "@" folder : folder;
      return location_cache[pid];
    }
    BEGIN {
      root_count = split(root_list, root_names, " ");
      for (i = 1; i <= root_count; i++) root[root_names[i]] = 1;
    }
    {
      pid_val = $1;
      ppid_val = $2;
      comm_val = $6;
      $1 = ""; $2 = ""; $3 = ""; $4 = ""; $5 = ""; $6 = "";
      args_val = trim($0);
      ppid[pid_val] = ppid_val;
      comm[pid_val] = comm_val;
      kind[pid_val] = agent_kind_for(comm_val, args_val);
      if (kind[pid_val] != "" || root[comm_val]) roots[++root_count_seen] = pid_val;
    }
    END {
      for (i = 1; i <= root_count_seen; i++) {
        pid_val = roots[i];
        location = location_for(pid_val);
        if (location != "") printf "%s\t%s\n", pid_val, location;
      }
    }
  '
}

calculate_location_width() {
  printf '%s\n' "$FRAME_LOCATION_MAP" | awk -F '\t' '
    BEGIN { width = 7 }
    NF >= 2 {
      location = $2;
      at = index(location, "@");
      if (at > 0) {
        branch = substr(location, 1, at - 1);
        if (length(branch) + 5 > width) width = length(branch) + 5;
      } else if (length(location) > width) {
        width = length(location);
      }
    }
    END { print width }
  '
}

repeat_char() {
  char="$1"
  count="$2"
  awk -v char="$char" -v count="$count" 'BEGIN {
    for (i = 0; i < count; i++) {
      printf "%s", char;
    }
  }'
}

bar() {
  percent="$1"
  width="${2:-20}"
  awk -v percent="$percent" -v width="$width" 'BEGIN {
    filled = int((percent / 100.0) * width + 0.5);
    if (filled < 0) {
      filled = 0;
    }
    if (filled > width) {
      filled = width;
    }
    for (i = 0; i < filled; i++) {
      printf "█";
    }
    for (i = filled; i < width; i++) {
      printf "░";
    }
  }'
}

bar_color_code() {
  percent="$1"
  kind="$2"

  if [ "$STYLE_ENABLED" -eq 0 ]; then
    printf '%s' ""
    return
  fi

  awk -v percent="$percent" -v kind="$kind" -v green="$ANSI_BRIGHT_GREEN" -v yellow="$ANSI_BRIGHT_YELLOW" -v red="$ANSI_BRIGHT_RED" 'BEGIN {
    if (kind == "disk_availability") {
      if (percent < 5) {
        printf "%s", red;
      } else if (percent < 15) {
        printf "%s", yellow;
      } else {
        printf "%s", green;
      }
      exit;
    }

    if (kind == "availability") {
      if (percent < 20) {
        printf "%s", red;
      } else if (percent < 40) {
        printf "%s", yellow;
      } else {
        printf "%s", green;
      }
      exit;
    }

    if (percent >= 80) {
      printf "%s", red;
    } else if (percent >= 60) {
      printf "%s", yellow;
    } else {
      printf "%s", green;
    }
  }'
}

render_bar() {
  percent="$1"
  width="$2"
  kind="$3"
  bar_text=$(bar "$percent" "$width")

  if [ "$STYLE_ENABLED" -eq 1 ]; then
    color=$(bar_color_code "$percent" "$kind")
    printf '%s%s%s' "$color" "$bar_text" "$ANSI_RESET"
    return
  fi

  printf '%s' "$bar_text"
}

role_color_code() {
  role_kind="$1"

  if [ "$STYLE_ENABLED" -eq 0 ]; then
    printf '%s' ""
    return
  fi

  case "$role_kind" in
    claude)
      printf '%s' "$ANSI_BRIGHT_CLAUDE"
      ;;
    codex)
      printf '%s' "$ANSI_BRIGHT_CODEX"
      ;;
    *)
      printf '%s' ""
      ;;
  esac
}

task_color_code() {
  task_kind="$1"

  if [ "$STYLE_ENABLED" -eq 0 ]; then
    printf '%s' ""
    return
  fi

  case "$task_kind" in
    running)
      printf '%s' "$ANSI_BRIGHT_GREEN"
      ;;
    sleeping)
      printf '%s' "$ANSI_BRIGHT_ORANGE"
      ;;
    stopped)
      printf '%s' "$ANSI_BRIGHT_RED"
      ;;
    zombie)
      printf '%s' "$ANSI_GREEN"
      ;;
    *)
      printf '%s' ""
      ;;
  esac
}

render_colored_text() {
  text="$1"
  color="$2"

  if [ "$STYLE_ENABLED" -eq 1 ] && [ -n "$color" ]; then
    printf '%s%s%s' "$color" "$text" "$ANSI_RESET"
    return
  fi

  printf '%s' "$text"
}

risk_color_code() {
  risk_level="$1"

  if [ "$STYLE_ENABLED" -eq 0 ]; then
    printf '%s' ""
    return
  fi

  case "$risk_level" in
    OK)
      printf '%s' "$ANSI_BRIGHT_GREEN"
      ;;
    WARN)
      printf '%s' "$ANSI_BRIGHT_YELLOW"
      ;;
    HOT)
      printf '%s' "$ANSI_BRIGHT_ORANGE"
      ;;
    CRIT)
      printf '%s' "$ANSI_BRIGHT_RED"
      ;;
    *)
      printf '%s' ""
      ;;
  esac
}

render_risk_badge() {
  risk_level="$1"

  if [ "$STYLE_ENABLED" -eq 1 ]; then
    risk_color=$(risk_color_code "$risk_level")
    printf '%s%sRISK: %s%s' "$risk_color" "$ANSI_BOLD" "$risk_level" "$ANSI_NO_BOLD"
    return
  fi

  printf 'RISK: %s' "$risk_level"
}

render_metric_text() {
  percent="$1"
  kind="$2"
  suffix="${3:-}"
  color=$(bar_color_code "$percent" "$kind")
  render_colored_text "${percent}${suffix}" "$color"
}

render_metric_field() {
  value="$1"
  kind="$2"
  width="$3"
  padded_text=$(awk -v value="$value" -v width="$width" 'BEGIN { printf "%-*s", width, value }')
  color=$(bar_color_code "$value" "$kind")
  render_colored_text "$padded_text" "$color"
}

render_role_field() {
  role_kind="$1"
  role_text="$2"
  width="$3"
  if [ "$role_text" = "child" ]; then
    role_text="  child"
  fi
  padded_text=$(awk -v value="$role_text" -v width="$width" 'BEGIN { printf "%-*s", width, value }')
  color=$(role_color_code "$role_kind")
  render_colored_text "$padded_text" "$color"
}

render_text_field() {
  value="$1"
  width="$2"
  awk -v value="$value" -v width="$width" 'BEGIN { printf "%-*s", width, value }'
}

render_process_command_field() {
  value="$1"
  width="$2"
  awk -v value="$value" -v width="$width" 'BEGIN {
    if (width < 1) {
      exit;
    }
    if (length(value) > width) {
      if (width > 3) {
        value = substr(value, 1, width - 3) "...";
      } else {
        value = substr(value, 1, width);
      }
    }
    printf "%-*s", width, value;
  }'
}

render_process_location_field() {
  value="$1"
  width="$2"
  awk -v value="$value" -v width="$width" 'BEGIN {
    if (width < 1) {
      exit;
    }
    if (length(value) > width) {
      if (width > 3) {
        value = substr(value, 1, width - 3) "...";
      } else {
        value = substr(value, 1, width);
      }
    }
    printf "%-*s", width, value;
  }'
}

render_right_text_field() {
  value="$1"
  width="$2"
  awk -v value="$value" -v width="$width" 'BEGIN { printf "%*s", width, value }'
}

text_width() {
  value="$1"
  awk -v value="$value" 'BEGIN { print length(value) }'
}

render_resource_percent_field() {
  percent="$1"
  kind="$2"
  width="$3"
  padded_text=$(render_right_text_field "${percent}%" "$width")
  color=$(bar_color_code "$percent" "$kind")
  render_colored_text "$padded_text" "$color"
}

compute_resource_bar_width() {
  available_width="$1"
  reference_width="$2"
  fixed_width=$((RESOURCE_LABEL_WIDTH + 1 + RESOURCE_PERCENT_FIELD_WIDTH + 2 + available_width + 2 + reference_width))
  bar_width=$((PANEL_INNER_WIDTH - fixed_width))

  if [ "$bar_width" -gt "$RESOURCE_BAR_MAX_WIDTH" ]; then
    bar_width=$RESOURCE_BAR_MAX_WIDTH
  fi

  if [ "$bar_width" -lt 1 ]; then
    bar_width=1
  fi

  printf '%s\n' "$bar_width"
}

render_resource_line() {
  label="$1"
  percent="$2"
  kind="$3"
  available_text="$4"
  reference_text="$5"
  bar_width="$6"
  available_width="$7"
  label_field=$(render_text_field "$label" "$RESOURCE_LABEL_WIDTH")
  percent_field=$(render_resource_percent_field "$percent" "$kind" "$RESOURCE_PERCENT_FIELD_WIDTH")
  available_field=$(render_text_field "$available_text" "$available_width")
  render_single_panel_line "$label_field $(render_bar "$percent" "$bar_width" "$kind") $percent_field  $available_field  $reference_text"
}

render_composition_bar() {
  bar_width="$1"
  claude_percent="$2"
  codex_percent="$3"
  other_percent="$4"
  free_percent="$5"

  awk -v bar_width="$bar_width" \
    -v claude_percent="$claude_percent" \
    -v codex_percent="$codex_percent" \
    -v other_percent="$other_percent" \
    -v free_percent="$free_percent" \
    -v styled="$STYLE_ENABLED" \
    -v reverse="$ANSI_REVERSE" \
    -v ansi_claude="$ANSI_BRIGHT_CLAUDE" \
    -v ansi_codex="$ANSI_BRIGHT_CODEX" \
    -v ansi_other="$ANSI_BRIGHT_GREEN" \
    -v reset="$ANSI_RESET" '
    function clamp(value) {
      if (value < 0) return 0;
      if (value > 100) return 100;
      return value;
    }
    function style_segment(text, color, reverse_video) {
      if (styled != 1 || color == "") return text;
      if (reverse_video == 1) return color reverse text reset;
      return color text reset;
    }
    function segment_text(label, width, fill, color, reverse_video,    text, i, marker_text, fill_text) {
      if (width <= 0) return "";
      if (label == "|") {
        marker_text = style_segment(label, color, 1);
        if (width > 1) {
          fill_text = "";
          for (i = 2; i <= width; i++) fill_text = fill_text fill;
          return marker_text style_segment(fill_text, color, 0);
        }
        return marker_text;
      }
      if (label != "") {
        text = substr(label, 1, width);
        while (length(text) < width) {
          if (fill != "") text = text fill;
          else text = text " ";
        }
      } else {
        text = "";
        for (i = 1; i <= width; i++) text = text fill;
      }
      return style_segment(text, color, reverse_video);
    }
    BEGIN {
      values[1] = clamp(claude_percent + 0);
      values[2] = clamp(codex_percent + 0);
      values[3] = clamp(other_percent + 0);
      values[4] = clamp(free_percent + 0);
      total_percent = values[1] + values[2] + values[3] + values[4];
      if (total_percent <= 0) {
        values[4] = 100;
      } else if (total_percent != 100) {
        for (i = 1; i <= 4; i++) values[i] = values[i] * 100 / total_percent;
      }
      labels[1] = "claude";
      labels[2] = "codex";
      labels[3] = "|";
      labels[4] = "";
      fills[1] = "";
      fills[2] = "";
      fills[3] = "█";
      fills[4] = "░";
      colors[1] = ansi_claude;
      colors[2] = ansi_codex;
      colors[3] = ansi_other;
      colors[4] = "";
      reverse_video[1] = 1;
      reverse_video[2] = 1;
      reverse_video[3] = 0;
      reverse_video[4] = 0;

      total = 0;
      assigned = 0;
      for (i = 1; i <= 4; i++) {
        raw = values[i] * bar_width / 100.0;
        widths[i] = int(raw);
        remainders[i] = raw - widths[i];
        total += values[i];
        assigned += widths[i];
      }

      while (assigned < bar_width) {
        best = 1;
        for (i = 2; i <= 4; i++) {
          if (remainders[i] > remainders[best]) best = i;
        }
        widths[best]++;
        remainders[best] = -1;
        assigned++;
      }

      for (i = 1; i <= 2; i++) {
        if (values[i] > 0 && widths[i] == 0 && bar_width >= 2) {
          widths[i] = 1;
          assigned++;
        }
      }

      while (assigned > bar_width) {
        best = 0;
        for (i = 4; i >= 1; i--) {
          minimum = (i <= 2 && values[i] > 0 && bar_width >= 2) ? 1 : 0;
          if (widths[i] > minimum && (best == 0 || values[i] < values[best])) best = i;
        }
        if (best == 0) break;
        widths[best]--;
        assigned--;
      }

      while (assigned < bar_width) {
        best = 4;
        for (i = 3; i >= 1; i--) {
          if (values[i] > values[best]) best = i;
        }
        widths[best]++;
        assigned++;
      }

      result = "";
      for (i = 1; i <= 4; i++) result = result segment_text(labels[i], widths[i], fills[i], colors[i], reverse_video[i]);
      print result;
    }
  '
}

render_composition_line() {
  label="$1"
  metric_percent="$2"
  metric_kind="$3"
  available_text="$4"
  reference_text="$5"
  bar_width="$6"
  available_width="$7"
  claude_percent="$8"
  codex_percent="$9"
  other_percent="${10}"
  free_percent="${11}"
  label_field=$(render_text_field "$label" "$RESOURCE_LABEL_WIDTH")
  percent_field=$(render_resource_percent_field "$metric_percent" "$metric_kind" "$RESOURCE_PERCENT_FIELD_WIDTH")
  available_field=$(render_text_field "$available_text" "$available_width")
  composition_bar=$(render_composition_bar "$bar_width" "$claude_percent" "$codex_percent" "$other_percent" "$free_percent")
  render_single_panel_line "$label_field $composition_bar $percent_field  $available_field  $reference_text"
}

render_tasks_line() {
  tasks_total="$1"
  tasks_running="$2"
  tasks_sleeping="$3"
  tasks_stopped="$4"
  tasks_zombie="$5"
  tasks_label="Tasks:"
  tasks_total_text="$tasks_total total"
  label_width=$(text_width "$tasks_label")
  total_width=$(text_width "$tasks_total_text")
  tasks_bar_width=$((PANEL_INNER_WIDTH - label_width - 1 - 2 - total_width))

  if [ "$tasks_bar_width" -gt "$tasks_total" ]; then
    tasks_bar_width=$tasks_total
  fi

  if [ "$tasks_bar_width" -lt 0 ]; then
    tasks_bar_width=0
  fi

  if [ "$tasks_bar_width" -eq 0 ]; then
    render_single_panel_line "$tasks_label  $tasks_total_text"
    return
  fi

  task_widths=$(
    awk -v total="$tasks_total" -v bar_width="$tasks_bar_width" -v running="$tasks_running" -v sleeping="$tasks_sleeping" -v stopped="$tasks_stopped" -v zombie="$tasks_zombie" 'BEGIN {
      counts[1] = running;
      counts[2] = sleeping;
      counts[3] = stopped;
      counts[4] = zombie;

      if (total <= 0 || bar_width <= 0) {
        print "0 0 0 0";
        exit;
      }

      assigned = 0;
      for (i = 1; i <= 4; i++) {
        raw = counts[i] * bar_width / total;
        widths[i] = int(raw);
        remainders[i] = raw - widths[i];
        assigned += widths[i];
      }

      while (assigned < bar_width) {
        best = 1;
        for (i = 2; i <= 4; i++) {
          if (remainders[i] > remainders[best]) {
            best = i;
          }
        }
        widths[best]++;
        remainders[best] = -1;
        assigned++;
      }

      printf "%d %d %d %d\n", widths[1], widths[2], widths[3], widths[4];
    }'
  )
  set -- $task_widths
  running_width="${1:-0}"
  sleeping_width="${2:-0}"
  stopped_width="${3:-0}"
  zombie_width="${4:-0}"
  tasks_bar=""

  for task_kind in running sleeping stopped zombie; do
    case "$task_kind" in
      running)
        segment_width="$running_width"
        segment_label="running"
        ;;
      sleeping)
        segment_width="$sleeping_width"
        segment_label="sleeping"
        ;;
      stopped)
        segment_width="$stopped_width"
        segment_label="stopped"
        ;;
      zombie)
        segment_width="$zombie_width"
        segment_label="zombie"
        ;;
    esac

    if [ "$segment_width" -le 0 ]; then
      continue
    fi

    segment_text=$(
      awk -v value="$segment_label" -v width="$segment_width" 'BEGIN {
        text = value;
        if (length(text) > width) {
          text = substr(text, 1, width);
        }
        printf "%-" width "s", text;
      }'
    )

    if [ "$STYLE_ENABLED" -eq 1 ]; then
      tasks_bar="${tasks_bar}$(printf '%s%s%s%s' "$(task_color_code "$task_kind")" "$ANSI_REVERSE" "$segment_text" "$ANSI_RESET")"
    else
      tasks_bar="${tasks_bar}${segment_text}"
    fi
  done

  render_single_panel_line "$tasks_label $tasks_bar  $tasks_total_text"
}

to_mib() {
  kib="$1"
  awk -v kib="$kib" 'BEGIN { printf "%.1f", kib / 1024.0 }'
}

safe_percent() {
  numerator="$1"
  denominator="$2"
  awk -v numerator="$numerator" -v denominator="$denominator" 'BEGIN {
    if (denominator <= 0) {
      printf "0.0";
    } else {
      printf "%.1f", (numerator / denominator) * 100.0;
    }
  }'
}

parse_agent_roots() {
  input="$1"
  if [ -z "$input" ]; then
    input="claude,codex"
  fi
  printf '%s' "$input" | awk -F',' '
    function trim(s) {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", s);
      return s;
    }
    {
      for (i = 1; i <= NF; i++) {
        value = trim($i);
        if (value != "" && !seen[value]++) {
          roots[count++] = value;
        }
      }
    }
    END {
      if (count == 0) {
        split("claude,codex", fallback, ",");
        for (i = 1; i <= 2; i++) {
          value = fallback[i];
          if (!seen[value]++) {
            roots[count++] = value;
          }
        }
      }
      for (i = 0; i < count; i++) {
        printf "%s%s", roots[i], (i + 1 < count ? " " : "");
      }
    }'
}

agent_root_in_list() {
  target="$1"
  for root in $AGENT_ROOT_LIST; do
    if [ "$root" = "$target" ]; then
      return 0
    fi
  done
  return 1
}

parse_cpu_list_count() {
  list="$1"
  awk -v list="$list" 'BEGIN {
    gsub(/[[:space:]]+/, "", list);
    if (list == "") {
      print 0;
      exit;
    }
    n = split(list, parts, ",");
    total = 0;
    for (i = 1; i <= n; i++) {
      if (parts[i] ~ /^[0-9]+-[0-9]+$/) {
        split(parts[i], range, "-");
        start = range[1] + 0;
        end = range[2] + 0;
        if (end >= start) {
          total += (end - start + 1);
        }
      } else if (parts[i] ~ /^[0-9]+$/) {
        total += 1;
      }
    }
    print total + 0;
  }'
}

detect_cpu_count() {
  if is_fixture_mode; then
    printf '%s' 2
    return
  fi

  if [ -r /proc/self/status ]; then
    list=$(awk -F':' '/^Cpus_allowed_list:/ { gsub(/^[[:space:]]+/, "", $2); print $2; exit }' /proc/self/status)
    if [ -n "$list" ]; then
      count=$(parse_cpu_list_count "$list")
      if [ "$count" -gt 0 ] 2>/dev/null; then
        printf '%s' "$count"
        return
      fi
    fi
  fi

  if [ -r /sys/devices/system/cpu/online ]; then
    list=$(cat /sys/devices/system/cpu/online 2>/dev/null || :)
    if [ -n "$list" ]; then
      count=$(parse_cpu_list_count "$list")
      if [ "$count" -gt 0 ] 2>/dev/null; then
        printf '%s' "$count"
        return
      fi
    fi
  fi

  if command -v nproc >/dev/null 2>&1; then
    count=$(nproc 2>/dev/null || :)
    if [ -n "$count" ] && [ "$count" -gt 0 ] 2>/dev/null; then
      printf '%s' "$count"
      return
    fi
  fi

  printf '1'
}

determine_risk_level() {
  awk -v mem_available_kb="$MEM_AVAILABLE_KB" -v data_free_percent="$DATA_FREE_PERCENT" -v agent_cpu_percent="${AGENT_CPU_PERCENT:-0}" 'BEGIN {
    severity = 0;

    if (mem_available_kb < 1572864 || data_free_percent < 15) {
      severity = 1;
    }
    if (mem_available_kb < 768000 || agent_cpu_percent > 100) {
      severity = 2;
    }
    if (mem_available_kb < 512000 || data_free_percent < 5 || agent_cpu_percent > 200) {
      severity = 3;
    }

    if (severity == 3) {
      print "CRIT";
      exit;
    }
    if (severity == 2) {
      print "HOT";
      exit;
    }
    if (severity == 1) {
      print "WARN";
      exit;
    }
    print "OK";
  }'
}

build_title_layout() {
  width="$1"
  left_text="$2"
  fps_text="$3"
  risk_text="$4"

  awk -v width="$width" -v left="$left_text" -v fps="$fps_text" -v risk="$risk_text" 'BEGIN {
    gap = "  ";
    right = fps gap risk;

    if (length(right) >= width) {
      if (length(risk) >= width) {
        if (width > 3) {
          risk = substr(risk, 1, width - 3) "...";
        } else {
          risk = substr(risk, 1, width);
        }
        fps = "";
        gap = "";
      } else {
        fps_width = width - length(risk) - length(gap);
        if (fps_width <= 0) {
          fps = "";
          gap = "";
        } else if (length(fps) > fps_width) {
          if (fps_width > 3) {
            fps = substr(fps, 1, fps_width - 3) "...";
          } else {
            fps = substr(fps, 1, fps_width);
          }
        }
      }
      right = fps;
      if (fps != "" && risk != "") {
        right = right gap risk;
      } else if (risk != "") {
        right = risk;
      }
    }

    available = width - length(right);
    left_display = "";
    if (available > length(gap)) {
      left_width = available - length(gap);
      left_display = left;
      if (length(left_display) > left_width) {
        if (left_width > 3) {
          left_display = substr(left_display, 1, left_width - 3) "...";
        } else {
          left_display = substr(left_display, 1, left_width);
        }
      }
    }

    left_padding = left_display;
    if (left_display != "" && right != "") {
      left_padding = left_display gap;
    }

    padding = width - length(left_padding) - length(right);
    if (padding < 0) {
      padding = 0;
    }

    printf "%s\t%d\t%s\t%s\n", left_display, padding, fps, risk;
  }'
}

render_bold_title_text() {
  text="$1"
  title_label="TERMUX SYSTEM SNAPSHOT"

  if [ "$STYLE_ENABLED" -eq 0 ]; then
    printf '%s' "$text"
    return
  fi

  case "$text" in
    "$title_label"*)
      printf '%s%s%s%s' "$ANSI_BOLD" "$title_label" "$ANSI_NO_BOLD" "${text#"$title_label"}"
      ;;
    *)
      printf '%s%s%s' "$ANSI_BOLD" "$text" "$ANSI_NO_BOLD"
      ;;
  esac
}

clip_frame_to_terminal_height() {
  frame_text="$1"

  case "$PANEL_HEIGHT" in
    ''|*[!0-9]*|0)
      printf '%s' "$frame_text"
      return
      ;;
  esac

  printf '%s\n' "$frame_text" | awk -v max_rows="$PANEL_HEIGHT" -v focus="$TREE_FOCUS" -v styled="$STYLE_ENABLED" '
    { lines[NR]=$0; if ($0 ~ /^PID[[:space:]]+PPID/) header=NR }
    END {
      if (!header || NR <= max_rows) {
        for (i=1; i<=NR && i<=max_rows; i++) print lines[i];
        exit;
      }
      footer=(lines[NR] ~ /^\+/ ? 1 : 0);
      visible=max_rows-header-footer;
      if (visible < 1) {
        for (i=1; i<=max_rows; i++) print lines[i];
        exit;
      }
      total=NR-header-footer;
      if (focus >= total) focus=total-1;
      if (focus < 0) focus=0;
      start=focus-visible+1;
      if (start < 0) start=0;
      for (i=1; i<=header; i++) print lines[i];
      for (i=start; i<total && i<start+visible; i++) {
        line=lines[header+1+i];
        if (styled && i == focus) printf "\033[7m%s\033[27m\n", line;
        else print line;
      }
      if (footer) print lines[NR];
    }'
}

clamp_tree_focus() {
  frame_text=$1
  last_index=$(printf '%s\n' "$frame_text" | awk '
    /^PID[[:space:]]+PPID/ { header=NR }
    END { footer=($0 ~ /^\+/ ? 1 : 0); count=NR-header-footer; if (!header || count < 1) count=1; print count-1 }
  ')
  if [ "$TREE_FOCUS" -gt "$last_index" ]; then TREE_FOCUS=$last_index; fi
}

sleep_until_refresh() {
  interval="$1"

  if awk -v interval="$interval" 'BEGIN { exit !(interval <= 0) }'; then
    return
  fi

  remaining="$interval"
  while awk -v remaining="$remaining" 'BEGIN { exit !(remaining > 0) }'; do
    if [ "$RESIZE_PENDING" -eq 1 ]; then
      return
    fi

    sleep_chunk=$(awk -v remaining="$remaining" 'BEGIN {
      if (remaining > 0.1) {
        print "0.1";
      } else {
        printf "%.3f", remaining;
      }
    }')

    sleep "$sleep_chunk" || :
    remaining=$(awk -v remaining="$remaining" -v chunk="$sleep_chunk" 'BEGIN {
      next_value = remaining - chunk;
      if (next_value < 0) {
        next_value = 0;
      }
      printf "%.3f", next_value;
    }')
  done
}

set_status_message() {
  STATUS_MESSAGE="$1"
  STATUS_TTL="$STATUS_TTL_FRAMES"
}

tick_status_message() {
  if [ "${STATUS_TTL:-0}" -le 0 ]; then
    return
  fi

  STATUS_TTL=$((STATUS_TTL - 1))
  if [ "$STATUS_TTL" -le 0 ]; then
    STATUS_TTL=0
    STATUS_MESSAGE=""
  fi
}

tty_input_available() {
  tty >/dev/null 2>&1
}

configure_live_input() {
  if [ "$RUN_ONCE" -eq 1 ] || ! tty_input_available; then
    return
  fi

  TTY_STATE=$(stty -g </dev/tty 2>/dev/null || :)
  if [ -z "$TTY_STATE" ]; then
    return
  fi

  if stty -icanon -echo min 0 time 0 </dev/tty 2>/dev/null; then
    TTY_INPUT_READY=1
  else
    TTY_STATE=""
  fi
}

restore_live_input() {
  if [ "$TTY_INPUT_READY" -eq 1 ] && [ -n "$TTY_STATE" ] && tty_input_available; then
    stty "$TTY_STATE" </dev/tty 2>/dev/null || :
  fi

  TTY_INPUT_READY=0
  TTY_STATE=""
}

read_live_keypress() {
  if [ "$TTY_INPUT_READY" -ne 1 ]; then
    return
  fi

  key=$(dd bs=1 count=1 iflag=nonblock if=/dev/tty 2>/dev/null || :)
  if [ "$key" = "$(printf '\033')" ]; then
    tail=$(dd bs=1 count=2 iflag=nonblock if=/dev/tty 2>/dev/null || :)
    printf '%s%s' "$key" "$tail"
  else
    printf '%s' "$key"
  fi
}

format_target_label() {
  pid="$1"
  command_name="$2"
  printf '%s[%s]' "$command_name" "$pid"
}

select_hotkey_target() {
  case "$TEST_MODE" in
    hotkey_kill|hotkey_kill_fail)
      printf '4002\t87.5\trustc\n'
      return
      ;;
    hotkey_no_target)
      return
      ;;
  esac

  root_list=$(parse_agent_roots "${AGENT_TOP_ROOTS:-}")

  process_snapshot | awk -v monitor_pid="$MONITOR_PID" -v root_list="$root_list" '
    function trim(s) {
      sub(/^[[:space:]]+/, "", s);
      sub(/[[:space:]]+$/, "", s);
      return s;
    }
    function agent_kind_for(comm_val, args_val) {
      if (comm_val == "claude" || comm_val == "claude-exomind") return "claude";
      if (args_val ~ /(^|[[:space:]])[^[:space:]]*\/claude-exomind([[:space:]]|$)/) return "claude";
      if (comm_val == "codex" || comm_val == "codex-exomind") return "codex";
      if (args_val ~ /(^|[[:space:]])[^[:space:]]*@anthropic-ai\/claude-code\/bin\/claude([[:space:]]|$)/) return "claude";
      if ((comm_val == "MainThread" || comm_val == "node") && args_val ~ /(^|[[:space:]])[^[:space:]]*\/codex([[:space:]]|$)/) return "codex";
      return "";
    }
    function is_agent_root(pid) {
      return kind[pid] != "" || root[comm[pid]] == 1;
    }
    function mark_hidden_chain(pid) {
      while (pid != "" && pid != 0 && !is_agent_root(pid) && !hidden[pid]) {
        hidden[pid] = 1;
        pid = ppid[pid];
      }
    }
    function mark_hidden_descendants(pid, child_ids, n, i, child_pid) {
      hidden[pid] = 1;

      n = split(children[pid], child_ids, " ");
      for (i = 1; i <= n; i++) {
        child_pid = child_ids[i];
        if (child_pid != "" && !hidden[child_pid]) {
          mark_hidden_descendants(child_pid);
        }
      }
    }
    function scan_descendants(pid, depth, child_ids, n, i, child_pid, cpu_val) {
      if (hidden[pid]) {
        return;
      }

      if (depth > 0) {
        cpu_val = cpu[pid] + 0;
        if (!found || cpu_val > best_cpu) {
          found = 1;
          best_pid = pid;
          best_cpu = cpu_val;
          best_comm = comm[pid];
        }
      }

      n = split(children[pid], child_ids, " ");
      for (i = 1; i <= n; i++) {
        child_pid = child_ids[i];
        if (child_pid != "") {
          scan_descendants(child_pid, depth + 1);
        }
      }
    }
    BEGIN {
      root_count = split(root_list, root_names, " ");
      for (i = 1; i <= root_count; i++) {
        root[root_names[i]] = 1;
      }
    }
    {
      pid_val = $1;
      ppid_val = $2;
      cpu_val = $4;
      comm_val = $6;

      $1 = ""; $2 = ""; $3 = ""; $4 = ""; $5 = ""; $6 = "";
      args_val = trim($0);

      pid[pid_val] = pid_val;
      ppid[pid_val] = ppid_val;
      cpu[pid_val] = cpu_val + 0;
      comm[pid_val] = comm_val;
      args[pid_val] = args_val;
      kind[pid_val] = agent_kind_for(comm_val, args_val);
      children[ppid_val] = children[ppid_val] " " pid_val;

      if (kind[pid_val] != "" || root[comm_val] || comm_val == "tmux") {
        root_order[++root_pid_count] = pid_val;
      }
    }
    END {
      mark_hidden_chain(monitor_pid);
      mark_hidden_descendants(monitor_pid);

      for (i = 1; i <= root_pid_count; i++) {
        pid_val = root_order[i];
        if (!hidden[pid_val]) {
          scan_descendants(pid_val, 0);
        }
      }

      if (found) {
        printf "%s\t%.1f\t%s\n", best_pid, best_cpu, best_comm;
      }
    }
  '
}

select_hotkey_targets() {
  case "$TEST_MODE" in
    hotkey_kill_all|hotkey_kill_all_partial_fail)
      printf '4002\trustc\n4003\tnode\n'
      return
      ;;
    hotkey_kill_all_no_target)
      return
      ;;
  esac

  root_list=$(parse_agent_roots "${AGENT_TOP_ROOTS:-}")

  process_snapshot | awk -v monitor_pid="$MONITOR_PID" -v root_list="$root_list" '
    function trim(s) {
      sub(/^[[:space:]]+/, "", s);
      sub(/[[:space:]]+$/, "", s);
      return s;
    }
    function agent_kind_for(comm_val, args_val) {
      if (comm_val == "claude" || comm_val == "claude-exomind") return "claude";
      if (args_val ~ /(^|[[:space:]])[^[:space:]]*\/claude-exomind([[:space:]]|$)/) return "claude";
      if (comm_val == "codex" || comm_val == "codex-exomind") return "codex";
      if (args_val ~ /(^|[[:space:]])[^[:space:]]*@anthropic-ai\/claude-code\/bin\/claude([[:space:]]|$)/) return "claude";
      if ((comm_val == "MainThread" || comm_val == "node") && args_val ~ /(^|[[:space:]])[^[:space:]]*\/codex([[:space:]]|$)/) return "codex";
      return "";
    }
    function is_agent_root(pid) {
      return kind[pid] != "" || root[comm[pid]] == 1;
    }
    function mark_hidden_chain(pid) {
      while (pid != "" && pid != 0 && !is_agent_root(pid) && !hidden[pid]) {
        hidden[pid] = 1;
        pid = ppid[pid];
      }
    }
    function mark_hidden_descendants(pid, child_ids, n, i, child_pid) {
      hidden[pid] = 1;

      n = split(children[pid], child_ids, " ");
      for (i = 1; i <= n; i++) {
        child_pid = child_ids[i];
        if (child_pid != "" && !hidden[child_pid]) {
          mark_hidden_descendants(child_pid);
        }
      }
    }
    function emit_descendants(pid, depth, child_ids, n, i, child_pid) {
      if (hidden[pid]) {
        return;
      }

      if (depth > 0 && !is_agent_root(pid)) {
        printf "%s\t%s\n", pid, comm[pid];
      }

      n = split(children[pid], child_ids, " ");
      for (i = 1; i <= n; i++) {
        child_pid = child_ids[i];
        if (child_pid != "") {
          emit_descendants(child_pid, depth + 1);
        }
      }
    }
    BEGIN {
      root_count = split(root_list, root_names, " ");
      for (i = 1; i <= root_count; i++) {
        root[root_names[i]] = 1;
      }
    }
    {
      pid_val = $1;
      ppid_val = $2;
      comm_val = $6;
      $1 = ""; $2 = ""; $3 = ""; $4 = ""; $5 = ""; $6 = "";
      args_val = trim($0);

      pid[pid_val] = pid_val;
      ppid[pid_val] = ppid_val;
      comm[pid_val] = comm_val;
      kind[pid_val] = agent_kind_for(comm_val, args_val);
      children[ppid_val] = children[ppid_val] " " pid_val;

      if (kind[pid_val] != "" || root[comm_val]) {
        root_order[++root_pid_count] = pid_val;
      }
    }
    END {
      mark_hidden_chain(monitor_pid);
      mark_hidden_descendants(monitor_pid);

      for (i = 1; i <= root_pid_count; i++) {
        pid_val = root_order[i];
        if (!hidden[pid_val]) {
          emit_descendants(pid_val, 0);
        }
      }
    }
  '
}

execute_hotkey_kill() {
  pid="$1"

  if [ -n "$TEST_KILL_LOG" ]; then
    printf -- '-9 %s\n' "$pid" >>"$TEST_KILL_LOG"
  fi

  case "$TEST_MODE" in
    hotkey_kill)
      return 0
      ;;
    hotkey_kill_fail)
      return 1
      ;;
    hotkey_kill_all)
      return 0
      ;;
    hotkey_kill_all_partial_fail)
      if [ "$pid" = "4003" ]; then
        return 1
      fi
      return 0
      ;;
  esac

  kill -9 "$pid" 2>/dev/null
}

perform_hotkey_kill() {
  now=$(date +%s)
  if [ -n "$ARMED_PID" ] && [ "$now" -le "$ARMED_UNTIL" ]; then
    armed_pid=$ARMED_PID
    armed_cpu=$ARMED_CPU
    armed_command=$ARMED_COMMAND
    ARMED_PID=""
    if is_armed_target_eligible "$armed_pid"; then
      armed_label=$(format_target_label "$armed_pid" "$armed_command")
      if execute_hotkey_kill "$armed_pid"; then
        set_status_message "KILLED $armed_label ($armed_cpu%)"
      else
        set_status_message "KILL FAILED $armed_label"
      fi
      return
    fi
    rearming=1
  else
    ARMED_PID=""
    rearming=0
  fi
  target=$(select_hotkey_target)
  if [ -z "$target" ]; then
    set_status_message "NO TARGET"
    return
  fi

  IFS='	' read -r target_pid target_cpu target_command <<EOF
$target
EOF

  target_label=$(format_target_label "$target_pid" "$target_command")
  ARMED_PID=$target_pid
  ARMED_CPU=$target_cpu
  ARMED_COMMAND=$target_command
  ARMED_UNTIL=$((now + 5))
  if [ "$rearming" -eq 1 ]; then
    set_status_message "REARMED: press k again to kill $target_label ($target_cpu%)"
  else
    set_status_message "ARMED: press k again to kill $target_label ($target_cpu%)"
  fi
}

is_armed_target_eligible() {
  case "$TEST_MODE" in
    hotkey_kill|hotkey_kill_fail) return 0 ;;
  esac
  select_hotkey_targets | awk -F '\t' -v target_pid="$1" -v target_command="$ARMED_COMMAND" '$1 == target_pid && $2 == target_command { found=1 } END { exit !found }'
}

perform_hotkey_kill_all() {
  ARMED_PID=""
  targets=$(select_hotkey_targets)
  if [ -z "$targets" ]; then
    set_status_message "NO TARGET"
    return
  fi

  total_count=0
  success_count=0
  while IFS='	' read -r target_pid target_command; do
    if [ -z "$target_pid" ]; then
      continue
    fi
    total_count=$((total_count + 1))
    if execute_hotkey_kill "$target_pid"; then
      success_count=$((success_count + 1))
    fi
  done <<EOF
$targets
EOF

  if [ "$success_count" -eq "$total_count" ]; then
    set_status_message "KILLED ALL $total_count CHILDREN"
  else
    set_status_message "KILLED $success_count/$total_count CHILDREN"
  fi
}

handle_live_keypress() {
  key="$1"

  case "$key" in
    k)
      perform_hotkey_kill
      ;;
    "$CTRL_K_CHAR")
      perform_hotkey_kill_all
      ;;
    j|"$(printf '\033[B')") TREE_FOCUS=$((TREE_FOCUS + 1)) ;;
    u|"$(printf '\033[A')")
      if [ "$TREE_FOCUS" -gt 0 ]; then TREE_FOCUS=$((TREE_FOCUS - 1)); fi
      ;;
    g) TREE_FOCUS=0 ;;
    G) TREE_FOCUS=999999 ;;
    q) EXIT_REQUESTED=1 ;;
  esac
}

process_live_input() {
  key=$(read_live_keypress)
  if [ -n "$key" ]; then
    handle_live_keypress "$key"
  fi
}

collect_global_cpu() {
  if is_fixture_mode && [ -z "$TEST_PS_FILE" ]; then
    GLOBAL_CPU_RAW_PERCENT=84.0
    GLOBAL_CPU_PERCENT=42.0
    return
  fi
  GLOBAL_CPU_RAW_PERCENT=$(snapshot_lines | awk '{ total += $4 } END { if (total < 0) total=0; printf "%.1f", total }')
  GLOBAL_CPU_PERCENT=$(awk -v raw="$GLOBAL_CPU_RAW_PERCENT" -v cpu_count="$CPU_COUNT" 'BEGIN {
    if (cpu_count <= 0) cpu_count = 1;
    value = raw / cpu_count;
    if (value < 0) value = 0;
    if (value > 100) value = 100;
    printf "%.1f", value;
  }')
}
collect_system_metrics() {
  case "$TEST_MODE" in
    diff|diff_title|resize|risk_cpu_hot|risk_cpu_crit|hotkey_kill|hotkey_no_target|hotkey_kill_fail|hotkey_kill_all|hotkey_kill_all_no_target|hotkey_kill_all_partial_fail)
      MEM_TOTAL_KB=4194304
      MEM_FREE_KB=1048576
      MEM_AVAILABLE_KB=2097152
      BUFFERS_KB=65536
      CACHED_KB=524288
      SWAP_TOTAL_KB=2097152
      SWAP_FREE_KB=1048576
      DATA_BLOCKS=4194304
      DATA_USED_BLOCKS=1048576
      DATA_AVAILABLE_BLOCKS=3145728
      DATA_USED_PERCENT=25
      DATA_FREE_PERCENT=75.0
      MEM_AVAILABLE_PERCENT=50.0
      SWAP_USED_KB=1048576
      SWAP_FREE_PERCENT=50.0
      RISK_LEVEL=$(determine_risk_level)
      return
      ;;
    risk_warn)
      MEM_TOTAL_KB=4194304
      MEM_FREE_KB=1048576
      MEM_AVAILABLE_KB=1310720
      BUFFERS_KB=65536
      CACHED_KB=524288
      SWAP_TOTAL_KB=2097152
      SWAP_FREE_KB=1048576
      DATA_BLOCKS=4194304
      DATA_USED_BLOCKS=1048576
      DATA_AVAILABLE_BLOCKS=3145728
      DATA_USED_PERCENT=25
      DATA_FREE_PERCENT=75.0
      MEM_AVAILABLE_PERCENT=31.2
      SWAP_USED_KB=1048576
      SWAP_FREE_PERCENT=50.0
      RISK_LEVEL=$(determine_risk_level)
      return
      ;;
    risk_hot)
      MEM_TOTAL_KB=4194304
      MEM_FREE_KB=1048576
      MEM_AVAILABLE_KB=716800
      BUFFERS_KB=65536
      CACHED_KB=524288
      SWAP_TOTAL_KB=2097152
      SWAP_FREE_KB=1048576
      DATA_BLOCKS=4194304
      DATA_USED_BLOCKS=1048576
      DATA_AVAILABLE_BLOCKS=3145728
      DATA_USED_PERCENT=25
      DATA_FREE_PERCENT=75.0
      MEM_AVAILABLE_PERCENT=17.1
      SWAP_USED_KB=1048576
      SWAP_FREE_PERCENT=50.0
      RISK_LEVEL=$(determine_risk_level)
      return
      ;;
    risk_crit)
      MEM_TOTAL_KB=4194304
      MEM_FREE_KB=1048576
      MEM_AVAILABLE_KB=409600
      BUFFERS_KB=65536
      CACHED_KB=524288
      SWAP_TOTAL_KB=2097152
      SWAP_FREE_KB=1048576
      DATA_BLOCKS=4194304
      DATA_USED_BLOCKS=1048576
      DATA_AVAILABLE_BLOCKS=3145728
      DATA_USED_PERCENT=25
      DATA_FREE_PERCENT=75.0
      MEM_AVAILABLE_PERCENT=9.8
      SWAP_USED_KB=1048576
      SWAP_FREE_PERCENT=50.0
      RISK_LEVEL=$(determine_risk_level)
      return
      ;;
    disk_warn)
      MEM_TOTAL_KB=4194304
      MEM_FREE_KB=1048576
      MEM_AVAILABLE_KB=2097152
      BUFFERS_KB=65536
      CACHED_KB=524288
      SWAP_TOTAL_KB=2097152
      SWAP_FREE_KB=1048576
      DATA_BLOCKS=4194304
      DATA_USED_BLOCKS=3607102
      DATA_AVAILABLE_BLOCKS=587202
      DATA_USED_PERCENT=86
      DATA_FREE_PERCENT=14.0
      MEM_AVAILABLE_PERCENT=50.0
      SWAP_USED_KB=1048576
      SWAP_FREE_PERCENT=50.0
      RISK_LEVEL=$(determine_risk_level)
      return
      ;;
    disk_hot)
      MEM_TOTAL_KB=4194304
      MEM_FREE_KB=1048576
      MEM_AVAILABLE_KB=2097152
      BUFFERS_KB=65536
      CACHED_KB=524288
      SWAP_TOTAL_KB=2097152
      SWAP_FREE_KB=1048576
      DATA_BLOCKS=4194304
      DATA_USED_BLOCKS=4026532
      DATA_AVAILABLE_BLOCKS=167772
      DATA_USED_PERCENT=96
      DATA_FREE_PERCENT=4.0
      MEM_AVAILABLE_PERCENT=50.0
      SWAP_USED_KB=1048576
      SWAP_FREE_PERCENT=50.0
      RISK_LEVEL=$(determine_risk_level)
      return
      ;;
  esac

  eval "$(
    awk '
      /MemTotal:/ { print "MEM_TOTAL_KB=" $2 }
      /MemFree:/ { print "MEM_FREE_KB=" $2 }
      /MemAvailable:/ { print "MEM_AVAILABLE_KB=" $2 }
      /^Buffers:/ { print "BUFFERS_KB=" $2 }
      /^Cached:/ { print "CACHED_KB=" $2 }
      /SwapTotal:/ { print "SWAP_TOTAL_KB=" $2 }
      /SwapFree:/ { print "SWAP_FREE_KB=" $2 }
    ' /proc/meminfo
  )"

  DATA_DF_LINE=$(df -P /data | awk 'NR == 2 { print $2 " " $3 " " $4 " " $5 }')
  DATA_BLOCKS=$(printf '%s\n' "$DATA_DF_LINE" | awk '{ print $1 }')
  DATA_USED_BLOCKS=$(printf '%s\n' "$DATA_DF_LINE" | awk '{ print $2 }')
  DATA_AVAILABLE_BLOCKS=$(printf '%s\n' "$DATA_DF_LINE" | awk '{ print $3 }')
  DATA_USED_PERCENT=$(printf '%s\n' "$DATA_DF_LINE" | awk '{ gsub(/%/, "", $4); print $4 }')
  DATA_FREE_PERCENT=$(safe_percent "$DATA_AVAILABLE_BLOCKS" "$DATA_BLOCKS")

  MEM_AVAILABLE_PERCENT=$(safe_percent "$MEM_AVAILABLE_KB" "$MEM_TOTAL_KB")
  SWAP_USED_KB=$((SWAP_TOTAL_KB - SWAP_FREE_KB))
  SWAP_FREE_PERCENT=$(safe_percent "$SWAP_FREE_KB" "$SWAP_TOTAL_KB")
  RISK_LEVEL=$(determine_risk_level)
}

collect_agent_rollup() {
  if is_fixture_mode && [ -z "$TEST_PS_FILE" ]; then
    if [ "$LOOP_ITERATION" -le 1 ]; then
      claude_root_count=1
      claude_root_rss_kb=131072
      claude_child_count=1
      claude_child_rss_kb=4096
      codex_root_count=1
      codex_root_rss_kb=196608
      codex_child_count=1
      codex_child_rss_kb=5120
    else
      claude_root_count=2
      claude_root_rss_kb=262144
      claude_child_count=1
      claude_child_rss_kb=4096
      codex_root_count=1
      codex_root_rss_kb=196608
      codex_child_count=1
      codex_child_rss_kb=5120
    fi
    AGENT_ROOT_SUMMARY=""
    AGENT_CPU_PERCENT=0.0
    AGENT_TOTAL_RSS_KB=0
    CLAUDE_ROOT_COUNT=0
    CLAUDE_CHILD_COUNT=0
    CLAUDE_ROOT_RSS_KB=0
    CLAUDE_CHILD_RSS_KB=0
    CLAUDE_CPU_PERCENT=0.0
    CLAUDE_RSS_KB=0
    CODEX_ROOT_COUNT=0
    CODEX_CHILD_COUNT=0
    CODEX_ROOT_RSS_KB=0
    CODEX_CHILD_RSS_KB=0
    CODEX_CPU_PERCENT=0.0
    CODEX_RSS_KB=0
    for root in $AGENT_ROOT_LIST; do
      case "$root" in
        claude)
          CLAUDE_ROOT_COUNT=$claude_root_count
          CLAUDE_CHILD_COUNT=$claude_child_count
          CLAUDE_ROOT_RSS_KB=$claude_root_rss_kb
          CLAUDE_CHILD_RSS_KB=$claude_child_rss_kb
          CLAUDE_CPU_PERCENT=55.0
          CLAUDE_RSS_KB=$((claude_root_rss_kb + claude_child_rss_kb))
          AGENT_CPU_PERCENT=$(awk -v cpu="$AGENT_CPU_PERCENT" -v claude="$CLAUDE_CPU_PERCENT" 'BEGIN { printf "%.1f", cpu + claude }')
          AGENT_TOTAL_RSS_KB=$((AGENT_TOTAL_RSS_KB + CLAUDE_RSS_KB))
          AGENT_ROOT_SUMMARY="${AGENT_ROOT_SUMMARY}${AGENT_ROOT_SUMMARY:+ }claude:${CLAUDE_ROOT_COUNT}:${CLAUDE_CHILD_COUNT}:${CLAUDE_ROOT_RSS_KB}:${CLAUDE_CHILD_RSS_KB}:${CLAUDE_CPU_PERCENT}"
          ;;
        codex)
          CODEX_ROOT_COUNT=$codex_root_count
          CODEX_CHILD_COUNT=$codex_child_count
          CODEX_ROOT_RSS_KB=$codex_root_rss_kb
          CODEX_CHILD_RSS_KB=$codex_child_rss_kb
          CODEX_CPU_PERCENT=0.0
          CODEX_RSS_KB=$((codex_root_rss_kb + codex_child_rss_kb))
          AGENT_TOTAL_RSS_KB=$((AGENT_TOTAL_RSS_KB + CODEX_RSS_KB))
          AGENT_ROOT_SUMMARY="${AGENT_ROOT_SUMMARY}${AGENT_ROOT_SUMMARY:+ }codex:${CODEX_ROOT_COUNT}:${CODEX_CHILD_COUNT}:${CODEX_ROOT_RSS_KB}:${CODEX_CHILD_RSS_KB}:${CODEX_CPU_PERCENT}"
          ;;
      esac
    done
    case "$TEST_MODE" in
      risk_cpu_hot)
        if agent_root_in_list claude; then
          AGENT_CPU_PERCENT=150.0
          CLAUDE_CPU_PERCENT=150.0
        fi
        ;;
      risk_cpu_crit)
        if agent_root_in_list claude; then
          AGENT_CPU_PERCENT=250.0
          CLAUDE_CPU_PERCENT=250.0
        fi
        ;;
    esac
    AGENT_MEM_PERCENT=$(safe_percent "$AGENT_TOTAL_RSS_KB" "$MEM_TOTAL_KB")
    return
  fi

  eval "$(
    snapshot_lines | awk -v monitor_pid="$MONITOR_PID" -v mem_total_kb="$MEM_TOTAL_KB" -v root_list="$AGENT_ROOT_LIST" '
      function trim(s) {
        sub(/^[[:space:]]+/, "", s);
        sub(/[[:space:]]+$/, "", s);
        return s;
      }
      function agent_kind_for(comm_val, args_val) {
        if (comm_val == "claude" || comm_val == "claude-exomind") return "claude";
        if (args_val ~ /(^|[[:space:]])[^[:space:]]*\/claude-exomind([[:space:]]|$)/) return "claude";
        if (args_val ~ /(^|[[:space:]])[^[:space:]]*@anthropic-ai\/claude-code\/bin\/claude([[:space:]]|$)/) return "claude";
        if (comm_val == "codex" || comm_val == "codex-exomind") return "codex";
        if ((comm_val == "MainThread" || comm_val == "node") && args_val ~ /(^|[[:space:]])[^[:space:]]*\/codex([[:space:]]|$)/) return "codex";
        return "";
      }
      function is_agent_root(pid) {
        return kind[pid] != "" || root[comm[pid]] == 1;
      }
      function mark_hidden_chain(pid) {
        while (pid != "" && pid != 0 && !is_agent_root(pid) && !hidden[pid]) {
          hidden[pid] = 1;
          pid = ppid[pid];
        }
      }
      function mark_hidden_descendants(pid, child_ids, n, i, child_pid) {
        hidden[pid] = 1;
        n = split(children[pid], child_ids, " ");
        for (i = 1; i <= n; i++) {
          child_pid = child_ids[i];
          if (child_pid != "" && !hidden[child_pid]) {
            mark_hidden_descendants(child_pid);
          }
        }
      }
      function add_type_name(name) {
        if (name != "" && !type_seen[name]++) {
          type_order[++type_count] = name;
        }
      }
      function collect_tree(pid, type_name, is_root, child_ids, n, i, child_pid) {
        if (hidden[pid]) return;
        if (!is_root && is_agent_root(pid)) return;

        if (is_root) {
          root_count_map[type_name]++;
          root_rss_map[type_name] += rss[pid];
        } else {
          child_count_map[type_name]++;
          child_rss_map[type_name] += rss[pid];
        }
        type_cpu_map[type_name] += cpu[pid];
        type_rss_map[type_name] += rss[pid];
        agent_cpu += cpu[pid];
        agent_rss += rss[pid];

        n = split(children[pid], child_ids, " ");
        for (i = 1; i <= n; i++) {
          child_pid = child_ids[i];
          if (child_pid != "") {
            collect_tree(child_pid, type_name, 0);
          }
        }
      }
      BEGIN {
        root_count = split(root_list, root_names, " ");
        for (i = 1; i <= root_count; i++) {
          root[root_names[i]] = 1;
          add_type_name(root_names[i]);
        }
        add_type_name("claude");
        add_type_name("codex");
      }
      {
        pid_val = $1;
        ppid_val = $2;
        rss_val = $3;
        cpu_val = $4;
        comm_val = $6;

        $1 = ""; $2 = ""; $3 = ""; $4 = ""; $5 = ""; $6 = "";
        args_val = trim($0);

        pid[pid_val] = pid_val;
        ppid[pid_val] = ppid_val;
        rss[pid_val] = rss_val + 0;
        cpu[pid_val] = cpu_val + 0;
        comm[pid_val] = comm_val;
        args[pid_val] = args_val;
        kind[pid_val] = agent_kind_for(comm_val, args_val);
        children[ppid_val] = children[ppid_val] " " pid_val;

        if (is_agent_root(pid_val)) {
          root_order[++root_pid_count] = pid_val;
          root_kind[pid_val] = (kind[pid_val] != "" ? kind[pid_val] : comm_val);
          add_type_name(root_kind[pid_val]);
        }
      }
      END {
        mark_hidden_chain(monitor_pid);
        mark_hidden_descendants(monitor_pid);

        for (i = 1; i <= root_pid_count; i++) {
          pid_val = root_order[i];
          if (!hidden[pid_val]) {
            collect_tree(pid_val, root_kind[pid_val], 1);
          }
        }

        summary = "";
        for (i = 1; i <= type_count; i++) {
          name = type_order[i];
          if (root_count_map[name] + child_count_map[name] <= 0) continue;
          if (summary != "") summary = summary " ";
          summary = summary name ":" (root_count_map[name] + 0) ":" (child_count_map[name] + 0) ":" (root_rss_map[name] + 0) ":" (child_rss_map[name] + 0) ":" sprintf("%.1f", type_cpu_map[name] + 0);
        }
        escaped = summary;
        gsub(/["\\]/, "\\\\&", escaped);
        printf "AGENT_ROOT_SUMMARY=\"%s\"\n", escaped;
        printf "AGENT_CPU_PERCENT=%.1f\n", agent_cpu;
        printf "AGENT_TOTAL_RSS_KB=%.0f\n", agent_rss;
        printf "CLAUDE_ROOT_COUNT=%d\n", root_count_map["claude"] + 0;
        printf "CLAUDE_CHILD_COUNT=%d\n", child_count_map["claude"] + 0;
        printf "CLAUDE_ROOT_RSS_KB=%.0f\n", root_rss_map["claude"] + 0;
        printf "CLAUDE_CHILD_RSS_KB=%.0f\n", child_rss_map["claude"] + 0;
        printf "CLAUDE_CPU_PERCENT=%.1f\n", type_cpu_map["claude"] + 0;
        printf "CODEX_ROOT_COUNT=%d\n", root_count_map["codex"] + 0;
        printf "CODEX_CHILD_COUNT=%d\n", child_count_map["codex"] + 0;
        printf "CODEX_ROOT_RSS_KB=%.0f\n", root_rss_map["codex"] + 0;
        printf "CODEX_CHILD_RSS_KB=%.0f\n", child_rss_map["codex"] + 0;
        printf "CODEX_CPU_PERCENT=%.1f\n", type_cpu_map["codex"] + 0;
        if (mem_total_kb > 0) {
          printf "AGENT_MEM_PERCENT=%.1f\n", (agent_rss / mem_total_kb) * 100.0;
        } else {
          printf "AGENT_MEM_PERCENT=0.0\n";
        }
      }
    '
  )"
  CLAUDE_RSS_KB=$((CLAUDE_ROOT_RSS_KB + CLAUDE_CHILD_RSS_KB))
  CODEX_RSS_KB=$((CODEX_ROOT_RSS_KB + CODEX_CHILD_RSS_KB))
}

collect_task_metrics() {
  if is_fixture_mode && [ -z "$TEST_PS_FILE" ]; then
      TASK_RUNNING_COUNT=2
      TASK_SLEEPING_COUNT=34
      TASK_STOPPED_COUNT=1
      TASK_ZOMBIE_COUNT=1
      TASK_TOTAL_COUNT=38
      return
  fi

  eval "$(
    snapshot_lines | awk '
      /^[[:space:]]*$/ {
        next;
      }
      {
        state = substr($5, 1, 1);
        total++;
        if (state == "R") {
          running++;
        } else if (state == "T" || state == "t") {
          stopped++;
        } else if (state == "Z") {
          zombie++;
        } else {
          sleeping++;
        }
      }
      END {
        printf "TASK_RUNNING_COUNT=%d\n", running + 0;
        printf "TASK_SLEEPING_COUNT=%d\n", sleeping + 0;
        printf "TASK_STOPPED_COUNT=%d\n", stopped + 0;
        printf "TASK_ZOMBIE_COUNT=%d\n", zombie + 0;
        printf "TASK_TOTAL_COUNT=%d\n", total + 0;
      }
    '
  )"
}

render_plain_header_line() {
  printf "+"
  repeat_char "=" "$((PANEL_WIDTH - 2))"
  printf "+\n"
}

render_reverse_text_line() {
  content="$1"
  awk -v width="$PANEL_WIDTH" -v content="$content" -v reverse="$ANSI_REVERSE" -v reset="$ANSI_RESET" 'BEGIN {
    text = content;
    if (length(text) > width) {
      if (width > 3) {
        text = substr(text, 1, width - 3) "...";
      } else {
        text = substr(text, 1, width);
      }
    }
    printf "%s%-" width "s%s\n", reverse, text, reset;
  }'
}

render_title_line() {
  left_text="$1"
  right_text="${2:-}"
  content="$left_text"

  if [ -n "$right_text" ]; then
    if [ "$STYLE_ENABLED" -eq 1 ]; then
      title_width="$PANEL_WIDTH"
      if [ "$title_width" -gt 1 ]; then
        title_width=$((title_width - 1))
      fi
    else
      title_width="$PANEL_INNER_WIDTH"
    fi

    content=$(
      awk -v width="$title_width" -v left="$left_text" -v right="$right_text" 'BEGIN {
        gap = "  ";
        if (length(right) >= width) {
          if (width > 3) {
            print substr(right, 1, width - 3) "...";
          } else {
            print substr(right, 1, width);
          }
          exit;
        }

        available = width - length(right);
        left_display = "";
        if (available > length(gap)) {
          left_width = available - length(gap);
          left_display = left;
          if (length(left_display) > left_width) {
            if (left_width > 3) {
              left_display = substr(left_display, 1, left_width - 3) "...";
            } else {
              left_display = substr(left_display, 1, left_width);
            }
          }
          left_display = left_display gap;
        }

        padding = width - length(left_display) - length(right);
        if (padding < 0) {
          padding = 0;
        }

        printf "%s", left_display;
        for (i = 0; i < padding; i++) {
          printf " ";
        }
        printf "%s\n", right;
      }'
    )
  fi

  if [ "$STYLE_ENABLED" -eq 1 ]; then
    render_reverse_text_line "$content"
  else
    render_panel_line "$content"
  fi
}

render_title_bar() {
  now_text="$1"
  fps_text="FPS: $FPS_LABEL"
  risk_text="RISK: $RISK_LEVEL"
  title_left_text="TERMUX SYSTEM SNAPSHOT  $now_text"

  if [ "$STYLE_ENABLED" -eq 1 ]; then
    title_layout=$(build_title_layout "$PANEL_WIDTH" "$title_left_text" "$fps_text" "$risk_text")
    IFS='	' read -r left_display padding_count fps_display risk_display <<EOF
$title_layout
EOF
    risk_badge=$(render_risk_badge "$RISK_LEVEL")

    printf '%s' "$ANSI_REVERSE"
    if [ -n "$left_display" ]; then
      render_bold_title_text "$left_display"
      if [ -n "$fps_display$risk_display" ]; then
        printf '  '
      fi
    fi
    repeat_char " " "$padding_count"
    if [ -n "$fps_display" ]; then
      printf '%s' "$fps_display"
      if [ -n "$risk_display" ]; then
        printf '  '
      fi
    fi
    if [ -n "$risk_display" ]; then
      printf '%s' "$risk_badge"
    fi
    printf '%s\n' "$ANSI_RESET"
    return
  fi

  render_title_line "$title_left_text" "$fps_text  $risk_text"
}

render_panel_line() {
  content="$1"
  awk -v width="$PANEL_INNER_WIDTH" -v content="$content" 'BEGIN {
    text = content;
    if (length(text) > width) {
      if (width > 3) {
        text = substr(text, 1, width - 3) "...";
      } else {
        text = substr(text, 1, width);
      }
    }
    printf "| %-" width "s |\n", text;
  }'
}

render_single_panel_line() {
  content="$1"

  if [ "$STYLE_ENABLED" -eq 1 ]; then
    printf '%s\n' "$content"
    return
  fi

  render_panel_line "$content"
}

render_panel_lines_wrapped() {
  content="$1"
  if [ "$STYLE_ENABLED" -eq 1 ]; then
    printf '%s\n' "$content" | awk -v width="$PANEL_WIDTH" '
      function emit_line(text) {
        printf "%-" width "s\n", text;
      }
      {
        remaining = $0;

        while (length(remaining) > width) {
          split_pos = 0;
          for (i = width; i >= 1; i--) {
            if (substr(remaining, i, 1) == " ") {
              split_pos = i;
              break;
            }
          }

          if (split_pos == 0) {
            emit_line(substr(remaining, 1, width));
            remaining = substr(remaining, width + 1);
          } else {
            emit_line(substr(remaining, 1, split_pos - 1));
            remaining = substr(remaining, split_pos + 1);
          }

          sub(/^ +/, "", remaining);
        }

        emit_line(remaining);
      }
    '
    return
  fi

  printf '%s\n' "$content" | awk -v width="$PANEL_INNER_WIDTH" '
    function emit_line(text) {
      printf "| %-" width "s |\n", text;
    }
    {
      line = "";
      remaining = $0;

      while (length(remaining) > width) {
        split_pos = 0;
        for (i = width; i >= 1; i--) {
          if (substr(remaining, i, 1) == " ") {
            split_pos = i;
            break;
          }
        }

        if (split_pos == 0) {
          emit_line(substr(remaining, 1, width));
          remaining = substr(remaining, width + 1);
        } else {
          emit_line(substr(remaining, 1, split_pos - 1));
          remaining = substr(remaining, split_pos + 1);
        }

        sub(/^ +/, "", remaining);
      }

      emit_line(remaining);
    }
  '
}

render_status_line() {
  content="$1"

  if [ "$STYLE_ENABLED" -eq 1 ]; then
    awk -v width="$PANEL_WIDTH" -v content="$content" 'BEGIN {
      text = content;
      if (length(text) > width) {
        if (width > 3) {
          text = substr(text, 1, width - 3) "...";
        } else {
          text = substr(text, 1, width);
        }
      }
      printf "%-" width "s\n", text;
    }'
    return
  fi

  render_panel_line "$content"
}

render_process_header() {
  location_heading="LOCATION"
  if [ "$PROCESS_LOCATION_WIDTH" -lt 8 ]; then
    location_heading="LOC"
  fi
  header_line=$(printf '%-6s %-6s %-7s %-6s %-*s %-6s %-*s %-9s %-*s %-*s' "PID" "PPID" "RSS_KB" "%MEM" "$PROCESS_MEM_BAR_FIELD_WIDTH" "MEM" "%CPU" "$PROCESS_CPU_BAR_FIELD_WIDTH" "CPU" "ROLE" "$PROCESS_LOCATION_WIDTH" "$location_heading" "$PROCESS_COMMAND_WIDTH" "COMMAND")
  if [ "$STYLE_ENABLED" -eq 1 ]; then
    render_reverse_text_line "$header_line"
  else
    printf '%s\n' "$header_line"
  fi
}

render_process_tree() {
  render_process_header

  if is_fixture_mode && [ -z "$TEST_PS_FILE" ]; then
    sample_path=$(compact_home_path "/data/data/com.termux/files/home/A137442/example/project/index.ts")
    sample_location_claude="main@termux-tools"
    sample_location_codex="scratch"
    sample_location_field_claude=$(render_process_location_field "$sample_location_claude" "$PROCESS_LOCATION_WIDTH")
    sample_location_field_codex=$(render_process_location_field "$sample_location_codex" "$PROCESS_LOCATION_WIDTH")
    sample_location_field_empty=$(render_text_field "" "$PROCESS_LOCATION_WIDTH")
    sample_mem_bar_low="$(render_bar 1.6 "$MEM_BAR_WIDTH" utilization)"
    sample_mem_bar_mid="$(render_bar 2.3 "$MEM_BAR_WIDTH" utilization)"
    sample_bar_low="$(render_bar 12.5 "$CPU_BAR_WIDTH" utilization)"
    sample_bar_mid="$(render_bar 55 "$CPU_BAR_WIDTH" utilization)"

    case "$TEST_MODE" in
      hotkey_kill|hotkey_kill_fail|hotkey_kill_all|hotkey_kill_all_partial_fail)
        sample_location_claude="main@termux-tools"
        sample_location_codex="scratch"
        sample_location_field_claude=$(render_process_location_field "$sample_location_claude" "$PROCESS_LOCATION_WIDTH")
        sample_location_field_codex=$(render_process_location_field "$sample_location_codex" "$PROCESS_LOCATION_WIDTH")
        printf '%-6s %-6s %-7s %s %-*s %s %-*s %s %s %-*s\n' 3001 1 65536 "$(render_metric_field 1.6 utilization 6)" "$PROCESS_MEM_BAR_FIELD_WIDTH" "$sample_mem_bar_low" "$(render_metric_field 95.0 utilization 6)" "$PROCESS_CPU_BAR_FIELD_WIDTH" "$(render_bar 95.0 "$CPU_BAR_WIDTH" utilization)" "$(render_role_field claude CLAUDE 9)" "$sample_location_field_claude" "$PROCESS_COMMAND_WIDTH" "claude"
        printf '%-6s %-6s %-7s %s %-*s %s %-*s %s %s %-*s\n' 4002 3001 32768 "$(render_metric_field 0.8 utilization 6)" "$PROCESS_MEM_BAR_FIELD_WIDTH" "$(render_bar 0.8 "$MEM_BAR_WIDTH" utilization)" "$(render_metric_field 87.5 utilization 6)" "$PROCESS_CPU_BAR_FIELD_WIDTH" "$(render_bar 87.5 "$CPU_BAR_WIDTH" utilization)" "$(render_role_field claude child 9)" "$sample_location_field_empty" "$PROCESS_COMMAND_WIDTH" "|- rustc"
        printf '%-6s %-6s %-7s %s %-*s %s %-*s %s %s %-*s\n' 3002 1 98304 "$(render_metric_field 2.3 utilization 6)" "$PROCESS_MEM_BAR_FIELD_WIDTH" "$sample_mem_bar_mid" "$(render_metric_field 55.0 utilization 6)" "$PROCESS_CPU_BAR_FIELD_WIDTH" "$sample_bar_mid" "$(render_role_field codex CODEX 9)" "$sample_location_field_codex" "$PROCESS_COMMAND_WIDTH" "codex"
        printf '%-6s %-6s %-7s %s %-*s %s %-*s %s %s %-*s\n' 4003 3002 12288 "$(render_metric_field 0.3 utilization 6)" "$PROCESS_MEM_BAR_FIELD_WIDTH" "$(render_bar 0.3 "$MEM_BAR_WIDTH" utilization)" "$(render_metric_field 40.0 utilization 6)" "$PROCESS_CPU_BAR_FIELD_WIDTH" "$(render_bar 40.0 "$CPU_BAR_WIDTH" utilization)" "$(render_role_field codex child 9)" "$sample_location_field_empty" "$PROCESS_COMMAND_WIDTH" "|- node"
        return
        ;;
      hotkey_no_target|hotkey_kill_all_no_target)
        printf '%-6s %-6s %-7s %s %-*s %s %-*s %s %s %-*s\n' 3001 1 65536 "$(render_metric_field 1.6 utilization 6)" "$PROCESS_MEM_BAR_FIELD_WIDTH" "$sample_mem_bar_low" "$(render_metric_field 95.0 utilization 6)" "$PROCESS_CPU_BAR_FIELD_WIDTH" "$(render_bar 95.0 "$CPU_BAR_WIDTH" utilization)" "$(render_role_field claude CLAUDE 9)" "$sample_location_field_claude" "$PROCESS_COMMAND_WIDTH" "claude"
        printf '%-6s %-6s %-7s %s %-*s %s %-*s %s %s %-*s\n' 3002 1 98304 "$(render_metric_field 2.3 utilization 6)" "$PROCESS_MEM_BAR_FIELD_WIDTH" "$sample_mem_bar_mid" "$(render_metric_field 55.0 utilization 6)" "$PROCESS_CPU_BAR_FIELD_WIDTH" "$sample_bar_mid" "$(render_role_field codex CODEX 9)" "$sample_location_field_codex" "$PROCESS_COMMAND_WIDTH" "codex"
        return
        ;;
    esac

    if agent_root_in_list claude; then
      printf '%-6s %-6s %-7s %s %-*s %s %-*s %s %s %s\n' 1234 1 65536 "$(render_metric_field 1.6 utilization 6)" "$PROCESS_MEM_BAR_FIELD_WIDTH" "$sample_mem_bar_low" "$(render_metric_field 12.5 utilization 6)" "$PROCESS_CPU_BAR_FIELD_WIDTH" "$sample_bar_low" "$(render_role_field claude CLAUDE 9)" "$sample_location_field_claude" "$(render_process_command_field claude "$PROCESS_COMMAND_WIDTH")"
      printf '%-6s %-6s %-7s %s %-*s %s %-*s %s %s %s\n' 1456 1234 4096 "$(render_metric_field 0.1 utilization 6)" "$PROCESS_MEM_BAR_FIELD_WIDTH" "$(render_bar 0.1 "$MEM_BAR_WIDTH" utilization)" "$(render_metric_field 4.0 utilization 6)" "$PROCESS_CPU_BAR_FIELD_WIDTH" "$(render_bar 4.0 "$CPU_BAR_WIDTH" utilization)" "$(render_role_field claude child 9)" "$sample_location_field_empty" "$(render_process_command_field '|- helper' "$PROCESS_COMMAND_WIDTH")"
    fi
    if agent_root_in_list codex; then
      printf '%-6s %-6s %-7s %s %-*s %s %-*s %s %s %s\n' 2345 1 98304 "$(render_metric_field 2.3 utilization 6)" "$PROCESS_MEM_BAR_FIELD_WIDTH" "$sample_mem_bar_mid" "$(render_metric_field 55.0 utilization 6)" "$PROCESS_CPU_BAR_FIELD_WIDTH" "$sample_bar_mid" "$(render_role_field codex CODEX 9)" "$sample_location_field_codex" "$(render_process_command_field "node $sample_path" "$PROCESS_COMMAND_WIDTH")"
      printf '%-6s %-6s %-7s %s %-*s %s %-*s %s %s %s\n' 2456 2345 5120 "$(render_metric_field 0.1 utilization 6)" "$PROCESS_MEM_BAR_FIELD_WIDTH" "$(render_bar 0.1 "$MEM_BAR_WIDTH" utilization)" "$(render_metric_field 8.0 utilization 6)" "$PROCESS_CPU_BAR_FIELD_WIDTH" "$(render_bar 8.0 "$CPU_BAR_WIDTH" utilization)" "$(render_role_field codex child 9)" "$sample_location_field_empty" "$(render_process_command_field '|- worker' "$PROCESS_COMMAND_WIDTH")"
    fi
    return
  fi

  snapshot_lines | awk -v monitor_pid="$MONITOR_PID" -v command_width="$PROCESS_COMMAND_WIDTH" -v location_width="$PROCESS_LOCATION_WIDTH" -v home_prefix="$HOME" -v termux_prefix="/data/data/com.termux/files" -v location_map="$FRAME_LOCATION_MAP" -v cpu_bar_width="$CPU_BAR_WIDTH" -v cpu_bar_field_width="$PROCESS_CPU_BAR_FIELD_WIDTH" -v mem_total_kb="$MEM_TOTAL_KB" -v mem_bar_width="$MEM_BAR_WIDTH" -v mem_bar_field_width="$PROCESS_MEM_BAR_FIELD_WIDTH" -v style_enabled="$STYLE_ENABLED" -v ansi_green="$ANSI_BRIGHT_GREEN" -v ansi_yellow="$ANSI_BRIGHT_YELLOW" -v ansi_red="$ANSI_BRIGHT_RED" -v ansi_claude="$ANSI_BRIGHT_CLAUDE" -v ansi_codex="$ANSI_BRIGHT_CODEX" -v ansi_reset="$ANSI_RESET" -v root_list="$AGENT_ROOT_LIST" '
    function trim(s) {
      sub(/^[[:space:]]+/, "", s);
      sub(/[[:space:]]+$/, "", s);
      return s;
    }
    function agent_kind_for(comm_val, args_val) {
      if (comm_val == "claude" || comm_val == "claude-exomind") return "claude";
      if (args_val ~ /(^|[[:space:]])[^[:space:]]*\/claude-exomind([[:space:]]|$)/) return "claude";
      if (comm_val == "codex" || comm_val == "codex-exomind") return "codex";
      if (args_val ~ /(^|[[:space:]])[^[:space:]]*@anthropic-ai\/claude-code\/bin\/claude([[:space:]]|$)/) return "claude";
      if ((comm_val == "MainThread" || comm_val == "node") && args_val ~ /(^|[[:space:]])[^[:space:]]*\/codex([[:space:]]|$)/) return "codex";
      return "";
    }
    function is_agent_root(pid) {
      return kind[pid] != "" || root[comm[pid]] == 1;
    }
    function is_tmux(pid) {
      return comm[pid] == "tmux" || args[pid] ~ /(^|[[:space:]])tmux([[:space:]]|$)/;
    }
    function nearest_tmux(pid, parent) {
      parent = ppid[pid];
      while (parent != "" && parent != 0) {
        if (is_tmux(parent)) return parent;
        parent = ppid[parent];
      }
      return "";
    }
    function role_label(root_kind, depth, pid) {
      if (kind[pid] != "") {
        return toupper(kind[pid]);
      }
      if (depth == 0) {
        if (root_kind == "claude") {
          return "CLAUDE";
        }
        if (root_kind == "codex") {
          return "CODEX";
        }
        return toupper(root_kind);
      }
      return "  child";
    }
    function short_args(text, max_len) {
      if (max_len < 1) {
        return "";
      }
      if (length(text) <= max_len) {
        return text;
      }
      if (max_len <= 3) {
        return substr(text, 1, max_len);
      }
      return substr(text, 1, max_len - 3) "...";
    }
    function short_location(text, max_len, at_pos, folder_chars) {
      if (max_len < 1) return "";
      if (length(text) <= max_len) return text;
      at_pos = index(text, "@");
      if (at_pos > 0) {
        folder_chars = max_len - at_pos - 2;
        if (folder_chars > 0) {
          return substr(text, 1, at_pos + folder_chars) "..";
        }
        if (max_len >= at_pos + 2) {
          return substr(text, 1, at_pos) "..";
        }
      }
      if (max_len <= 2) return substr("..", 1, max_len);
      return substr(text, 1, max_len - 2) "..";
    }
    function safe_percent(numerator, denominator) {
      if (denominator <= 0) {
        return 0.0;
      }
      return (numerator / denominator) * 100.0;
    }
    function cpu_bar(percent, width, clamped, filled, i, bar_text) {
      clamped = percent + 0;
      if (clamped < 0) {
        clamped = 0;
      }
      if (clamped > 100) {
        clamped = 100;
      }

      filled = int((clamped / 100.0) * width + 0.5);
      if (filled < 0) {
        filled = 0;
      }
      if (filled > width) {
        filled = width;
      }

      bar_text = "";
      for (i = 0; i < filled; i++) {
        bar_text = bar_text "█";
      }
      for (i = filled; i < width; i++) {
        bar_text = bar_text "░";
      }
      return bar_text;
    }
    function bar_color(percent, kind) {
      if (style_enabled != 1) {
        return "";
      }

      if (kind == "availability") {
        if (percent < 20) {
          return ansi_red;
        }
        if (percent < 40) {
          return ansi_yellow;
        }
        return ansi_green;
      }

      if (percent >= 80) {
        return ansi_red;
      }
      if (percent >= 60) {
        return ansi_yellow;
      }
      return ansi_green;
    }
    function role_color(root_kind) {
      if (style_enabled != 1) {
        return "";
      }
      if (root_kind == "claude") {
        return ansi_claude;
      }
      if (root_kind == "codex") {
        return ansi_codex;
      }
      return "";
    }
    function style_text(text, color_text) {
      if (style_enabled == 1 && color_text != "") {
        return color_text text ansi_reset;
      }
      return text;
    }
    function render_bar(percent, width, kind, bar_text, color_text) {
      bar_text = cpu_bar(percent, width);
      color_text = bar_color(percent, kind);
      if (style_enabled == 1) {
        return color_text bar_text ansi_reset;
      }
      return bar_text;
    }
    function render_metric_text(percent, kind, width, plain_text) {
      plain_text = sprintf("%-*s", width, sprintf("%.1f", percent));
      return style_text(plain_text, bar_color(percent, kind));
    }
    function render_role_text(root_kind, depth, width, plain_text, pid) {
      plain_text = sprintf("%-*s", width, role_label(root_kind, depth, pid));
      return style_text(plain_text, role_color(root_kind));
    }
    function compact_path_prefix(text, prefix, replacement,    pos, before, after, result) {
      result = "";
      while ((pos = index(text, prefix)) > 0) {
        before = (pos == 1 ? "" : substr(text, pos - 1, 1));
        after = substr(text, pos + length(prefix), 1);
        if ((pos == 1 || before ~ /[[:space:]"=]/) && (after == "" || after == "/" || after ~ /[[:space:]]/)) {
          result = result substr(text, 1, pos - 1) replacement;
          text = substr(text, pos + length(prefix));
        } else {
          result = result substr(text, 1, pos);
          text = substr(text, pos + 1);
        }
      }
      return result text;
    }
    function compact_home_path(text) {
      text = compact_path_prefix(text, home_prefix, "~");
      return compact_path_prefix(text, termux_prefix, "~/..");
    }
    BEGIN {
      root_name_count = split(root_list, root_names, " ");
      for (i = 1; i <= root_name_count; i++) {
        root[root_names[i]] = 1;
      }
      location_count = split(location_map, location_records, "\n");
      for (i = 1; i <= location_count; i++) {
        separator = index(location_records[i], "\t");
        if (separator > 0) {
          location_pid = substr(location_records[i], 1, separator - 1);
          location_cache[location_pid] = substr(location_records[i], separator + 1);
        }
      }
    }
    function dq_quote(text,    result, i, ch) {
      result = "\"";
      for (i = 1; i <= length(text); i++) {
        ch = substr(text, i, 1);
        if (ch == "\\" || ch == "\"" || ch == "$" || ch == "`") {
          result = result "\\" ch;
        } else {
          result = result ch;
        }
      }
      result = result "\"";
      return result;
    }
    function basename_path(path,    pos) {
      sub(/\/$/, "", path);
      pos = match(path, /[^\/]+$/);
      if (pos == 0) {
        return "";
      }
      return substr(path, RSTART, RLENGTH);
    }
    function get_location(pid) {
      return location_cache[pid];
    }
    function mark_hidden_chain(pid) {
      while (pid != "" && pid != 0 && !is_agent_root(pid) && !hidden[pid]) {
        hidden[pid] = 1;
        pid = ppid[pid];
      }
    }
    function mark_hidden_descendants(pid, child_ids, n, i, child_pid) {
      hidden[pid] = 1;

      n = split(children[pid], child_ids, " ");
      for (i = 1; i <= n; i++) {
        child_pid = child_ids[i];
        if (child_pid != "" && !hidden[child_pid]) {
          mark_hidden_descendants(child_pid);
        }
      }
    }
    function print_node(pid, depth, root_kind, prefix, child_ids, n, i, child_pid, summary) {
      prefix = "";
      for (i = 0; i < depth; i++) {
        prefix = prefix "  ";
      }
      if (depth > 0) {
        prefix = prefix "|- ";
      }
      command_text = prefix compact_home_path(args[pid]);
      summary = short_args(command_text, command_width);
      mem_percent = safe_percent(rss[pid], mem_total_kb);
      if (depth == 0) {
        root_kind = (kind[pid] != "" ? kind[pid] : comm[pid]);
      }
      location_text = "";
      if (depth == 0 || kind[pid] != "") {
        location_text = short_location(get_location(pid), location_width);
      }
      printf "%-6s %-6s %-7s %s %-*s %s %-*s %s %-*s %-*s\n",
        pid,
        ppid[pid],
        rss[pid],
        render_metric_text(mem_percent, "utilization", 6),
        mem_bar_field_width,
        render_bar(mem_percent, mem_bar_width, "utilization"),
        render_metric_text(cpu[pid], "utilization", 6),
        cpu_bar_field_width,
        render_bar(cpu[pid], cpu_bar_width, "utilization"),
        render_role_text(root_kind, depth, 9, "", pid),
        location_width,
        location_text,
        command_width,
        summary;

      if (is_tmux(pid)) {
        for (i = 1; i <= root_pid_count; i++) {
          child_pid = root_order[i];
          if (tmux_agent_parent[child_pid] == pid && !printed[child_pid]) {
            printed[child_pid] = 1;
            print_node(child_pid, depth + 1, kind[child_pid]);
          }
        }
      } else {
        n = split(children[pid], child_ids, " ");
        for (i = 1; i <= n; i++) {
          child_pid = child_ids[i];
          if (child_pid == "" || hidden[child_pid] || printed[child_pid]) continue;
          printed[child_pid] = 1;
          print_node(child_pid, depth + 1, root_kind);
        }
      }
    }
    {
      line = $0;
      pid_val = $1;
      ppid_val = $2;
      rss_val = $3;
      cpu_val = $4;
      comm_val = $6;

      $1 = ""; $2 = ""; $3 = ""; $4 = ""; $5 = ""; $6 = "";
      args_val = trim($0);

      pid[pid_val] = pid_val;
      ppid[pid_val] = ppid_val;
      rss[pid_val] = rss_val;
      cpu[pid_val] = cpu_val;
      comm[pid_val] = comm_val;
      args[pid_val] = args_val;
      kind[pid_val] = agent_kind_for(comm_val, args_val);
      children[ppid_val] = children[ppid_val] " " pid_val;

      if (kind[pid_val] != "" || root[comm_val] || comm_val == "tmux") {
        root_order[++root_pid_count] = pid_val;
      }
    }
    END {
      for (i = 1; i <= root_pid_count; i++) {
        pid_val = root_order[i];
        if (kind[pid_val] == "") continue;
        tmux_pid = nearest_tmux(pid_val);
        if (tmux_pid != "") {
          tmux_agent_parent[pid_val] = tmux_pid;
          tmux_display[tmux_pid] = 1;
        }
      }
      for (i = 1; i <= root_pid_count; i++) {
        pid_val = root_order[i];
        if (kind[pid_val] != "" && tmux_agent_parent[pid_val] != "") continue;
        if (kind[pid_val] == "" && !tmux_display[pid_val] && !root[comm[pid_val]]) continue;
        if (!printed[pid_val]) {
          printed[pid_val] = 1;
          print_node(pid_val, 0, tmux_display[pid_val] ? "tmux" : (kind[pid_val] != "" ? kind[pid_val] : comm[pid_val]));
        }
      }
    }
  '
}

render_dashboard() {
  if [ "$TEST_MODE" = "diff" ]; then
    now='2026-03-12 00:00:00 CST'
  elif [ "$TEST_MODE" = "diff_title" ]; then
    now=$(awk -v iteration="$LOOP_ITERATION" 'BEGIN {
      second = iteration - 1;
      if (second < 0) {
        second = 0;
      }
      printf "2026-03-12 00:00:%02d CST", second;
    }')
  elif [ "$TEST_MODE" = "resize" ]; then
    now=$(awk -v iteration="$LOOP_ITERATION" 'BEGIN {
      second = iteration - 1;
      if (second < 0) {
        second = 0;
      }
      printf "2026-03-12 00:00:%02d CST", second;
    }')
  else
    now=$(date '+%F %T %Z')
  fi
  mem_available_mib=$(to_mib "$MEM_AVAILABLE_KB")
  buffers_mib=$(to_mib "$BUFFERS_KB")
  swap_free_mib=$(to_mib "$SWAP_FREE_KB")
  cached_mib=$(to_mib "$CACHED_KB")
  data_available_gib=$(awk -v blocks="$DATA_AVAILABLE_BLOCKS" 'BEGIN { printf "%.1f", blocks / 2097152.0 }')
  data_used_gib=$(awk -v blocks="$DATA_USED_BLOCKS" 'BEGIN { printf "%.1f", blocks / 2097152.0 }')
  mem_available_text="$mem_available_mib MiB free"
  swap_available_text="$swap_free_mib MiB free"
  data_available_text="$data_available_gib GiB free"
  mem_reference_text="$buffers_mib MiB buffers"
  swap_reference_text="$cached_mib MiB cached"
  data_reference_text="$data_used_gib GiB used"
  agent_cpu_cores=$(awk -v percent="$AGENT_CPU_PERCENT" 'BEGIN { printf "%.2f", percent / 100.0 }')
  global_cpu_cores=$(awk -v percent="$GLOBAL_CPU_RAW_PERCENT" 'BEGIN { printf "%.2f", percent / 100.0 }')
  global_cpu_text="${global_cpu_cores}/${CPU_COUNT} cores"
  resource_available_width=$(text_width "$mem_available_text")
  current_width=$(text_width "$swap_available_text")
  if [ "$current_width" -gt "$resource_available_width" ]; then
    resource_available_width=$current_width
  fi
  current_width=$(text_width "$data_available_text")
  if [ "$current_width" -gt "$resource_available_width" ]; then
    resource_available_width=$current_width
  fi
  resource_reference_width=$(text_width "$mem_reference_text")
  current_width=$(text_width "$swap_reference_text")
  if [ "$current_width" -gt "$resource_reference_width" ]; then
    resource_reference_width=$current_width
  fi
  current_width=$(text_width "$data_reference_text")
  if [ "$current_width" -gt "$resource_reference_width" ]; then
    resource_reference_width=$current_width
  fi
  resource_bar_width=$(compute_resource_bar_width "$resource_available_width" "$resource_reference_width")
  agent_type_summary=""
  for root_entry in $AGENT_ROOT_SUMMARY; do
    IFS=':' read -r root_name root_count child_count root_rss_kb child_rss_kb type_cpu <<EOF
$root_entry
EOF
    root_rss_mib=$(to_mib "$root_rss_kb")
    child_rss_mib=$(to_mib "$child_rss_kb")
    type_rss_mib=$(to_mib "$((root_rss_kb + child_rss_kb))")
    process_count=$((root_count + child_count))
    root_label=$(printf '%s' "$root_name" | awk '{ print toupper($0) }')
    summary_part="${root_label}: ${root_count} agents + ${child_count} child = ${process_count} proc  CPU ${type_cpu}%  RSS ${root_rss_mib} + ${child_rss_mib} = ${type_rss_mib} MiB"
    summary_part=$(render_colored_text "$summary_part" "$(role_color_code "$root_name")")
    if [ -n "$agent_type_summary" ]; then
      agent_type_summary="${agent_type_summary}
${summary_part}"
    else
      agent_type_summary="$summary_part"
    fi
  done
  agent_cpu_cores=$(awk -v percent="$AGENT_CPU_PERCENT" 'BEGIN { printf "%.2f", percent / 100.0 }')
  agent_rss_mib=$(to_mib "$AGENT_TOTAL_RSS_KB")
  agent_summary="Agents: CPU ${AGENT_CPU_PERCENT}%  ${agent_cpu_cores} cores  Mem ${AGENT_MEM_PERCENT}%  ${agent_rss_mib} MiB"

  cpu_claude_percent=$(awk -v cpu="$CLAUDE_CPU_PERCENT" -v count="$CPU_COUNT" 'BEGIN { if (count <= 0) count=1; printf "%.4f", cpu/count }')
  cpu_codex_percent=$(awk -v cpu="$CODEX_CPU_PERCENT" -v count="$CPU_COUNT" 'BEGIN { if (count <= 0) count=1; printf "%.4f", cpu/count }')
  cpu_other_percent=$(awk -v total="$GLOBAL_CPU_PERCENT" -v claude="$cpu_claude_percent" -v codex="$cpu_codex_percent" 'BEGIN { value=total-claude-codex; if (value<0) value=0; printf "%.4f", value }')
  cpu_idle_percent=$(awk -v total="$GLOBAL_CPU_PERCENT" 'BEGIN { value=100-total; if (value<0) value=0; printf "%.4f", value }')
  mem_claude_percent=$(safe_percent "$CLAUDE_RSS_KB" "$MEM_TOTAL_KB")
  mem_codex_percent=$(safe_percent "$CODEX_RSS_KB" "$MEM_TOTAL_KB")
  mem_other_percent=$(awk -v total="$MEM_TOTAL_KB" -v available="$MEM_AVAILABLE_KB" -v claude="$CLAUDE_RSS_KB" -v codex="$CODEX_RSS_KB" 'BEGIN {
    value = total - available - claude - codex;
    if (value < 0) value = 0;
    if (total <= 0) percent = 0;
    else percent = value / total * 100;
    printf "%.4f", percent;
  }')

  if [ "$STYLE_ENABLED" -eq 1 ]; then
    render_title_bar "$now"
  else
    render_plain_header_line
    render_title_bar "$now"
    render_plain_header_line
  fi
  render_tasks_line "$TASK_TOTAL_COUNT" "$TASK_RUNNING_COUNT" "$TASK_SLEEPING_COUNT" "$TASK_STOPPED_COUNT" "$TASK_ZOMBIE_COUNT"
  render_composition_line "CPU:" "$GLOBAL_CPU_PERCENT" utilization "$global_cpu_text" "all processes" "$resource_bar_width" "$resource_available_width" "$cpu_claude_percent" "$cpu_codex_percent" "$cpu_other_percent" "$cpu_idle_percent"
  render_composition_line "Mem:" "$MEM_AVAILABLE_PERCENT" availability "$mem_available_text" "$mem_reference_text" "$resource_bar_width" "$resource_available_width" "$mem_claude_percent" "$mem_codex_percent" "$mem_other_percent" "$MEM_AVAILABLE_PERCENT"
  render_resource_line "Swap:" "$SWAP_FREE_PERCENT" availability "$swap_available_text" "$swap_reference_text" "$resource_bar_width" "$resource_available_width"
  render_resource_line "/data:" "$DATA_FREE_PERCENT" disk_availability "$data_available_text" "$data_reference_text" "$resource_bar_width" "$resource_available_width"
  render_panel_lines_wrapped "$agent_type_summary"
  render_panel_lines_wrapped "$agent_summary"
  render_panel_lines_wrapped "AgentsCPU(norm): $(render_bar "$AGENT_CPU_NORM_PERCENT" "$SUMMARY_BAR_WIDTH" utilization) $(render_metric_text "$AGENT_CPU_NORM_PERCENT" utilization "%")"
  if [ "$SUMMARY_ONLY" -eq 1 ]; then
    if [ -n "$STATUS_MESSAGE" ]; then
      render_status_line "$STATUS_MESSAGE"
    fi
    if [ "$STYLE_ENABLED" -eq 0 ]; then
      render_plain_header_line
    fi
    return
  fi
  if [ -n "$STATUS_MESSAGE" ]; then
    render_status_line "$STATUS_MESSAGE"
  elif [ "$RUN_ONCE" -eq 0 ]; then
    render_status_line 'j/u: scroll  g/G: top/bottom  k,k: kill-one  Ctrl+K: kill-all  q: quit'
  fi
  if [ "$STYLE_ENABLED" -eq 0 ]; then
    render_plain_header_line
  fi
  render_process_tree
  if [ "$STYLE_ENABLED" -eq 0 ]; then
    render_plain_header_line
  fi
}

enter_live_screen() {
  LIVE_SCREEN_ACTIVE=1
  configure_live_input
  printf '\033[?1049h\033[?25l\033[H\033[J'
}

leave_live_screen() {
  restore_live_input
  if [ "$LIVE_SCREEN_ACTIVE" -eq 1 ]; then
    printf '\033[?25h\033[?1049l'
    LIVE_SCREEN_ACTIVE=0
  fi
}

handle_live_termination() {
  leave_live_screen
  exit 0
}

run_once() {
  AGENT_ROOT_LIST=$(parse_agent_roots "${AGENT_TOP_ROOTS:-}")
  if is_fixture_mode && [ -z "$TEST_PS_FILE" ]; then
    FRAME_PROCESS_SNAPSHOT=""
  else
    FRAME_PROCESS_SNAPSHOT=$(process_snapshot)
  fi
  collect_system_metrics
  collect_agent_rollup
  collect_task_metrics
  CPU_COUNT=$(detect_cpu_count)
  collect_global_cpu
  if is_fixture_mode && [ -z "$TEST_PS_FILE" ]; then
    FRAME_LOCATION_MAP=""
    FRAME_LOCATION_WIDTH=$DEFAULT_PROCESS_LOCATION_WIDTH
  else
    FRAME_LOCATION_MAP=$(collect_agent_locations)
    FRAME_LOCATION_WIDTH=$(calculate_location_width)
  fi
  configure_process_location_layout
  AGENT_CPU_NORM_PERCENT=$(awk -v percent="$AGENT_CPU_PERCENT" -v count="$CPU_COUNT" 'BEGIN {
    if (count <= 0) {
      count = 1;
    }
    value = percent / count;
    if (value < 0) {
      value = 0;
    }
    if (value > 100) {
      value = 100;
    }
    printf "%.1f", value;
  }')
  RISK_LEVEL=$(determine_risk_level)
  render_dashboard
}

render_frame_diff() {
  previous_frame="$1"
  current_frame="$2"

  if [ -z "$previous_frame" ]; then
    printf '%s' "$current_frame"
    printf '\033[J'
    return
  fi

  awk -v previous_frame="$previous_frame" -v current_frame="$current_frame" 'BEGIN {
    previous_count = split(previous_frame, previous_lines, /\n/);
    current_count = split(current_frame, current_lines, /\n/);
    max_count = previous_count > current_count ? previous_count : current_count;

    for (i = 1; i <= max_count; i++) {
      if (previous_lines[i] != current_lines[i]) {
        printf "\033[%d;1H", i;
        if (i <= current_count) {
          printf "\033[2K%s", current_lines[i];
        } else {
          printf "\033[2K";
        }
      }
    }

    if (current_count < previous_count) {
      printf "\033[%d;1H\033[J", current_count + 1;
    }
  }'
}

run_loop() {
  trap 'leave_live_screen' EXIT
  trap 'handle_live_termination' INT TERM HUP
  trap 'RESIZE_PENDING=1' WINCH
  enter_live_screen

  while :; do
    LOOP_ITERATION=$((LOOP_ITERATION + 1))
    previous_width=$PANEL_WIDTH
    previous_height=$PANEL_HEIGHT
    previous_location_width=$PROCESS_LOCATION_WIDTH
    configure_layout
    if [ "$RESIZE_PENDING" -eq 1 ] || [ "$PANEL_WIDTH" -ne "$previous_width" ] || [ "$PANEL_HEIGHT" -ne "$previous_height" ] || [ "$PROCESS_LOCATION_WIDTH" -ne "$previous_location_width" ]; then
      PREVIOUS_FRAME=""
      RESIZE_PENDING=0
    fi

    process_live_input
    if [ "$EXIT_REQUESTED" -eq 1 ]; then break; fi
    current_frame=$(run_once)
    if [ "$PROCESS_LOCATION_WIDTH" -ne "$previous_location_width" ]; then
      PREVIOUS_FRAME=""
    fi
    clamp_tree_focus "$current_frame"
    current_frame=$(clip_frame_to_terminal_height "$current_frame")
    printf '\033[H'
    render_frame_diff "$PREVIOUS_FRAME" "$current_frame"
    PREVIOUS_FRAME=$current_frame
    tick_status_message

    if [ "$TEST_CYCLES" -gt 0 ] && [ "$LOOP_ITERATION" -ge "$TEST_CYCLES" ]; then
      break
    fi

    sleep_until_refresh "$INTERVAL_SECONDS"
  done
}

if [ "$RUN_ONCE" -eq 1 ]; then
  run_once
else
  run_loop
fi
