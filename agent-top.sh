#!/usr/bin/env sh
set -eu

INTERVAL_SECONDS=2
FPS_LABEL=""
RUN_ONCE=0
MONITOR_PID=$$
LIVE_SCREEN_ACTIVE=0
LOOP_ITERATION=0
PREVIOUS_FRAME=""
TEST_MODE="${CODEX_TOP_TEST_MODE:-}"
TEST_CYCLES="${CODEX_TOP_TEST_CYCLES:-0}"
FORCE_STYLE="${CODEX_TOP_FORCE_STYLE:-0}"
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
PROCESS_FIXED_WIDTH=$((6 + 1 + 6 + 1 + 7 + 1 + 6 + 1 + PROCESS_MEM_BAR_FIELD_WIDTH + 1 + 6 + 1 + PROCESS_CPU_BAR_FIELD_WIDTH + 1 + 9 + 1))
PANEL_WIDTH=$DEFAULT_PANEL_WIDTH
PANEL_HEIGHT=0
PANEL_INNER_WIDTH=$((PANEL_WIDTH - 4))
PROCESS_COMMAND_WIDTH=$((PANEL_WIDTH - PROCESS_FIXED_WIDTH))
STYLE_ENABLED=0
RESIZE_PENDING=0
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
    --interval)
      shift
      INTERVAL_SECONDS="${1:-2}"
      ;;
    *)
      echo "usage: $0 [--once] [--interval seconds]" >&2
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
  PROCESS_COMMAND_WIDTH=$((PANEL_WIDTH - PROCESS_FIXED_WIDTH))
  if [ "$PROCESS_COMMAND_WIDTH" -lt 7 ]; then
    PROCESS_COMMAND_WIDTH=7
  fi
}

configure_layout

compact_home_path() {
  text="$1"
  home_prefix="$HOME"
  result=""

  while :; do
    case "$text" in
      *"$home_prefix"*)
        prefix=${text%%"$home_prefix"*}
        result="${result}${prefix}~"
        text=${text#*"$home_prefix"}
        ;;
      *)
        printf '%s' "${result}${text}"
        return
        ;;
    esac
  done
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
  padded_text=$(awk -v value="$role_text" -v width="$width" 'BEGIN { printf "%-*s", width, value }')
  color=$(role_color_code "$role_kind")
  render_colored_text "$padded_text" "$color"
}

