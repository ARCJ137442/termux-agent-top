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
    else
      CLAUDE_COUNT=2
      CLAUDE_RSS_KB=262144
    fi
    CODEX_COUNT=1
    CODEX_RSS_KB=196608
    return
  fi

  eval "$(
    ps -eo rss=,comm=,args= | awk '
      tolower($0) ~ /claude/ && tolower($0) !~ /awk|grep|rg/ {
        claude_count++;
        claude_rss += $1;
      }
      $2 == "codex" {
        codex_count++;
        codex_rss += $1;
      }
      END {
        printf "CLAUDE_COUNT=%d\n", claude_count;
        printf "CLAUDE_RSS_KB=%d\n", claude_rss;
        printf "CODEX_COUNT=%d\n", codex_count;
        printf "CODEX_RSS_KB=%d\n", codex_rss;
      }
    '
  )"
}

render_header_line() {
  width="$1"
  printf "+"
  repeat_char "=" "$((width - 2))"
  printf "+\n"
}

render_process_tree() {
  if [ "$TEST_MODE" = "diff" ]; then
    cat <<'EOF'
PID    PPID   RSS_KB  %CPU   ROLE      COMMAND
------ ------ ------- ------ --------- --------------------------------------------------------
1234   1      65536   0.0    CLAUDE    claude
2345   1      98304   0.0    CODEX     codex
EOF
    return
  fi

  ps -eo pid=,ppid=,rss=,pcpu=,comm=,args= --sort=-rss | awk -v monitor_pid="$MONITOR_PID" '
    function trim(s) {
      sub(/^[[:space:]]+/, "", s);
      sub(/[[:space:]]+$/, "", s);
      return s;
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
      if (length(text) <= max_len) {
        return text;
      }
      return substr(text, 1, max_len - 3) "...";
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
      summary = short_args(args[pid], 56);
      printf "%-6s %-6s %-7s %-6s %-9s %s%s\n",
        pid,
        ppid[pid],
        rss[pid],
        cpu[pid],
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
      for (pid_val in hidden) {
        mark_hidden_descendants(pid_val);
      }

      print "PID    PPID   RSS_KB  %CPU   ROLE      COMMAND";
      print "------ ------ ------- ------ --------- --------------------------------------------------------";
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

  render_header_line 116
  printf "| %-112s |\n" "TERMUX SYSTEM SNAPSHOT  $now"
  render_header_line 116
  printf "| RISK: %-5s  MemAvailable: %6s MiB [%s]  SwapFree: %6s MiB [%s]  /data: %3s%% used |\n" \
    "$RISK_LEVEL" \
    "$mem_available_mib" "$(bar "$MEM_AVAILABLE_PERCENT" 18)" \
    "$swap_free_mib" "$(bar "$SWAP_FREE_PERCENT" 18)" \
    "$DATA_USED_PERCENT"
  printf "| CLAUDE: %2s proc  RSS %6s MiB    CODEX: %2s proc  RSS %6s MiB    /data free: %5s GiB           |\n" \
    "$CLAUDE_COUNT" "$claude_rss_mib" "$CODEX_COUNT" "$codex_rss_mib" "$data_free_gib"
  render_header_line 116
  render_process_tree
  render_header_line 116
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
