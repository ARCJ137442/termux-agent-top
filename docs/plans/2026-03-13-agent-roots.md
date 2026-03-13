# Configurable Agent Roots Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Allow configuration of agent root process names via `AGENT_TOP_ROOTS`, replacing hardcoded `claude/codex` defaults.

**Architecture:** Parse a comma-separated root list at startup, build a lookup for root detection, update rollups and the process tree to use this list, and render a dynamic summary line. Preserve existing coloring for `claude`/`codex` only.

**Tech Stack:** POSIX `sh`, `awk`, `ps`

---

### Task 1: Add failing tests for configurable roots

**Files:**
- Modify: `tests/test_agent_top.sh`

**Step 1: Write the failing test**

Add a custom-root test using test mode output:

```sh
custom_output=$(AGENT_TOP_ROOTS=codex,claude CODEX_TOP_TEST_MODE=diff "$SCRIPT" --once)
if ! printf '%s' "$custom_output" | grep -F "CODEX" >/dev/null 2>&1; then
  echo "FAIL: custom root list should still include CODEX" >&2
  exit 1
fi

custom_output=$(AGENT_TOP_ROOTS=codex CODEX_TOP_TEST_MODE=diff "$SCRIPT" --once)
if printf '%s' "$custom_output" | grep -F "CLAUDE:" >/dev/null 2>&1; then
  echo "FAIL: custom root list should not include CLAUDE when omitted" >&2
  exit 1
fi
```

**Step 2: Run test to verify it fails**

Run: `sh tests/test_agent_top.sh`

Expected: FAIL with missing custom-root behavior.

---

### Task 2: Parse and normalize AGENT_TOP_ROOTS

**Files:**
- Modify: `agent-top.sh`

**Step 1: Implement parsing**

Add helper to normalize a comma-separated list and set defaults when empty:

```sh
parse_agent_roots() {
  input="$1"
  default="claude,codex"
  if [ -z "$input" ]; then
    input="$default"
  fi
  printf '%s' "$input" | awk -F',' '
    function trim(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
    {
      for (i = 1; i <= NF; i++) {
        v = trim($i)
        if (v != "" && !seen[v]++) {
          roots[count++] = v
        }
      }
    }
    END {
      if (count == 0) {
        split("claude,codex", fallback, ",")
        for (i in fallback) {
          if (!seen[fallback[i]]++) {
            roots[count++] = fallback[i]
          }
        }
      }
      for (i = 0; i < count; i++) {
        printf "%s%s", roots[i], (i + 1 < count ? " " : "")
      }
    }'
}

AGENT_ROOT_LIST=$(parse_agent_roots "${AGENT_TOP_ROOTS:-}")
```

**Step 2: Run test to verify it passes**

Run: `sh tests/test_agent_top.sh`

Expected: PASS

---

### Task 3: Use root list in rollups and process tree

**Files:**
- Modify: `agent-top.sh`

**Step 1: Rollup changes**

Pass the root list into `awk` and replace hardcoded checks:

```sh
ps ... | awk -v root_list="$AGENT_ROOT_LIST" '
  BEGIN { n = split(root_list, roots, " "); for (i = 1; i <= n; i++) root[roots[i]] = 1; }
  function is_agent_root(pid) { return root[comm[pid]] == 1; }
  ...
  if (root[comm_val]) { root_order[++root_count] = pid_val; }
  ...
  if (root[comm[pid_val]]) { root_count_map[comm[pid_val]]++; root_rss_map[comm[pid_val]] += rss[pid_val]; }
'
```

**Step 2: Summary line**

Build summary dynamically using `AGENT_ROOT_LIST` order and values from the rollup.

**Step 3: Process tree**

Use the same root map to determine roots and role labels.

**Step 4: Run tests**

Run: `sh tests/test_agent_top.sh`

Expected: PASS

---

### Task 4: Update README

**Files:**
- Modify: `README.md`

**Step 1: Document the new env var**

Add a short section explaining `AGENT_TOP_ROOTS` and include a sample invocation.

**Step 2: Run tests**

Run: `sh tests/test_agent_top.sh`

Expected: PASS

---

### Task 5: Commit

**Step 1: Commit changes**

```bash
git add agent-top.sh tests/test_agent_top.sh README.md
git commit -m "feat: add configurable agent roots"
```

**Step 2: Verify full test run**

Run: `sh tests/test_agent_top.sh`

Expected: PASS
