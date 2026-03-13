# AgentsCPU Normalization Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a normalized AgentsCPU percentage (0-100%) alongside the existing raw core-equivalent percentage.

**Architecture:** Detect CPU count from cpuset/online/nproc fallback, compute a normalized percentage capped at 100%, and render it as a new summary line while preserving existing raw CPU and risk logic.

**Tech Stack:** POSIX `sh`, `awk`, `ps`

---

### Task 1: Add failing tests for AgentsCPU(norm)

**Files:**
- Modify: `tests/test_agent_top.sh`

**Step 1: Write the failing test**

Add assertions for the new summary line and normalized value in diff mode:

```sh
if ! printf '%s' "$styled_diff_output" | grep -F "AgentsCPU(norm):" >/dev/null 2>&1; then
  echo "FAIL: output should include AgentsCPU(norm) summary line" >&2
  exit 1
fi

if ! printf '%s' "$styled_diff_output" | grep -F "27.5%" >/dev/null 2>&1; then
  echo "FAIL: normalized CPU percentage should appear in diff output" >&2
  exit 1
fi
```

**Step 2: Run test to verify it fails**

Run: `sh tests/test_agent_top.sh`

Expected: FAIL with missing AgentsCPU(norm) line/percentage.

---

### Task 2: Add CPU count detection + normalized value (minimal implementation)

**Files:**
- Modify: `agent-top.sh`

**Step 1: Write minimal implementation**

Add helpers for CPU count detection and normalization:

```sh
parse_cpu_list_count() {
  list="$1"
  awk -v list="$list" 'BEGIN {
    n = split(list, parts, ",");
    total = 0;
    for (i = 1; i <= n; i++) {
      if (parts[i] ~ /-/) {
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
  count=""
  if [ -r /proc/self/status ]; then
    count=$(awk -F':' '/^Cpus_allowed_list:/ { gsub(/^[[:space:]]+/, "", $2); print $2; exit }' /proc/self/status)
    if [ -n "$count" ]; then
      parsed=$(parse_cpu_list_count "$count")
      if [ "$parsed" -gt 0 ] 2>/dev/null; then
        printf '%s' "$parsed"
        return
      fi
    fi
  fi

  if [ -r /sys/devices/system/cpu/online ]; then
    count=$(cat /sys/devices/system/cpu/online 2>/dev/null)
    if [ -n "$count" ]; then
      parsed=$(parse_cpu_list_count "$count")
      if [ "$parsed" -gt 0 ] 2>/dev/null; then
        printf '%s' "$parsed"
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
```

Compute normalized percent in `run_once`:

```sh
CPU_COUNT=$(detect_cpu_count)
AGENT_CPU_NORM_PERCENT=$(awk -v percent="$AGENT_CPU_PERCENT" -v count="$CPU_COUNT" 'BEGIN {
  if (count <= 0) { count = 1 }
  value = percent / count;
  if (value > 100) { value = 100 }
  printf "%.1f", value;
}')
```

Render new summary line below AgentsCPU:

```sh
render_panel_lines_wrapped "AgentsCPU(norm): $(render_bar "$AGENT_CPU_NORM_PERCENT" "$SUMMARY_BAR_WIDTH" utilization) $(render_metric_text "$AGENT_CPU_NORM_PERCENT" utilization "%")"
```

**Step 2: Run test to verify it passes**

Run: `sh tests/test_agent_top.sh`

Expected: PASS

---

### Task 3: Update diff/test mode fixtures for normalized CPU

**Files:**
- Modify: `agent-top.sh`

**Step 1: Update test mode values**

In the diff/risk test-mode path, set `CPU_COUNT=2` (or `4`) and precompute a deterministic normalized percent matching the new test assertion (e.g., `55.0 / 2 = 27.5`).

**Step 2: Run test to verify it passes**

Run: `sh tests/test_agent_top.sh`

Expected: PASS

---

### Task 4: Update README for raw vs norm semantics

**Files:**
- Modify: `README.md`

**Step 1: Add short explanation**

Document that `AgentsCPU` is raw core-equivalent, and `AgentsCPU(norm)` is normalized to 0-100 based on detected CPU count.

**Step 2: Run test to verify it passes**

Run: `sh tests/test_agent_top.sh`

Expected: PASS

---

### Task 5: Commit

**Step 1: Commit changes**

```bash
git add agent-top.sh tests/test_agent_top.sh README.md
git commit -m "feat: add normalized AgentsCPU"`
```

**Step 2: Verify full test run**

Run: `sh tests/test_agent_top.sh`

Expected: PASS
