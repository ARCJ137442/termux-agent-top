#!/usr/bin/env sh
set -eu

ROOT="/data/data/com.termux/files/home/A137442/termux-tools"
SCRIPT="$ROOT/agent-top.sh"

if [ ! -x "$SCRIPT" ]; then
  echo "FAIL: missing executable script at $SCRIPT" >&2
  exit 1
fi

output=$("$SCRIPT" --once)
styled_output=$(CODEX_TOP_FORCE_STYLE=1 "$SCRIPT" --once)
plain_diff_output=$(CODEX_TOP_TEST_MODE=diff "$SCRIPT" --once)
styled_diff_output=$(CODEX_TOP_FORCE_STYLE=1 CODEX_TOP_TEST_MODE=diff "$SCRIPT" --once)
styled_risk_warn_output=$(CODEX_TOP_FORCE_STYLE=1 CODEX_TOP_TEST_MODE=risk_warn "$SCRIPT" --once)
styled_risk_hot_output=$(CODEX_TOP_FORCE_STYLE=1 CODEX_TOP_TEST_MODE=risk_hot "$SCRIPT" --once)
styled_risk_crit_output=$(CODEX_TOP_FORCE_STYLE=1 CODEX_TOP_TEST_MODE=risk_crit "$SCRIPT" --once)
styled_risk_cpu_hot_output=$(CODEX_TOP_FORCE_STYLE=1 CODEX_TOP_TEST_MODE=risk_cpu_hot "$SCRIPT" --once)
styled_risk_cpu_crit_output=$(CODEX_TOP_FORCE_STYLE=1 CODEX_TOP_TEST_MODE=risk_cpu_crit "$SCRIPT" --once)
styled_disk_warn_output=$(CODEX_TOP_FORCE_STYLE=1 CODEX_TOP_TEST_MODE=disk_warn "$SCRIPT" --once)
styled_disk_hot_output=$(CODEX_TOP_FORCE_STYLE=1 CODEX_TOP_TEST_MODE=disk_hot "$SCRIPT" --once)
styled_fps_integer_output=$(COLUMNS=80 CODEX_TOP_FORCE_STYLE=1 "$SCRIPT" --once --interval 0.25)
styled_fps_fraction_output=$(COLUMNS=80 CODEX_TOP_FORCE_STYLE=1 "$SCRIPT" --once --interval 8)
fps_output=$(COLUMNS=90 "$SCRIPT" --once --interval 2)
fps_zero_output=$("$SCRIPT" --once --interval 0)
reverse_ansi=$(printf '\033[7m')
bold_ansi=$(printf '\033[1m')
green_ansi=$(printf '\033[92m')
yellow_ansi=$(printf '\033[93m')
red_ansi=$(printf '\033[91m')
dark_green_ansi=$(printf '\033[32m')
orange_ansi=$(printf '\033[38;2;255;170;0m')
cyan_ansi=$(printf '\033[38;2;110;235;255m')
reset_ansi=$(printf '\033[0m')
resource_bar_50=$(awk 'BEGIN {
  for (i = 0; i < 25; i++) {
    printf "█";
  }
  for (i = 0; i < 25; i++) {
    printf "░";
  }
  printf "\n";
}')

set +e
invalid_interval_output=$("$SCRIPT" --once --interval -1 2>&1)
invalid_interval_status=$?
set -e

if [ "$invalid_interval_status" -eq 0 ]; then
  echo "FAIL: negative interval values should be rejected" >&2
  exit 1
fi

if ! printf '%s\n' "$invalid_interval_output" | grep -F "interval must be a non-negative number" >/dev/null 2>&1; then
  echo "FAIL: negative interval rejection should explain the constraint" >&2
  exit 1
fi

fps_title_line=$(printf '%s\n' "$fps_output" | sed -n '2p')
case "$fps_title_line" in
  *"FPS: 0.5  RISK: "*)
    ;;
  *)
    echo "FAIL: title line should show right-aligned FPS followed by RISK in plain output" >&2
    exit 1
    ;;
esac

fps_zero_title_line=$(printf '%s\n' "$fps_zero_output" | sed -n '2p')
case "$fps_zero_title_line" in
  *"FPS: max  RISK: "*)
    ;;
  *)
    echo "FAIL: title line should show 'FPS: max' followed by RISK in plain output" >&2
    exit 1
    ;;
esac

