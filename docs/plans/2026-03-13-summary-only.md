# Summary-Only Output Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a `--summary-only` flag that renders the summary panel without the process tree.

**Architecture:** Parse a new CLI flag into `SUMMARY_ONLY`, and branch in `render_dashboard` to skip `render_process_tree` and its surrounding borders. Update usage help and document the flag in README. Add tests to assert summary markers remain while process headers are absent.

**Tech Stack:** POSIX `sh`, `awk`, coreutils, existing `tests/test_agent_top.sh`.

---

### Task 1: Add failing summary-only tests

**Files:**
- Modify: `tests/test_agent_top.sh`

**Step 1: Write the failing test**

Add new outputs near the top:

```sh
summary_only_output=$("$SCRIPT" --once --summary-only)
styled_summary_only_output=$(CODEX_TOP_FORCE_STYLE=1 "$SCRIPT" --once --summary-only)
```

Add assertions after the existing pattern checks:

```sh
for pattern in "Tasks:" "AgentsCPU" "AgentsMem"; do
  if ! printf '%s\n' "$summary_only_output" | grep -F "$pattern" >/dev/null 2>&1; then
    echo "FAIL: --summary-only should keep '$pattern' in the summary" >&2
    exit 1
  fi
done

for pattern in "PID" "COMMAND"; do
  if printf '%s\n' "$summary_only_output" | grep -F "$pattern" >/dev/null 2>&1; then
    echo "FAIL: --summary-only should omit the process table header" >&2
    exit 1
  fi
  if printf '%s\n' "$styled_summary_only_output" | grep -F "$pattern" >/dev/null 2>&1; then
    echo "FAIL: styled --summary-only should omit the process table header" >&2
    exit 1
  fi
done
```

**Step 2: Run test to verify it fails**

Run:

```sh
sh tests/test_agent_top.sh
```

Expected: FAIL mentioning `--summary-only` (flag unrecognized or missing output).

**Step 3: Commit the failing test**

```sh
git add tests/test_agent_top.sh
git commit -m "test: cover --summary-only output"
```

---

### Task 2: Implement summary-only rendering

**Files:**
- Modify: `agent-top.sh`

**Step 1: Implement minimal code**

Add flag parsing and state:

```sh
SUMMARY_ONLY=0
```

Update the CLI parser:

```sh
    --summary-only)
      SUMMARY_ONLY=1
      ;;
```

Update usage to include `--summary-only`.

In `render_dashboard`, gate the process tree:

```sh
  if [ "$STYLE_ENABLED" -eq 0 ]; then
    render_plain_header_line
  fi
  if [ "$SUMMARY_ONLY" -eq 0 ]; then
    render_process_tree
    if [ "$STYLE_ENABLED" -eq 0 ]; then
      render_plain_header_line
    fi
  elif [ "$STYLE_ENABLED" -eq 0 ]; then
    render_plain_header_line
  fi
```

**Step 2: Run tests**

Run:

```sh
sh tests/test_agent_top.sh
```

Expected: PASS.

**Step 3: Commit**

```sh
git add agent-top.sh
git commit -m "feat: add --summary-only flag"
```

---

### Task 3: Document the new flag

**Files:**
- Modify: `README.md`

**Step 1: Update usage docs**

Add a short example:

```sh
./agent-top.sh --once --summary-only
```

Mention that it omits the process tree.

**Step 2: Run tests (smoke check)**

Run:

```sh
sh tests/test_agent_top.sh
```

Expected: PASS.

**Step 3: Commit**

```sh
git add README.md
git commit -m "docs: document --summary-only"
```