render_text_field() {
  value="$1"
  width="$2"
  awk -v value="$value" -v width="$width" 'BEGIN { printf "%-*s", width, value }'
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

  printf '%s\n' "$frame_text" | awk -v max_rows="$PANEL_HEIGHT" 'NR <= max_rows { print }'
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

collect_system_metrics() {
  case "$TEST_MODE" in
    diff|diff_title|resize|risk_cpu_hot|risk_cpu_crit)
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
  if [ "$TEST_MODE" = "diff" ] || [ "$TEST_MODE" = "diff_title" ] || [ "$TEST_MODE" = "resize" ] || [ "$TEST_MODE" = "risk_warn" ] || [ "$TEST_MODE" = "risk_hot" ] || [ "$TEST_MODE" = "risk_crit" ] || [ "$TEST_MODE" = "risk_cpu_hot" ] || [ "$TEST_MODE" = "risk_cpu_crit" ] || [ "$TEST_MODE" = "disk_warn" ] || [ "$TEST_MODE" = "disk_hot" ]; then
    if [ "$LOOP_ITERATION" -le 1 ]; then
      CLAUDE_COUNT=1
      CLAUDE_RSS_KB=131072
      case "$TEST_MODE" in
        risk_cpu_hot)
          AGENT_CPU_PERCENT=150.0
          ;;
        risk_cpu_crit)
          AGENT_CPU_PERCENT=250.0
          ;;
        *)
          AGENT_CPU_PERCENT=55.0
          ;;
      esac
      AGENT_MEM_PERCENT=7.8
    else
      CLAUDE_COUNT=2
      CLAUDE_RSS_KB=262144
      case "$TEST_MODE" in
        risk_cpu_hot)
          AGENT_CPU_PERCENT=150.0
          ;;
        risk_cpu_crit)
          AGENT_CPU_PERCENT=250.0
          ;;
        *)
          AGENT_CPU_PERCENT=65.0
          ;;
      esac
      AGENT_MEM_PERCENT=10.9
    fi
    CODEX_COUNT=1
    CODEX_RSS_KB=196608
    return
  fi

  eval "$(
    ps -eo pid=,ppid=,rss=,pcpu=,comm=,args= | awk -v monitor_pid="$MONITOR_PID" -v mem_total_kb="$MEM_TOTAL_KB" '
      function trim(s) {
        sub(/^[[:space:]]+/, "", s);
        sub(/[[:space:]]+$/, "", s);
        return s;
      }
      function is_agent_root(pid) {
        return comm[pid] == "claude" || comm[pid] == "codex";
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
      function sum_visible_cpu(pid, child_ids, n, i, child_pid, total) {
        if (hidden[pid]) {
          return 0;
        }

        total = cpu[pid];
        n = split(children[pid], child_ids, " ");
        for (i = 1; i <= n; i++) {
          child_pid = child_ids[i];
          if (child_pid != "") {
            total += sum_visible_cpu(child_pid);
          }
        }
        return total;
      }
      function sum_visible_rss(pid, child_ids, n, i, child_pid, total) {
        if (hidden[pid]) {
          return 0;
        }

        total = rss[pid];
        n = split(children[pid], child_ids, " ");
        for (i = 1; i <= n; i++) {
          child_pid = child_ids[i];
          if (child_pid != "") {
            total += sum_visible_rss(child_pid);
          }
        }
        return total;
      }
      {
        pid_val = $1;
        ppid_val = $2;
        rss_val = $3;
        cpu_val = $4;
        comm_val = $5;

        $1 = ""; $2 = ""; $3 = ""; $4 = ""; $5 = "";
        args_val = trim($0);

        pid[pid_val] = pid_val;
        ppid[pid_val] = ppid_val;
        rss[pid_val] = rss_val + 0;
        cpu[pid_val] = cpu_val + 0;
        comm[pid_val] = comm_val;
        args[pid_val] = args_val;
        children[ppid_val] = children[ppid_val] " " pid_val;

        if (comm_val == "claude" || comm_val == "codex") {
          root_order[++root_count] = pid_val;
        }
      }
      END {
        mark_hidden_chain(monitor_pid);
        mark_hidden_descendants(monitor_pid);

        for (i = 1; i <= root_count; i++) {
          pid_val = root_order[i];
          if (!hidden[pid_val]) {
            if (comm[pid_val] == "claude") {
              claude_count++;
              claude_rss += rss[pid_val];
            }
            if (comm[pid_val] == "codex") {
              codex_count++;
              codex_rss += rss[pid_val];
            }
            agent_cpu += sum_visible_cpu(pid_val);
            agent_rss += sum_visible_rss(pid_val);
          }
        }

        printf "CLAUDE_COUNT=%d\n", claude_count;
        printf "CLAUDE_RSS_KB=%d\n", claude_rss;
        printf "CODEX_COUNT=%d\n", codex_count;
        printf "CODEX_RSS_KB=%d\n", codex_rss;
        printf "AGENT_CPU_PERCENT=%.1f\n", agent_cpu;
        if (mem_total_kb > 0) {
          printf "AGENT_MEM_PERCENT=%.1f\n", (agent_rss / mem_total_kb) * 100.0;
        } else {
          printf "AGENT_MEM_PERCENT=0.0\n";
        }
      }
    '
  )"
}

