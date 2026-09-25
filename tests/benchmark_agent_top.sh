#!/usr/bin/env sh
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$ROOT/agent-top.sh"
WARM_RUNS=3

if [ "$#" -ne 0 ]; then
  if [ "$#" -ne 2 ] || [ "$1" != '--warm-runs' ]; then
    printf 'usage: %s [--warm-runs positive-integer]\n' "$0" >&2
    exit 2
  fi
  WARM_RUNS=$2
fi

case "$WARM_RUNS" in
  ''|*[!0-9]*|0)
    printf 'warm runs must be a positive integer\n' >&2
    exit 2
    ;;
esac

if [ ! -x "$SCRIPT" ]; then
  printf 'missing executable: %s\n' "$SCRIPT" >&2
  exit 1
fi

probe=$(date +%s%N 2>/dev/null || :)
case "$probe" in
  ''|*[!0-9]*) NANOSECONDS=0 ;;
  *)
    if [ "${#probe}" -ge 19 ]; then
      NANOSECONDS=1
    else
      NANOSECONDS=0
    fi
    ;;
esac

now_ns() {
  if [ "$NANOSECONDS" -eq 1 ]; then
    date +%s%N
  else
    seconds=$(date +%s)
    printf '%s000000000\n' "$seconds"
  fi
}

measure() {
  start_ns=$(now_ns)
  "$SCRIPT" "$@" >/dev/null
  end_ns=$(now_ns)
  elapsed_ns=$((end_ns - start_ns))
}

median_ms() {
  sort -n | awk '
    { samples[NR] = $1 }
    END {
      if (NR % 2) {
        median = samples[(NR + 1) / 2]
      } else {
        median = (samples[NR / 2] + samples[NR / 2 + 1]) / 2
      }
      printf "%.3f", median / 1000000
    }
  '
}

if [ "$NANOSECONDS" -eq 1 ]; then
  printf 'Clock: nanoseconds (date +%%s%%N)\n'
else
  printf 'Clock: seconds (date +%%s fallback; results rounded to seconds)\n'
fi
printf 'Cold = first invocation per mode (no cache eviction); warm = next %s invocations.\n' "$WARM_RUNS"

for mode in full summary-only; do
  set -- --once
  if [ "$mode" = summary-only ]; then
    set -- "$@" --summary-only
  fi

  measure "$@"
  cold_ns=$elapsed_ns
  warm_samples=''
  run=0
  while [ "$run" -lt "$WARM_RUNS" ]; do
    measure "$@"
    warm_samples="${warm_samples}${elapsed_ns}
"
    run=$((run + 1))
  done

  warm_median=$(printf '%s' "$warm_samples" | median_ms)
  cold_ms=$(printf '%s\n' "$cold_ns" | median_ms)
  printf '%s: cold median %s ms (n=1); warm median %s ms (n=%s)\n' \
    "$mode" "$cold_ms" "$warm_median" "$WARM_RUNS"
done
