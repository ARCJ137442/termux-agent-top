#!/usr/bin/env sh
set -eu

INTERVAL_SECONDS=2
RUN_ONCE=0
MONITOR_PID=$$
LIVE_SCREEN_ACTIVE=0
LOOP_ITERATION=0
PREVIOUS_FRAME=""
TEST_MODE="${CODEX_TOP_TEST_MODE:-}"
TEST_CYCLES="${CODEX_TOP_TEST_CYCLES:-0}"
DEFAULT_PANEL_WIDTH=300
MIN_PANEL_WIDTH=72
CPU_BAR_WIDTH=10
MEM_BAR_WIDTH=10
PROCESS_MEM_BAR_FIELD_WIDTH=$((MEM_BAR_WIDTH + 2))
PROCESS_CPU_BAR_FIELD_WIDTH=$((CPU_BAR_WIDTH + 2))
PROCESS_FIXED_WIDTH=$((6 + 1 + 6 + 1 + 7 + 1 + 6 + 1 + PROCESS_MEM_BAR_FIELD_WIDTH + 1 + 6 + 1 + PROCESS_CPU_BAR_FIELD_WIDTH + 1 + 9 + 1))
PANEL_WIDTH=$DEFAULT_PANEL_WIDTH
PANEL_INNER_WIDTH=$((PANEL_WIDTH - 4))
PROCESS_COMMAND_WIDTH=$((PANEL_WIDTH - PROCESS_FIXED_WIDTH))

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

detect_terminal_columns() {
  if [ -n "${COLUMNS:-}" ]; then
    printf '%s\n' "$COLUMNS"
    return
  fi

  stty size 2>/dev/null | awk 'NF >= 2 { print $2; exit }'
}

configure_layout() {
  terminal_columns=$(detect_terminal_columns)

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
      printf "#";
    }
    for (i = filled; i < width; i++) {
      printf "-";
    }
  }'
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

collect_system_metrics() {
  if [ "$TEST_MODE" = "diff" ]; then
    MEM_TOTAL_KB=4194304
    MEM_FREE_KB=1048576
    MEM_AVAILABLE_KB=2097152
    SWAP_TOTAL_KB=2097152
    SWAP_FREE_KB=1048576
    DATA_BLOCKS=4194304
    DATA_USED_BLOCKS=1048576
    DATA_AVAILABLE_BLOCKS=3145728
    DATA_USED_PERCENT=25
    MEM_AVAILABLE_PERCENT=50.0
    SWAP_USED_KB=1048576
    SWAP_FREE_PERCENT=50.0
    RISK_LEVEL="OK"
    return
  fi

  eval "$(
    awk '
      /MemTotal:/ { print "MEM_TOTAL_KB=" $2 }
      /MemFree:/ { print "MEM_FREE_KB=" $2 }
      /MemAvailable:/ { print "MEM_AVAILABLE_KB=" $2 }
      /SwapTotal:/ { print "SWAP_TOTAL_KB=" $2 }
      /SwapFree:/ { print "SWAP_FREE_KB=" $2 }
    ' /proc/meminfo
  )"

  DATA_DF_LINE=$(df -P /data | awk 'NR == 2 { print $2 " " $3 " " $4 " " $5 }')
  DATA_BLOCKS=$(printf '%s\n' "$DATA_DF_LINE" | awk '{ print $1 }')
  DATA_USED_BLOCKS=$(printf '%s\n' "$DATA_DF_LINE" | awk '{ print $2 }')
  DATA_AVAILABLE_BLOCKS=$(printf '%s\n' "$DATA_DF_LINE" | awk '{ print $3 }')
  DATA_USED_PERCENT=$(printf '%s\n' "$DATA_DF_LINE" | awk '{ gsub(/%/, "", $4); print $4 }')

  MEM_AVAILABLE_PERCENT=$(safe_percent "$MEM_AVAILABLE_KB" "$MEM_TOTAL_KB")
  SWAP_USED_KB=$((SWAP_TOTAL_KB - SWAP_FREE_KB))
  SWAP_FREE_PERCENT=$(safe_percent "$SWAP_FREE_KB" "$SWAP_TOTAL_KB")

  if [ "$MEM_AVAILABLE_KB" -lt 1048576 ] || [ "$DATA_USED_PERCENT" -ge 90 ]; then
    RISK_LEVEL="HOT"
  elif [ "$MEM_AVAILABLE_KB" -lt 1572864 ] || [ "$DATA_USED_PERCENT" -ge 88 ]; then
    RISK_LEVEL="WARN"
  else
    RISK_LEVEL="OK"
  fi
}