styled_integer_title_line=$(printf '%s\n' "$styled_fps_integer_output" | grep -F "TERMUX SYSTEM SNAPSHOT" | head -n 1)
if ! printf '%s' "$styled_integer_title_line" | grep -F "FPS: 4" >/dev/null 2>&1; then
  echo "FAIL: styled title should keep the integer FPS value on the title bar" >&2
  exit 1
fi

if ! printf '%s' "$styled_integer_title_line" | grep -F "RISK:" >/dev/null 2>&1; then
  echo "FAIL: styled title should place the RISK badge on the title bar" >&2
  exit 1
fi

styled_fraction_title_line=$(printf '%s\n' "$styled_fps_fraction_output" | grep -F "TERMUX SYSTEM SNAPSHOT" | head -n 1)
if ! printf '%s' "$styled_fraction_title_line" | grep -F "FPS: 0.125" >/dev/null 2>&1; then
  echo "FAIL: styled title should keep the fractional FPS value on the title bar" >&2
  exit 1
fi

for pattern in "TERMUX SYSTEM SNAPSHOT" "Tasks:" "Mem:" "Swap:" "CLAUDE" "CODEX" "AgentsMem:" "PID" "%MEM"; do
  if ! printf '%s\n' "$output" | grep -F "$pattern" >/dev/null 2>&1; then
    echo "FAIL: missing pattern '$pattern'" >&2
    exit 1
  fi
done

plain_tasks_line=$(printf '%s\n' "$plain_diff_output" | awk '/Tasks:/ { print; exit }')
if ! printf '%s' "$plain_tasks_line" | grep -F "Tasks:" >/dev/null 2>&1; then
  echo "FAIL: plain diff output should render a dedicated Tasks line" >&2
  exit 1
fi

if ! printf '%s' "$plain_tasks_line" | grep -F "sleeping" >/dev/null 2>&1; then
  echo "FAIL: plain diff Tasks line should preserve readable task-state labels" >&2
  exit 1
fi

if ! printf '%s' "$plain_tasks_line" | grep -F "38 total" >/dev/null 2>&1; then
  echo "FAIL: plain diff Tasks line should show the total task count at the end" >&2
  exit 1
fi

if printf '%s' "$plain_tasks_line" | grep -F "$reverse_ansi" >/dev/null 2>&1; then
  echo "FAIL: plain diff Tasks line should not emit reverse-video ANSI sequences" >&2
  exit 1
fi

if ! printf '%s\n' "$output" | grep -F "█" >/dev/null 2>&1; then
  echo "FAIL: output should render block-style utilization bars" >&2
  exit 1
fi

resource_bar_positions=$(
  printf '%s\n' "$output" | awk '
    $0 ~ /^\| Mem:/ {
      mem = index($0, "█");
      if (mem == 0) {
        mem = index($0, "░");
      }
    }
    $0 ~ /^\| Swap:/ {
      swap = index($0, "█");
      if (swap == 0) {
        swap = index($0, "░");
      }
    }
    $0 ~ /^\| \/data:/ {
      data = index($0, "█");
      if (data == 0) {
        data = index($0, "░");
      }
    }
    END {
      printf "%d %d %d\n", mem, swap, data;
    }
  '
)
set -- $resource_bar_positions
if [ "$1" -ne "$2" ] || [ "$1" -ne "$3" ]; then
  echo "FAIL: Mem, Swap, and /data progress bars should start at the same column" >&2
  exit 1
fi

if ! printf '%s\n' "$plain_diff_output" | grep -F "$resource_bar_50" >/dev/null 2>&1; then
  echo "FAIL: wide resource lines should expand to a 50-slot progress bar" >&2
  exit 1
fi

if ! printf '%s' "$styled_diff_output" | grep -F "${green_ansi}███████████░░░░░░░░░${reset_ansi}" >/dev/null 2>&1; then
  echo "FAIL: forced diff output should color the full 20-slot summary bar with one ANSI color" >&2
  exit 1
fi

if ! printf '%s' "$styled_diff_output" | grep -F "${green_ansi}55.0%  0.55 cores${reset_ansi}" >/dev/null 2>&1; then
  echo "FAIL: forced diff output should append and color core-equivalent utilization after the AgentsCPU percentage" >&2
  exit 1
fi

