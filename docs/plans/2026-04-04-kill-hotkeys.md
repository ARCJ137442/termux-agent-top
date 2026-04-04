# Kill Hotkeys Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add compact `comm[pid]` kill status labels for `k` and introduce `Ctrl+K` to kill all non-root agent child processes while preserving root CLI sessions.

**Architecture:** Extend the existing live-mode hotkey path in `agent-top.sh` rather than introducing a new interaction layer. Reuse the current process-tree scan pattern to support both single-target and bulk-target selection, then drive both features through the existing status-line rendering.

**Tech Stack:** POSIX `sh`, `awk`, `ps`, PTY-driven shell tests

---

### Task 1: Update the PTY tests first

**Files:**
- Modify: `tests/test_agent_top.sh`
- Test: `tests/test_agent_top.sh`

- [ ] **Step 1: Write the failing assertions for the shorter single-kill label**

Change the single-target PTY expectations from `KILLED pid=4002 rustc (87.5%)` to `KILLED rustc[4002] (87.5%)`, and from `KILL FAILED pid=4002` to `KILL FAILED rustc[4002]`.

- [ ] **Step 2: Add failing PTY tests for `Ctrl+K` bulk kill**

Add three PTY-driven scenarios:
- success: `Ctrl+K` logs all child PIDs and shows `KILLED ALL <count> CHILDREN`
- no target: `Ctrl+K` shows `NO TARGET` and writes no kill log
- partial failure: `Ctrl+K` shows `KILLED <success>/<total> CHILDREN`

Use `printf '\013'` to send `Ctrl+K`.

- [ ] **Step 3: Run the test script and confirm the new assertions fail**

Run: `sh tests/test_agent_top.sh`

Expected: failure on the new kill-status assertions before implementation.

- [ ] **Step 4: Commit the test-only red state**

```bash
git add tests/test_agent_top.sh
git commit -m "test: cover compact kill labels and ctrl-k bulk kill"
```

### Task 2: Add compact labels and bulk-target selection

**Files:**
- Modify: `agent-top.sh`
- Test: `tests/test_agent_top.sh`

- [ ] **Step 1: Add a reusable target-label formatter**

Add a small helper that formats a selected process as `<comm>[<pid>]`.

- [ ] **Step 2: Change the single-target selector to return `comm` as well as `pid` and `cpu`**

Keep the current selection semantics: full subtree scan, highest `%CPU`, non-root descendants only.

- [ ] **Step 3: Add a bulk selector for all non-root descendants**

Return every eligible child PID/comm pair under the configured roots while excluding root processes.

- [ ] **Step 4: Extend the kill executor for batch use**

Reuse the existing `kill -9` wrapper for both single and bulk actions. For bulk mode, count successes and failures without aborting the whole loop on the first failure.

- [ ] **Step 5: Wire `Ctrl+K` into live input handling**

Handle byte `0x0b` as the emergency bulk-kill hotkey. Keep `k` mapped to single-target kill and leave uppercase `K` unassigned.

- [ ] **Step 6: Update status messages**

Implement these exact formats:
- `KILLED <comm>[<pid>] (<cpu>%)`
- `KILL FAILED <comm>[<pid>]`
- `KILLED ALL <count> CHILDREN`
- `KILLED <success>/<total> CHILDREN`
- `NO TARGET`

- [ ] **Step 7: Add or extend fixture modes for deterministic PTY tests**

Provide deterministic fixture branches for:
- single kill success/failure
- bulk kill success/no target/partial failure

- [ ] **Step 8: Run the full test script and confirm green**

Run: `sh tests/test_agent_top.sh`

Expected: `PASS: agent-top snapshot and live refresh behavior look correct`

- [ ] **Step 9: Commit the implementation**

```bash
git add agent-top.sh tests/test_agent_top.sh
git commit -m "feat: add ctrl-k bulk child kill"
```

### Task 3: Document the finalized hotkeys

**Files:**
- Modify: `README.md`
- Test: `tests/test_agent_top.sh`

- [ ] **Step 1: Update live-mode docs**

Document:
- default refresh remains 1 second
- `k` kills the hottest non-root child
- `Ctrl+K` kills all non-root children under the configured roots
- root CLI processes are preserved

- [ ] **Step 2: Re-run the shell test script after docs changes**

Run: `sh tests/test_agent_top.sh`

Expected: still passes with no regressions.

- [ ] **Step 3: Commit the docs update**

```bash
git add README.md
git commit -m "docs: describe kill hotkeys"
```