collect_task_metrics() {
  case "$TEST_MODE" in
    diff|diff_title|resize|risk_warn|risk_hot|risk_crit|risk_cpu_hot|risk_cpu_crit|disk_warn|disk_hot)
      TASK_RUNNING_COUNT=2
      TASK_SLEEPING_COUNT=34
      TASK_STOPPED_COUNT=1
      TASK_ZOMBIE_COUNT=1
      TASK_TOTAL_COUNT=38
      return
      ;;
  esac

  eval "$(
    ps -e -o stat= | awk '
      /^[[:space:]]*$/ {
        next;
      }
      {
        state = substr($1, 1, 1);
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

render_process_header() {
  header_line=$(printf '%-6s %-6s %-7s %-6s %-*s %-6s %-*s %-9s %-*s' "PID" "PPID" "RSS_KB" "%MEM" "$PROCESS_MEM_BAR_FIELD_WIDTH" "MEM" "%CPU" "$PROCESS_CPU_BAR_FIELD_WIDTH" "CPU" "ROLE" "$PROCESS_COMMAND_WIDTH" "COMMAND")
  if [ "$STYLE_ENABLED" -eq 1 ]; then
    render_reverse_text_line "$header_line"
  else
    printf '%s\n' "$header_line"
  fi
}

render_process_tree() {
  render_process_header

  if [ "$TEST_MODE" = "diff" ] || [ "$TEST_MODE" = "diff_title" ] || [ "$TEST_MODE" = "resize" ] || [ "$TEST_MODE" = "risk_warn" ] || [ "$TEST_MODE" = "risk_hot" ] || [ "$TEST_MODE" = "risk_crit" ] || [ "$TEST_MODE" = "risk_cpu_hot" ] || [ "$TEST_MODE" = "risk_cpu_crit" ] || [ "$TEST_MODE" = "disk_warn" ] || [ "$TEST_MODE" = "disk_hot" ]; then
    sample_path=$(compact_home_path "/data/data/com.termux/files/home/A137442/example/project/index.ts")
    sample_mem_bar_low="$(render_bar 1.6 "$MEM_BAR_WIDTH" utilization)"
    sample_mem_bar_mid="$(render_bar 2.3 "$MEM_BAR_WIDTH" utilization)"
    sample_bar_low="$(render_bar 12.5 "$CPU_BAR_WIDTH" utilization)"
    sample_bar_mid="$(render_bar 55 "$CPU_BAR_WIDTH" utilization)"
    printf '%-6s %-6s %-7s %s %-*s %s %-*s %s %s\n' 1234 1 65536 "$(render_metric_field 1.6 utilization 6)" "$PROCESS_MEM_BAR_FIELD_WIDTH" "$sample_mem_bar_low" "$(render_metric_field 12.5 utilization 6)" "$PROCESS_CPU_BAR_FIELD_WIDTH" "$sample_bar_low" "$(render_role_field claude CLAUDE 9)" claude
    printf '%-6s %-6s %-7s %s %-*s %s %-*s %s %s\n' 1456 1234 4096 "$(render_metric_field 0.1 utilization 6)" "$PROCESS_MEM_BAR_FIELD_WIDTH" "$(render_bar 0.1 "$MEM_BAR_WIDTH" utilization)" "$(render_metric_field 4.0 utilization 6)" "$PROCESS_CPU_BAR_FIELD_WIDTH" "$(render_bar 4.0 "$CPU_BAR_WIDTH" utilization)" "$(render_role_field claude child 9)" "|- helper"
    printf '%-6s %-6s %-7s %s %-*s %s %-*s %s %s\n' 2345 1 98304 "$(render_metric_field 2.3 utilization 6)" "$PROCESS_MEM_BAR_FIELD_WIDTH" "$sample_mem_bar_mid" "$(render_metric_field 55.0 utilization 6)" "$PROCESS_CPU_BAR_FIELD_WIDTH" "$sample_bar_mid" "$(render_role_field codex CODEX 9)" "node $sample_path"
    printf '%-6s %-6s %-7s %s %-*s %s %-*s %s %s\n' 2456 2345 5120 "$(render_metric_field 0.1 utilization 6)" "$PROCESS_MEM_BAR_FIELD_WIDTH" "$(render_bar 0.1 "$MEM_BAR_WIDTH" utilization)" "$(render_metric_field 8.0 utilization 6)" "$PROCESS_CPU_BAR_FIELD_WIDTH" "$(render_bar 8.0 "$CPU_BAR_WIDTH" utilization)" "$(render_role_field codex child 9)" "|- worker"
    return
  fi

  ps -eo pid=,ppid=,rss=,pcpu=,comm=,args= --sort=-rss | awk -v monitor_pid="$MONITOR_PID" -v command_width="$PROCESS_COMMAND_WIDTH" -v home_prefix="$HOME" -v cpu_bar_width="$CPU_BAR_WIDTH" -v cpu_bar_field_width="$PROCESS_CPU_BAR_FIELD_WIDTH" -v mem_total_kb="$MEM_TOTAL_KB" -v mem_bar_width="$MEM_BAR_WIDTH" -v mem_bar_field_width="$PROCESS_MEM_BAR_FIELD_WIDTH" -v style_enabled="$STYLE_ENABLED" -v ansi_green="$ANSI_BRIGHT_GREEN" -v ansi_yellow="$ANSI_BRIGHT_YELLOW" -v ansi_red="$ANSI_BRIGHT_RED" -v ansi_claude="$ANSI_BRIGHT_CLAUDE" -v ansi_codex="$ANSI_BRIGHT_CODEX" -v ansi_reset="$ANSI_RESET" '
    function trim(s) {
      sub(/^[[:space:]]+/, "", s);
      sub(/[[:space:]]+$/, "", s);
      return s;
    }
    function is_agent_root(pid) {
      return comm[pid] == "claude" || comm[pid] == "codex";
    }
    function role_label(root_kind, depth) {
      if (depth == 0) {
        if (root_kind == "claude") {
          return "CLAUDE";
        }
        if (root_kind == "codex") {
          return "CODEX";
        }
      }
      return "child";
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
    function render_role_text(root_kind, depth, width, plain_text) {
      plain_text = sprintf("%-*s", width, role_label(root_kind, depth));
      return style_text(plain_text, role_color(root_kind));
    }
    function compact_home_path(text,    pos, result) {
      result = "";
      while ((pos = index(text, home_prefix)) > 0) {
        result = result substr(text, 1, pos - 1) "~";
        text = substr(text, pos + length(home_prefix));
      }
      return result text;
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
      summary = short_args(compact_home_path(args[pid]), command_width - length(prefix));
      mem_percent = safe_percent(rss[pid], mem_total_kb);
      if (depth == 0) {
        root_kind = comm[pid];
      }
      printf "%-6s %-6s %-7s %s %-*s %s %-*s %s %s%s\n",
        pid,
        ppid[pid],
        rss[pid],
        render_metric_text(mem_percent, "utilization", 6),
        mem_bar_field_width,
        render_bar(mem_percent, mem_bar_width, "utilization"),
        render_metric_text(cpu[pid], "utilization", 6),
        cpu_bar_field_width,
        render_bar(cpu[pid], cpu_bar_width, "utilization"),
        render_role_text(root_kind, depth, 9),
        prefix,
        summary;

      n = split(children[pid], child_ids, " ");
      for (i = 1; i <= n; i++) {
        child_pid = child_ids[i];
        if (child_pid != "" && !hidden[child_pid] && !printed[child_pid]) {
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
      comm_val = $5;

      $1 = ""; $2 = ""; $3 = ""; $4 = ""; $5 = "";
      args_val = trim($0);

      pid[pid_val] = pid_val;
      ppid[pid_val] = ppid_val;
      rss[pid_val] = rss_val;
      cpu[pid_val] = cpu_val;
      comm[pid_val] = comm_val;
      args[pid_val] = args_val;
      children[ppid_val] = children[ppid_val] " " pid_val;

      if (comm_val == "claude" || comm_val == "codex") {
        root_order[++root_count] = pid_val;
      }
    }
    END {
      mark_hidden_chain(monitor_pid);
      mark_hidden_descendants(monitor_pid);

      for (i = 1; i <= root_count; i++) {
        pid_val = root_order[i];
        if (!hidden[pid_val] && !printed[pid_val]) {
          printed[pid_val] = 1;
          print_node(pid_val, 0, comm[pid_val]);
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
  claude_rss_mib=$(to_mib "$CLAUDE_RSS_KB")
  codex_rss_mib=$(to_mib "$CODEX_RSS_KB")
  data_available_gib=$(awk -v blocks="$DATA_AVAILABLE_BLOCKS" 'BEGIN { printf "%.1f", blocks / 2097152.0 }')
  data_used_gib=$(awk -v blocks="$DATA_USED_BLOCKS" 'BEGIN { printf "%.1f", blocks / 2097152.0 }')
  mem_available_text="$mem_available_mib MiB free"
  swap_available_text="$swap_free_mib MiB free"
  data_available_text="$data_available_gib GiB free"
  mem_reference_text="$buffers_mib MiB buffers"
  swap_reference_text="$cached_mib MiB cached"
  data_reference_text="$data_used_gib GiB used"
  agent_cpu_cores=$(awk -v percent="$AGENT_CPU_PERCENT" 'BEGIN { printf "%.2f", percent / 100.0 }')
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
  claude_summary=$(render_colored_text "CLAUDE: $CLAUDE_COUNT proc  RSS $claude_rss_mib MiB" "$(role_color_code claude)")
  codex_summary=$(render_colored_text "CODEX: $CODEX_COUNT proc  RSS $codex_rss_mib MiB" "$(role_color_code codex)")

  if [ "$STYLE_ENABLED" -eq 1 ]; then
    render_title_bar "$now"
  else
    render_plain_header_line
    render_title_bar "$now"
    render_plain_header_line
  fi
  render_tasks_line "$TASK_TOTAL_COUNT" "$TASK_RUNNING_COUNT" "$TASK_SLEEPING_COUNT" "$TASK_STOPPED_COUNT" "$TASK_ZOMBIE_COUNT"
  render_resource_line "Mem:" "$MEM_AVAILABLE_PERCENT" availability "$mem_available_text" "$mem_reference_text" "$resource_bar_width" "$resource_available_width"
  render_resource_line "Swap:" "$SWAP_FREE_PERCENT" availability "$swap_available_text" "$swap_reference_text" "$resource_bar_width" "$resource_available_width"
  render_resource_line "/data:" "$DATA_FREE_PERCENT" disk_availability "$data_available_text" "$data_reference_text" "$resource_bar_width" "$resource_available_width"
  render_panel_lines_wrapped "$claude_summary    $codex_summary"
  render_panel_lines_wrapped "AgentsCPU: $(render_bar "$AGENT_CPU_PERCENT" "$SUMMARY_BAR_WIDTH" utilization) $(render_metric_text "$AGENT_CPU_PERCENT" utilization "%  ${agent_cpu_cores} cores")"
  render_panel_lines_wrapped "AgentsMem: $(render_bar "$AGENT_MEM_PERCENT" "$SUMMARY_BAR_WIDTH" utilization) $(render_metric_text "$AGENT_MEM_PERCENT" utilization "%")"
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
  printf '\033[?1049h\033[?25l'
}

leave_live_screen() {
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
  collect_system_metrics
  collect_agent_rollup
  collect_task_metrics
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
    configure_layout
    if [ "$RESIZE_PENDING" -eq 1 ] || [ "$PANEL_WIDTH" -ne "$previous_width" ] || [ "$PANEL_HEIGHT" -ne "$previous_height" ]; then
      PREVIOUS_FRAME=""
      RESIZE_PENDING=0
    fi

    current_frame=$(run_once)
    current_frame=$(clip_frame_to_terminal_height "$current_frame")
    printf '\033[H'
    render_frame_diff "$PREVIOUS_FRAME" "$current_frame"
    PREVIOUS_FRAME=$current_frame

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