if ! printf '%s' "$styled_diff_output" | grep -F "${green_ansi}12.5" >/dev/null 2>&1; then
  echo "FAIL: forced diff output should color process utilization numbers with the same color as their bars" >&2
  exit 1
fi

if ! printf '%s' "$styled_diff_output" | grep -F "${orange_ansi}CLAUDE" >/dev/null 2>&1; then
  echo "FAIL: forced diff output should color CLAUDE roles bright orange" >&2
  exit 1
fi

if ! printf '%s' "$styled_diff_output" | grep -F "${cyan_ansi}CODEX" >/dev/null 2>&1; then
  echo "FAIL: forced diff output should color CODEX roles bright cyan" >&2
  exit 1
fi

if ! printf '%s' "$styled_diff_output" | grep -F "${orange_ansi}child" >/dev/null 2>&1; then
  echo "FAIL: forced diff output should color Claude child roles bright orange" >&2
  exit 1
fi

if ! printf '%s' "$styled_diff_output" | grep -F "${cyan_ansi}child" >/dev/null 2>&1; then
  echo "FAIL: forced diff output should color Codex child roles bright cyan" >&2
  exit 1
fi

if ! printf '%s' "$styled_diff_output" | grep -F "${orange_ansi}CLAUDE: 1 proc  RSS 128.0 MiB${reset_ansi}" >/dev/null 2>&1; then
  echo "FAIL: forced diff output should color the CLAUDE agent summary segment bright orange" >&2
  exit 1
fi

if ! printf '%s' "$styled_diff_output" | grep -F "${cyan_ansi}CODEX: 1 proc  RSS 192.0 MiB${reset_ansi}" >/dev/null 2>&1; then
  echo "FAIL: forced diff output should color the CODEX agent summary segment bright cyan" >&2
  exit 1
fi

if ! printf '%s' "$styled_diff_output" | grep -F "/data:" >/dev/null 2>&1; then
  echo "FAIL: forced diff output should render a dedicated /data summary line" >&2
  exit 1
fi

if ! printf '%s' "$styled_diff_output" | grep -F "${green_ansi} 75.0%${reset_ansi}  1.5 GiB free     0.5 GiB used" >/dev/null 2>&1; then
  echo "FAIL: forced diff output should align /data with the Mem/Swap field order and spacing" >&2
  exit 1
fi

if printf '%s' "$styled_diff_output" | grep -F "/data free:" >/dev/null 2>&1; then
  echo "FAIL: forced diff output should not use the old '/data free:' label" >&2
  exit 1
fi

if printf '%s' "$styled_diff_output" | grep -F "/data: 25% used" >/dev/null 2>&1; then
  echo "FAIL: forced diff output should not repeat the old trailing '/data: XX% used' format" >&2
  exit 1
fi

if printf '%s' "$styled_diff_output" | grep -F "/data:" | grep -F "${orange_ansi}CLAUDE" >/dev/null 2>&1; then
  echo "FAIL: forced diff output should keep the dedicated /data line separate from the agent summary line" >&2
  exit 1
fi

if ! printf '%s' "$styled_disk_warn_output" | grep -F "${yellow_ansi} 14.0%${reset_ansi}" >/dev/null 2>&1; then
  echo "FAIL: /data free percentages below 15% should render yellow" >&2
  exit 1
fi

if ! printf '%s' "$styled_disk_hot_output" | grep -F "${red_ansi}  4.0%${reset_ansi}" >/dev/null 2>&1; then
  echo "FAIL: /data free percentages below 5% should render red" >&2
  exit 1
fi

title_line=$(printf '%s\n' "$styled_output" | grep -F "TERMUX SYSTEM SNAPSHOT" | head -n 1)
if ! printf '%s' "$title_line" | grep -F "$reverse_ansi" >/dev/null 2>&1; then
  echo "FAIL: forced-style output should render the title line in reverse video" >&2
  exit 1
fi

if ! printf '%s' "$title_line" | grep -F "${bold_ansi}TERMUX SYSTEM SNAPSHOT" >/dev/null 2>&1; then
  echo "FAIL: forced-style output should render the main title in bold" >&2
  exit 1
fi

reverse_line_count=$(
  printf '%s\n' "$styled_output" | awk -v reverse="$reverse_ansi" 'index($0, reverse) > 0 { count++ } END { print count + 0 }'
)
if [ "$reverse_line_count" -ne 3 ]; then
  echo "FAIL: forced-style output should keep reverse video on the title line, Tasks line, and table header only" >&2
  exit 1
