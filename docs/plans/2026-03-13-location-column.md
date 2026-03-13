# Agent LOCATION Column Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a LOCATION column between ROLE and COMMAND, showing `branch@folder` for Claude/Codex root rows and `folder` when no git branch is available.

**Architecture:** Extend the process table width calculations to include a fixed `LOCATION` column, update the header and row renderers, and compute location only for root `claude`/`codex` processes by resolving `/proc/<pid>/cwd` and (if available) a git branch via `git -C`. Child rows leave LOCATION blank.

**Tech Stack:** POSIX `sh`, `awk`, `ps`, `readlink`, `git`

---

### Task 1: Add failing tests for LOCATION column

**Files:**
- Modify: `tests/test_agent_top.sh`

**Step 1: Write the failing test**

Add assertions for the new column and sample output in diff mode:

```sh
# ensure header includes LOCATION
header_line=$(printf '%s\n' "$styled_diff_output" | grep -F "PID" | head -n 1)
if ! printf '%s' "$header_line" | grep -F "LOCATION" >/dev/null 2>&1; then
  echo "FAIL: process table header should include LOCATION column" >&2
  exit 1
fi

# ensure location appears on root sample rows
if ! printf '%s' "$styled_diff_output" | grep -F "main@termux-tools" >/dev/null 2>&1; then
  echo "FAIL: root CLAUDE row should include LOCATION sample" >&2
  exit 1
fi

if ! printf '%s' "$styled_diff_output" | grep -F "project" >/dev/null 2>&1; then
  echo "FAIL: root CODEX row should include LOCATION sample" >&2
  exit 1
fi
```

**Step 2: Run test to verify it fails**

Run: `sh tests/test_agent_top.sh`

Expected: FAIL with missing LOCATION column/sample strings.

### Task 2: Add LOCATION column in the process table (minimal implementation)

**Files:**
- Modify: `agent-top.sh`

**Step 1: Write minimal implementation**

Add a fixed width and include LOCATION in the header/row format:

```sh
PROCESS_LOCATION_WIDTH=20
PROCESS_FIXED_WIDTH=$((... + PROCESS_LOCATION_WIDTH + 1))
```

Update header:

```sh
header_line=$(printf '%-6s %-6s %-7s %-6s %-*s %-6s %-*s %-9s %-*s %-*s' \
  "PID" "PPID" "RSS_KB" "%MEM" "$PROCESS_MEM_BAR_FIELD_WIDTH" "MEM" "%CPU" \
  "$PROCESS_CPU_BAR_FIELD_WIDTH" "CPU" "ROLE" "$PROCESS_LOCATION_WIDTH" "LOCATION" \
  "$PROCESS_COMMAND_WIDTH" "COMMAND")
```

Compute LOCATION for root rows inside the awk block:

```awk
function sh_quote(text,    result, i, ch) {
  result = "'";
  for (i = 1; i <= length(text); i++) {
    ch = substr(text, i, 1);
    if (ch == "'") {
      result = result "'\\''";
    } else {
      result = result ch;
    }
  }
  result = result "'";
  return result;
}
function basename_path(path,    pos) {
  sub(/\/$/, "", path);
  pos = match(path, /[^\/]+$/);
  if (pos == 0) { return ""; }
  return substr(path, RSTART, RLENGTH);
}
function get_location(pid,    cmd, cwd, folder, branch) {
  if (pid in location_cache) {
    return location_cache[pid];
  }
  cmd = "readlink /proc/" pid "/cwd 2>/dev/null";
  cwd = "";
  if ((cmd | getline cwd) <= 0) {
    close(cmd);
    location_cache[pid] = "";
    return "";
  }
  close(cmd);
  if (cwd == "") {
    location_cache[pid] = "";
    return "";
  }
  folder = basename_path(cwd);
  branch = "";
  cmd = "git -C " sh_quote(cwd) " symbolic-ref --short HEAD 2>/dev/null";
  if ((cmd | getline branch) > 0) {
    close(cmd);
  } else {
    close(cmd);
  }
  sub(/^[[:space:]]+/, "", branch);
  sub(/[[:space:]]+$/, "", branch);
  if (branch != "") {
    location_cache[pid] = branch "@" folder;
  } else {
    location_cache[pid] = folder;
  }
  return location_cache[pid];
}
```

Use it when printing rows (root only):

```awk
location_text = "";
if (depth == 0) {
  location_text = short_args(get_location(pid), location_width);
}
```

**Step 2: Run test to verify it passes**

Run: `sh tests/test_agent_top.sh`

Expected: PASS

### Task 3: Update diff-mode sample rows for LOCATION

**Files:**
- Modify: `agent-top.sh`

**Step 1: Update diff-mode sample output**

Add fixed LOCATION values in the `TEST_MODE` branch:

```sh
sample_location_claude="main@termux-tools"
sample_location_codex="project"
```

Include them in the sample `printf` lines for root rows, and leave blank for child rows.

**Step 2: Run test to verify it passes**

Run: `sh tests/test_agent_top.sh`

Expected: PASS

### Task 4: Commit

**Step 1: Commit changes**

```bash
git add tests/test_agent_top.sh agent-top.sh
git commit -m "feat: add process location column"
```

**Step 2: Verify full test run**

Run: `sh tests/test_agent_top.sh`

Expected: PASS
