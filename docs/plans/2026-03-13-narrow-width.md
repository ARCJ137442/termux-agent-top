# Narrow Width Command Clamp Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Ensure process rows never exceed the panel width in narrow terminals by clamping the command field (including prefix).

**Architecture:** In the process-tree awk code, build the command text as `prefix + args`, then clamp it to `command_width` using `short_args`. Print only the clamped command field so the row length is bounded.

**Tech Stack:** POSIX `sh`, `awk`, existing `tests/test_agent_top.sh`.

---

### Task 1: Reproduce failing narrow-width test

**Files:**
- Test: `tests/test_agent_top.sh`

**Step 1: Run test to verify failure**

Run:

```sh
sh tests/test_agent_top.sh
```

Expected: FAIL with `one-shot output should adapt to narrow terminal widths`.

**Step 2: Commit evidence (optional)**

No code changes yet; no commit needed.

---

### Task 2: Clamp command field width

**Files:**
- Modify: `agent-top.sh`

**Step 1: Write minimal implementation**

In `print_node` inside the awk block, replace the current `summary`/`prefix` handling with:

```awk
      command_text = prefix compact_home_path(args[pid]);
      summary = short_args(command_text, command_width);
```

Update the `printf` to print only the command field:

```awk
      printf "%-6s %-6s %-7s %s %-*s %s %-*s %s %-*s %-*s\n",
        ...,
        location_width,
        location_text,
        command_width,
        summary;
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
git commit -m "fix: clamp command field for narrow widths"
```

---

### Task 3: Stabilize live-mode ANSI sequences

**Files:**
- Modify: `agent-top.sh`

**Step 1: Implement minimal fix**

In `enter_live_screen`, include cursor-home and clear-to-end sequences:

```sh
printf '\033[?1049h\033[?25l\033[H\033[J'
```

**Step 2: Run tests**

```sh
sh tests/test_agent_top.sh
```

Expected: PASS.

**Step 3: Commit**

```sh
git add agent-top.sh
git commit -m "fix: always emit live-mode cursor clear sequences"
```

---

### Task 4: Runtime smoke check

**Files:**
- None

**Step 1: Run runtime snapshot**

```sh
./agent-top.sh --once
```

Expected: Output renders normally.

**Step 2: Commit**

No code changes; no commit needed.