fi

table_header_line=$(printf '%s\n' "$styled_output" | grep -F "PID" | head -n 1)
if ! printf '%s' "$table_header_line" | grep -F "$reverse_ansi" >/dev/null 2>&1; then
  echo "FAIL: forced-style output should render the process table header in reverse video" >&2
  exit 1
fi

styled_tasks_line=$(printf '%s\n' "$styled_diff_output" | sed -n '2p')
if ! printf '%s' "$styled_tasks_line" | grep -F "Tasks:" >/dev/null 2>&1; then
  echo "FAIL: styled output should render Tasks immediately below the title bar" >&2
  exit 1
fi

if ! printf '%s' "$styled_tasks_line" | grep -F "${green_ansi}${reverse_ansi}ru${reset_ansi}" >/dev/null 2>&1; then
  echo "FAIL: Tasks line should render running tasks as a bright-green reverse segment with truncated text when narrow" >&2
  exit 1
fi

if ! printf '%s' "$styled_tasks_line" | grep -F "${orange_ansi}${reverse_ansi}sleeping" >/dev/null 2>&1; then
  echo "FAIL: Tasks line should render sleeping tasks as a bright-orange reverse segment" >&2
  exit 1
fi

if ! printf '%s' "$styled_tasks_line" | grep -F "${red_ansi}${reverse_ansi}s${reset_ansi}" >/dev/null 2>&1; then
  echo "FAIL: Tasks line should render stopped tasks as a bright-red reverse segment" >&2
  exit 1
fi

if ! printf '%s' "$styled_tasks_line" | grep -F "${dark_green_ansi}${reverse_ansi}z${reset_ansi}" >/dev/null 2>&1; then
  echo "FAIL: Tasks line should render zombie tasks as a dark-green reverse segment" >&2
  exit 1
fi

if ! printf '%s' "$styled_tasks_line" | grep -F "38 total" >/dev/null 2>&1; then
  echo "FAIL: Tasks line should end with the total task count" >&2
  exit 1
fi

styled_mem_after_tasks=$(printf '%s\n' "$styled_diff_output" | sed -n '3p')
if ! printf '%s' "$styled_mem_after_tasks" | grep -F "Mem:" >/dev/null 2>&1; then
  echo "FAIL: Mem should move below the new Tasks line" >&2
  exit 1
fi

ok_title_line=$(printf '%s\n' "$styled_diff_output" | grep -F "TERMUX SYSTEM SNAPSHOT" | head -n 1)
if ! printf '%s' "$ok_title_line" | grep -F "${green_ansi}${bold_ansi}RISK: OK" >/dev/null 2>&1; then
  echo "FAIL: forced-style output should render a green bold RISK badge on the title bar for OK state" >&2
  exit 1
fi

if ! printf '%s' "$ok_title_line" | awk 'index($0, "FPS:") > 0 && index($0, "RISK:") > index($0, "FPS:") { found = 1 } END { exit found ? 0 : 1 }'; then
  echo "FAIL: title bar should place FPS to the left of the RISK badge" >&2
  exit 1
fi

mem_line=$(printf '%s\n' "$styled_diff_output" | awk '/^Mem:/ { print; exit }')
if ! printf '%s' "$mem_line" | grep -F "2048.0 MiB free  64.0 MiB buffers" >/dev/null 2>&1; then
  echo "FAIL: Mem line content should stay frozen apart from spacing alignment" >&2
  exit 1
fi

if ! printf '%s' "$mem_line" | grep -F "${green_ansi} 50.0%${reset_ansi}" >/dev/null 2>&1; then
  echo "FAIL: Mem line should show a colored percentage immediately after the progress bar" >&2
  exit 1
fi

swap_line=$(printf '%s\n' "$styled_diff_output" | awk '/^Swap:/ { print; exit }')
if ! printf '%s' "$swap_line" | grep -F "1024.0 MiB free  512.0 MiB cached" >/dev/null 2>&1; then
  echo "FAIL: Swap line content should stay frozen apart from spacing alignment" >&2
  exit 1
fi

if ! printf '%s' "$swap_line" | grep -F "${green_ansi} 50.0%${reset_ansi}" >/dev/null 2>&1; then
  echo "FAIL: Swap line should show a colored percentage immediately after the progress bar" >&2
  exit 1
