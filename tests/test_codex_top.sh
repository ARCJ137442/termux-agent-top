#!/usr/bin/env sh
set -eu

ROOT="/data/data/com.termux/files/home/A137442/termux-tools"
SCRIPT="$ROOT/codex-top.sh"

if [ ! -x "$SCRIPT" ]; then
  echo "FAIL: missing executable script at $SCRIPT" >&2
  exit 1
fi

output=$("$SCRIPT" --once)
styled_output=$(CODEX_TOP_FORCE_STYLE=1 "$SCRIPT" --once)
styled_diff_output=$(CODEX_TOP_FORCE_STYLE=1 CODEX_TOP_TEST_MODE=diff "$SCRIPT" --once)
styled_disk_warn_output=$(CODEX_TOP_FORCE_STYLE=1 CODEX_TOP_TEST_MODE=disk_warn "$SCRIPT" --once)
styled_disk_hot_output=$(CODEX_TOP_FORCE_STYLE=1 CODEX_TOP_TEST_MODE=disk_hot "$SCRIPT" --once)
styled_fps_integer_output=$(COLUMNS=80 CODEX_TOP_FORCE_STYLE=1 "$SCRIPT" --once --interval 0.25)
styled_fps_fraction_output=$(COLUMNS=80 CODEX_TOP_FORCE_STYLE=1 "$SCRIPT" --once --interval 8)
fps_output=$(COLUMNS=90 "$SCRIPT" --once --interval 2)
fps_zero_output=$("$SCRIPT" --once --interval 0)
reverse_ansi=$(printf '\033[7m')
green_ansi=$(printf '\033[92m')
yellow_ansi=$(printf '\033[93m')
red_ansi=$(printf '\033[91m')
orange_ansi=$(printf '\033[38;2;255;170;0m')
cyan_ansi=$(printf '\033[38;2;110;235;255m')
reset_ansi=$(printf '\033[0m')

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
  *"FPS: 0.5 |")
    ;;
  *)
    echo "FAIL: title line should show right-aligned FPS for positive intervals" >&2
    exit 1
    ;;
esac

fps_zero_title_line=$(printf '%s\n' "$fps_zero_output" | sed -n '2p')
case "$fps_zero_title_line" in
  *"FPS: max |")
    ;;
  *)
    echo "FAIL: title line should show 'FPS: max' when interval is zero" >&2
    exit 1
    ;;
esac

if ! printf '%s' "$styled_fps_integer_output" | grep -F "FPS: 4 ${reset_ansi}" >/dev/null 2>&1; then
  echo "FAIL: styled title should keep a trailing reverse-video spacer after 'FPS: 4'" >&2
  exit 1
fi

if ! printf '%s' "$styled_fps_fraction_output" | grep -F "FPS: 0.125 ${reset_ansi}" >/dev/null 2>&1; then
  echo "FAIL: styled title should keep a trailing reverse-video spacer after 'FPS: 0.125'" >&2
  exit 1
fi

for pattern in "TERMUX SYSTEM SNAPSHOT" "CLAUDE" "CODEX" "AgentsMem:" "PID" "%MEM"; do
  if ! printf '%s\n' "$output" | grep -F "$pattern" >/dev/null 2>&1; then
    echo "FAIL: missing pattern '$pattern'" >&2
    exit 1
  fi
done

if ! printf '%s\n' "$output" | grep -F "█" >/dev/null 2>&1; then
  echo "FAIL: output should render block-style utilization bars" >&2
  exit 1
fi

if ! printf '%s' "$styled_diff_output" | grep -F "${green_ansi}██████████░░░░░░░░░░${reset_ansi}" >/dev/null 2>&1; then
  echo "FAIL: forced diff output should color the full 20-slot summary bar with one ANSI color" >&2
  exit 1
fi

if ! printf '%s' "$styled_diff_output" | grep -F "${green_ansi}55.0%${reset_ansi}" >/dev/null 2>&1; then
  echo "FAIL: forced diff output should color summary percentages with the same color as their bars" >&2
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

if ! printf '%s' "$styled_diff_output" | grep -F "0.5 GiB used" >/dev/null 2>&1; then
  echo "FAIL: forced diff output should show /data used GiB on the dedicated /data line" >&2
  exit 1
fi

if ! printf '%s' "$styled_diff_output" | grep -F "${green_ansi}75.0%${reset_ansi} free" >/dev/null 2>&1; then
  echo "FAIL: forced diff output should show a colored /data free percentage on the dedicated /data line" >&2
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

if ! printf '%s' "$styled_disk_warn_output" | grep -F "${yellow_ansi}14.0%${reset_ansi} free" >/dev/null 2>&1; then
  echo "FAIL: /data free percentages below 15% should render yellow" >&2
  exit 1
fi

if ! printf '%s' "$styled_disk_hot_output" | grep -F "${red_ansi}4.0%${reset_ansi} free" >/dev/null 2>&1; then
  echo "FAIL: /data free percentages below 5% should render red" >&2
  exit 1
fi

title_line=$(printf '%s\n' "$styled_output" | grep -F "TERMUX SYSTEM SNAPSHOT" | head -n 1)
if ! printf '%s' "$title_line" | grep -F "$reverse_ansi" >/dev/null 2>&1; then
  echo "FAIL: forced-style output should render the title line in reverse video" >&2
  exit 1
fi

reverse_line_count=$(
  printf '%s\n' "$styled_output" | awk -v reverse="$reverse_ansi" 'index($0, reverse) > 0 { count++ } END { print count + 0 }'
)
if [ "$reverse_line_count" -ne 2 ]; then
  echo "FAIL: forced-style output should keep reverse video only on the title line and table header" >&2
  exit 1
fi

table_header_line=$(printf '%s\n' "$styled_output" | grep -F "PID" | head -n 1)
if ! printf '%s' "$table_header_line" | grep -F "$reverse_ansi" >/dev/null 2>&1; then
  echo "FAIL: forced-style output should render the process table header in reverse video" >&2
  exit 1
fi

summary_line=$(printf '%s\n' "$styled_output" | grep -F "RISK:" | head -n 1)
if printf '%s' "$summary_line" | grep -F "$reverse_ansi" >/dev/null 2>&1; then
  echo "FAIL: summary lines should remain plain text in forced-style output" >&2
  exit 1
fi

if printf '%s' "$summary_line" | grep -F "|" >/dev/null 2>&1; then
  echo "FAIL: summary lines should not include panel-side bars in forced-style output" >&2
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

path_output=$(CODEX_TOP_TEST_MODE=diff "$SCRIPT" --once)

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

if ! printf '%s' "$diff_output" | grep -F "$(printf '\033[6;1H')" >/dev/null 2>&1; then
  echo "FAIL: diff mode should reposition cursor to the updated agent summary row" >&2
  exit 1
fi

if ! printf '%s' "$title_refresh_output" | grep -F "$(printf '\033[1;1H\033[2K')" >/dev/null 2>&1; then
  echo "FAIL: title refresh should clear row 1 before repainting the styled title" >&2
  exit 1
fi

if printf '%s' "$title_refresh_output" | grep -F "FPS: 4 ${reset_ansi}$(printf '\033[K')" >/dev/null 2>&1; then
  echo "FAIL: title refresh should not clear the line after repainting the FPS edge" >&2
  exit 1
fi

echo "PASS: codex-top snapshot and live refresh behavior look correct"