collect_agent_rollup() {
  if [ "$TEST_MODE" = "diff" ]; then
    if [ "$LOOP_ITERATION" -le 1 ]; then
      CLAUDE_COUNT=1
      CLAUDE_RSS_KB=131072
      AGENT_CPU_PERCENT=55.0
      AGENT_MEM_PERCENT=7.8
    else
      CLAUDE_COUNT=2
      CLAUDE_RSS_KB=262144
      AGENT_CPU_PERCENT=65.0
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

render_header_line() {
  printf "+"
  repeat_char "=" "$((PANEL_WIDTH - 2))"
  printf "+\n"
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

render_panel_lines_wrapped() {
  content="$1"
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

render_process_tree() {
  if [ "$TEST_MODE" = "diff" ]; then
    sample_path=$(compact_home_path "/data/data/com.termux/files/home/A137442/example/project/index.ts")
    sample_mem_bar_low="[$(bar 1.6 "$MEM_BAR_WIDTH")]"
    sample_mem_bar_mid="[$(bar 2.3 "$MEM_BAR_WIDTH")]"
    sample_bar_low="[$(bar 12.5 "$CPU_BAR_WIDTH")]"
    sample_bar_mid="[$(bar 55 "$CPU_BAR_WIDTH")]"
    printf '%-6s %-6s %-7s %-6s %-*s %-6s %-*s %-9s %s\n' PID PPID RSS_KB %MEM "$PROCESS_MEM_BAR_FIELD_WIDTH" MEM %CPU "$PROCESS_CPU_BAR_FIELD_WIDTH" CPU ROLE COMMAND
    printf '%-6s %-6s %-7s %-6s %-*s %-6s %-*s %-9s %s\n' ------ ------ ------- ------ "$PROCESS_MEM_BAR_FIELD_WIDTH" ------------ ------ "$PROCESS_CPU_BAR_FIELD_WIDTH" ------------ --------- --------------------------------------------------------
    printf '%-6s %-6s %-7s %-6s %-*s %-6s %-*s %-9s %s\n' 1234 1 65536 1.6 "$PROCESS_MEM_BAR_FIELD_WIDTH" "$sample_mem_bar_low" 12.5 "$PROCESS_CPU_BAR_FIELD_WIDTH" "$sample_bar_low" CLAUDE claude
    printf '%-6s %-6s %-7s %-6s %-*s %-6s %-*s %-9s %s\n' 2345 1 98304 2.3 "$PROCESS_MEM_BAR_FIELD_WIDTH" "$sample_mem_bar_mid" 55.0 "$PROCESS_CPU_BAR_FIELD_WIDTH" "$sample_bar_mid" CODEX "node $sample_path"
    return
  fi

  ps -eo pid=,ppid=,rss=,pcpu=,comm=,args= --sort=-rss | awk -v monitor_pid="$MONITOR_PID" -v command_width="$PROCESS_COMMAND_WIDTH" -v home_prefix="$HOME" -v cpu_bar_width="$CPU_BAR_WIDTH" -v cpu_bar_field_width="$PROCESS_CPU_BAR_FIELD_WIDTH" -v mem_total_kb="$MEM_TOTAL_KB" -v mem_bar_width="$MEM_BAR_WIDTH" -v mem_bar_field_width="$PROCESS_MEM_BAR_FIELD_WIDTH" '
    function trim(s) {
      sub(/^[[:space:]]+/, "", s);
      sub(/[[:space:]]+$/, "", s);
      return s;
    }
    function repeat_str(char, count,    out, i) {
      out = "";
      for (i = 0; i < count; i++) {
        out = out char;
      }
      return out;
    }
    function is_agent_root(pid) {
      return comm[pid] == "claude" || comm[pid] == "codex";
    }
    function role_label(pid, depth) {
      if (depth == 0) {
        if (comm[pid] == "claude") {
          return "CLAUDE";
        }
        if (comm[pid] == "codex") {
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

      bar_text = "[";
      for (i = 0; i < filled; i++) {
        bar_text = bar_text "#";
      }
      for (i = filled; i < width; i++) {
        bar_text = bar_text "-";
      }
      return bar_text "]";
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
    function print_node(pid, depth, prefix, child_ids, n, i, child_pid, summary) {
      prefix = "";
      for (i = 0; i < depth; i++) {
        prefix = prefix "  ";
      }
      if (depth > 0) {
        prefix = prefix "|- ";
      }
      summary = short_args(compact_home_path(args[pid]), command_width - length(prefix));
      mem_percent = safe_percent(rss[pid], mem_total_kb);
      printf "%-6s %-6s %-7s %-6.1f %-*s %-6s %-*s %-9s %s%s\n",
        pid,
        ppid[pid],
        rss[pid],
        mem_percent,
        mem_bar_field_width,
        cpu_bar(mem_percent, mem_bar_width),
        cpu[pid],
        cpu_bar_field_width,
        cpu_bar(cpu[pid], cpu_bar_width),
        role_label(pid, depth),
        prefix,
        summary;

      n = split(children[pid], child_ids, " ");
      for (i = 1; i <= n; i++) {
        child_pid = child_ids[i];
        if (child_pid != "" && !hidden[child_pid] && !printed[child_pid]) {
          printed[child_pid] = 1;
          print_node(child_pid, depth + 1);
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

      printf "%-6s %-6s %-7s %-6s %-*s %-6s %-*s %-9s %-*s\n", "PID", "PPID", "RSS_KB", "%MEM", mem_bar_field_width, "MEM", "%CPU", cpu_bar_field_width, "CPU", "ROLE", command_width, "COMMAND";
      printf "%-6s %-6s %-7s %-6s %-*s %-6s %-*s %-9s %s\n", "------", "------", "-------", "------", mem_bar_field_width, repeat_str("-", mem_bar_field_width), "------", cpu_bar_field_width, repeat_str("-", cpu_bar_field_width), "---------", repeat_str("-", command_width);
      for (i = 1; i <= root_count; i++) {
        pid_val = root_order[i];
        if (!hidden[pid_val] && !printed[pid_val]) {
          printed[pid_val] = 1;
          print_node(pid_val, 0);
        }
      }
    }
  '
}

render_dashboard() {
  if [ "$TEST_MODE" = "diff" ]; then
    now='2026-03-12 00:00:00 CST'
  else
    now=$(date '+%F %T %Z')
  fi
  mem_available_mib=$(to_mib "$MEM_AVAILABLE_KB")
  mem_total_mib=$(to_mib "$MEM_TOTAL_KB")
  swap_free_mib=$(to_mib "$SWAP_FREE_KB")
  swap_total_mib=$(to_mib "$SWAP_TOTAL_KB")
  claude_rss_mib=$(to_mib "$CLAUDE_RSS_KB")
  codex_rss_mib=$(to_mib "$CODEX_RSS_KB")
  data_free_gib=$(awk -v blocks="$DATA_AVAILABLE_BLOCKS" 'BEGIN { printf "%.1f", blocks / 2097152.0 }')

  render_header_line
  render_panel_line "TERMUX SYSTEM SNAPSHOT  $now"
  render_header_line
  render_panel_lines_wrapped "RISK: $RISK_LEVEL  MemAvailable: $mem_available_mib MiB [$(bar "$MEM_AVAILABLE_PERCENT" 12)]  SwapFree: $swap_free_mib MiB [$(bar "$SWAP_FREE_PERCENT" 12)]  /data: $DATA_USED_PERCENT% used"
  render_panel_lines_wrapped "CLAUDE: $CLAUDE_COUNT proc  RSS $claude_rss_mib MiB    CODEX: $CODEX_COUNT proc  RSS $codex_rss_mib MiB    /data free: $data_free_gib GiB"
  render_panel_lines_wrapped "AgentsCPU: $AGENT_CPU_PERCENT [$(bar "$AGENT_CPU_PERCENT" "$CPU_BAR_WIDTH")]"
  render_panel_lines_wrapped "AgentsMem: $AGENT_MEM_PERCENT [$(bar "$AGENT_MEM_PERCENT" "$MEM_BAR_WIDTH")]"
  render_header_line
  render_process_tree
  render_header_line
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

run_once() {
  collect_system_metrics
  collect_agent_rollup
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
          printf "%s\033[K", current_lines[i];
        } else {
          printf "\033[K";
        }
      }
    }

    if (current_count < previous_count) {
      printf "\033[%d;1H\033[J", current_count + 1;
    }
  }'
}

run_loop() {
  trap 'leave_live_screen' EXIT INT TERM HUP
  enter_live_screen

  while :; do
    LOOP_ITERATION=$((LOOP_ITERATION + 1))
    current_frame=$(run_once)
    printf '\033[H'
    render_frame_diff "$PREVIOUS_FRAME" "$current_frame"
    PREVIOUS_FRAME=$current_frame

    if [ "$TEST_CYCLES" -gt 0 ] && [ "$LOOP_ITERATION" -ge "$TEST_CYCLES" ]; then
      break
    fi

    sleep "$INTERVAL_SECONDS"
  done
}

if [ "$RUN_ONCE" -eq 1 ]; then
  run_once
else
  run_loop
fi