fi

data_line=$(printf '%s\n' "$styled_diff_output" | awk '/^\/data:/ { print; exit }')
if ! printf '%s' "$data_line" | grep -F "1.5 GiB free     0.5 GiB used" >/dev/null 2>&1; then
  echo "FAIL: /data line should match the Mem/Swap field ordering with free space followed by used space" >&2
  exit 1
fi

if printf '%s\n' "$styled_diff_output" | grep -F "MemAvailable:" >/dev/null 2>&1; then
  echo "FAIL: forced diff output should replace the old MemAvailable summary label with a dedicated Mem line" >&2
  exit 1
fi

if printf '%s\n' "$styled_diff_output" | grep -F "SwapFree:" >/dev/null 2>&1; then
  echo "FAIL: forced diff output should replace the old SwapFree summary label with a dedicated Swap line" >&2
  exit 1
fi

warn_title_line=$(printf '%s\n' "$styled_risk_warn_output" | grep -F "TERMUX SYSTEM SNAPSHOT" | head -n 1)
if ! printf '%s' "$warn_title_line" | grep -F "${yellow_ansi}${bold_ansi}RISK: WARN" >/dev/null 2>&1; then
  echo "FAIL: forced-style output should render a yellow bold RISK badge on the title bar for WARN state" >&2
  exit 1
fi

hot_title_line=$(printf '%s\n' "$styled_risk_hot_output" | grep -F "TERMUX SYSTEM SNAPSHOT" | head -n 1)
if ! printf '%s' "$hot_title_line" | grep -F "${orange_ansi}${bold_ansi}RISK: HOT" >/dev/null 2>&1; then
  echo "FAIL: forced-style output should render an orange bold RISK badge on the title bar for HOT state" >&2
  exit 1
fi

crit_title_line=$(printf '%s\n' "$styled_risk_crit_output" | grep -F "TERMUX SYSTEM SNAPSHOT" | head -n 1)
if ! printf '%s' "$crit_title_line" | grep -F "${red_ansi}${bold_ansi}RISK: CRIT" >/dev/null 2>&1; then
  echo "FAIL: forced-style output should render a red bold RISK badge on the title bar for CRIT state" >&2
  exit 1
fi

cpu_hot_title_line=$(printf '%s\n' "$styled_risk_cpu_hot_output" | grep -F "TERMUX SYSTEM SNAPSHOT" | head -n 1)
if ! printf '%s' "$cpu_hot_title_line" | grep -F "${orange_ansi}${bold_ansi}RISK: HOT" >/dev/null 2>&1; then
  echo "FAIL: AgentsCPU values above 100% should elevate RISK to HOT even when memory and disk are healthy" >&2
  exit 1
fi

if ! printf '%s\n' "$styled_risk_cpu_hot_output" | grep -F "AgentsCPU:" | grep -F "150.0%" >/dev/null 2>&1; then
  echo "FAIL: CPU-driven HOT test mode should expose an AgentsCPU sample above 100%" >&2
  exit 1
fi

if ! printf '%s\n' "$styled_risk_cpu_hot_output" | grep -F "AgentsCPU:" | grep -F "1.50 cores" >/dev/null 2>&1; then
  echo "FAIL: CPU-driven HOT test mode should append core-equivalent utilization after AgentsCPU percent" >&2
  exit 1
fi

cpu_crit_title_line=$(printf '%s\n' "$styled_risk_cpu_crit_output" | grep -F "TERMUX SYSTEM SNAPSHOT" | head -n 1)
if ! printf '%s' "$cpu_crit_title_line" | grep -F "${red_ansi}${bold_ansi}RISK: CRIT" >/dev/null 2>&1; then
  echo "FAIL: AgentsCPU values above 200% should elevate RISK to CRIT even when memory and disk are healthy" >&2
  exit 1
fi

if ! printf '%s\n' "$styled_risk_cpu_crit_output" | grep -F "AgentsCPU:" | grep -F "250.0%" >/dev/null 2>&1; then
  echo "FAIL: CPU-driven CRIT test mode should expose an AgentsCPU sample above 200%" >&2
  exit 1
fi

if ! printf '%s\n' "$styled_risk_cpu_crit_output" | grep -F "AgentsCPU:" | grep -F "2.50 cores" >/dev/null 2>&1; then
  echo "FAIL: CPU-driven CRIT test mode should append core-equivalent utilization after AgentsCPU percent" >&2
  exit 1
fi

if printf '%s\n' "$styled_output" | grep -F "------ ------ -------" >/dev/null 2>&1; then
  echo "FAIL: forced-style output should remove the dashed separator below the table header" >&2
  exit 1
fi

if printf '%s\n' "$styled_output" | grep -F "+====" >/dev/null 2>&1; then
  echo "FAIL: forced-style output should remove ASCII divider lines around the title and table" >&2
  exit 1
fi

reported_agents_mem=$(
  printf '%s\n' "$output" | sed -n 's/.*AgentsMem: .* \([0-9.][0-9.]*%\).*/\1/p' | sed 's/%$//' | head -n 1
)
mem_total_kb=$(awk '/MemTotal:/ { print $2; exit }' /proc/meminfo)
agent_root_rss_kb=$(ps -eo comm=,rss= | awk '$1 == "claude" || $1 == "codex" { rss += $2 } END { print rss + 0 }')
minimum_agents_mem=$(
  awk -v rss="$agent_root_rss_kb" -v total="$mem_total_kb" 'BEGIN {
    if (total <= 0) {
      printf "0.0";
    } else {
      printf "%.1f", (rss / total) * 100.0;
    }
  }'
)

if [ -n "$reported_agents_mem" ] && [ "$minimum_agents_mem" != "0.0" ] && [ "$reported_agents_mem" = "0.0" ]; then
  echo "FAIL: AgentsMem should not be 0.0 when visible agent RSS already implies a non-zero percentage" >&2
  exit 1
fi

if ! printf '%s\n' "$output" | awk 'length($0) > 300 { exit 1 }'; then
  echo "FAIL: one-shot output should fit within the 300-column panel width" >&2
  exit 1
fi

wide_output=$(COLUMNS=300 "$SCRIPT" --once)

if ! printf '%s\n' "$wide_output" | awk 'length($0) > 300 { exit 1 }'; then
  echo "FAIL: wide output should respect the 300-column panel limit" >&2
  exit 1
fi

if [ "$(printf '%s\n' "$wide_output" | sed -n '1p' | awk '{ print length($0) }')" -ne 300 ]; then
  echo "FAIL: wide output should expand the panel width up to 300 columns" >&2
  exit 1
fi

narrow_output=$(COLUMNS=90 "$SCRIPT" --once)

if ! printf '%s\n' "$narrow_output" | awk 'length($0) > 90 { exit 1 }'; then
  echo "FAIL: one-shot output should adapt to narrow terminal widths" >&2
  exit 1
fi

if ! printf '%s\n' "$narrow_output" | grep -F "COMMAND" >/dev/null 2>&1; then
  echo "FAIL: narrow output should still include the process table header" >&2
  exit 1
fi

for metric_label in "CLAUDE:" "CODEX:"; do
  if ! printf '%s\n' "$narrow_output" | grep -F "$metric_label" >/dev/null 2>&1; then
    echo "FAIL: narrow output should preserve '$metric_label' in the summary area" >&2
    exit 1
  fi
done

path_output=$plain_diff_output

if ! printf '%s\n' "$path_output" | grep -F "~/A137442/example/project/index.ts" >/dev/null 2>&1; then
  echo "FAIL: output should compact home-directory paths to '~'" >&2
  exit 1
fi

if printf '%s\n' "$path_output" | grep -F "/data/data/com.termux/files/home/" >/dev/null 2>&1; then
  echo "FAIL: compacted path output should not expose the full home prefix" >&2
  exit 1
fi

live_output_file=$(mktemp)
trap 'rm -f "$live_output_file"' EXIT INT TERM

set +e
timeout 1 sh "$SCRIPT" --interval 10 >"$live_output_file" 2>&1
live_status=$?
set -e

if [ "$live_status" -ne 0 ] && [ "$live_status" -ne 124 ] && [ "$live_status" -ne 143 ]; then
  echo "FAIL: unexpected live-mode exit status '$live_status'" >&2
  exit 1
fi

live_output=$(cat "$live_output_file")

for ansi_pattern in \
  "$(printf '\033[?1049h')" \
  "$(printf '\033[?25l')" \
  "$(printf '\033[H')" \
  "$(printf '\033[J')" \
  "$(printf '\033[?25h')" \
  "$(printf '\033[?1049l')"
do
  if ! printf '%s' "$live_output" | grep -F "$ansi_pattern" >/dev/null 2>&1; then
    echo "FAIL: missing live-mode ANSI sequence" >&2
    exit 1
  fi
done

if printf '%s' "$live_output" | grep -F "$(printf '\033[2J')" >/dev/null 2>&1; then
  echo "FAIL: live mode should avoid full-screen clear" >&2
  exit 1
fi

diff_output=$(
  CODEX_TOP_TEST_MODE=diff \
  CODEX_TOP_TEST_CYCLES=2 \
  sh "$SCRIPT" --interval 1
)

title_refresh_output=$(
  CODEX_TOP_FORCE_STYLE=1 \
  CODEX_TOP_TEST_MODE=diff_title \
  CODEX_TOP_TEST_CYCLES=2 \
  sh "$SCRIPT" --interval 0.25
)

resize_output=$(
  CODEX_TOP_FORCE_STYLE=1 \
  CODEX_TOP_TEST_MODE=resize \
  CODEX_TOP_TEST_CYCLES=2 \
  sh "$SCRIPT" --interval 1
)

title_count=$(printf '%s' "$diff_output" | awk '
  BEGIN { count = 0 }
  {
    count += gsub(/TERMUX SYSTEM SNAPSHOT/, "&")
  }
  END { print count }
')

if [ "$title_count" -ne 1 ]; then
  echo "FAIL: diff mode should avoid redrawing unchanged title lines" >&2
  exit 1
fi

if ! printf '%s' "$diff_output" | grep -F "AgentsCPU:" >/dev/null 2>&1; then
  echo "FAIL: diff mode should include an AgentsCPU summary bar" >&2
  exit 1
fi

if ! printf '%s' "$diff_output" | grep -F "AgentsMem:" >/dev/null 2>&1; then
  echo "FAIL: diff mode should include an AgentsMem summary bar" >&2
  exit 1
fi

if ! printf '%s' "$diff_output" | grep -F "██████░░░░" >/dev/null 2>&1; then
  echo "FAIL: diff mode should render a 10-slot block utilization bar" >&2
  exit 1
fi

if ! printf '%s' "$diff_output" | grep -F "%MEM" >/dev/null 2>&1; then
  echo "FAIL: diff mode should include a %MEM process column" >&2
  exit 1
fi

if ! printf '%s' "$diff_output" | grep -F "$(printf '\033[8;1H')" >/dev/null 2>&1; then
  echo "FAIL: diff mode should reposition cursor to the updated agent summary row after the new Mem/Swap layout" >&2
  exit 1
fi

if ! printf '%s' "$title_refresh_output" | grep -F "$(printf '\033[1;1H\033[2K')" >/dev/null 2>&1; then
  echo "FAIL: title refresh should clear row 1 before repainting the styled title" >&2
  exit 1
fi

if printf '%s' "$title_refresh_output" | grep -F "FPS: 4$(printf '\033[K')" >/dev/null 2>&1; then
  echo "FAIL: title refresh should not clear the line after repainting the FPS edge" >&2
  exit 1
fi

resize_title_count=$(printf '%s' "$resize_output" | awk '
  BEGIN { count = 0 }
  {
    count += gsub(/TERMUX SYSTEM SNAPSHOT/, "&")
  }
  END { print count }
')

if [ "$resize_title_count" -ne 2 ]; then
  echo "FAIL: live mode should fully redraw the title when terminal dimensions change" >&2
  exit 1
fi

if ! printf '%s' "$resize_output" | grep -F "2026-03-12 00:00:00 CST" >/dev/null 2>&1; then
  echo "FAIL: resize test mode should render the initial deterministic title timestamp" >&2
  exit 1
fi

if ! printf '%s' "$resize_output" | grep -F "2026-03-12 00:00:01 CST" >/dev/null 2>&1; then
  echo "FAIL: resize test mode should render the resized deterministic title timestamp" >&2
  exit 1
fi

resize_pid_count=$(printf '%s' "$resize_output" | awk '
  BEGIN { count = 0 }
  {
    count += gsub(/PID    PPID/, "&")
  }
  END { print count }
')

if [ "$resize_pid_count" -ne 1 ]; then
  echo "FAIL: live mode should clip the process table when terminal height shrinks" >&2
  exit 1
fi

echo "PASS: agent-top snapshot and live refresh behavior look correct"
