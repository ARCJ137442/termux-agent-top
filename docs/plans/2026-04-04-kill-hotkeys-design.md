# Design: Kill Hotkeys and Short Kill Status Labels

## Goal
Refine live-mode kill feedback so single-target kill messages show a compact `comm[pid]` label instead of a long command string, and add an emergency bulk-kill hotkey that removes all non-root Claude Code / Codex child processes while preserving the root CLI sessions.

## Decisions
- Keep `k` as the single-target hotkey.
- Change single-target success/failure messages to use `comm[pid]`, for example `KILLED rustc[12345] (87.5%)`.
- Add `Ctrl+K` as the bulk-kill hotkey. It targets all non-root descendants under the configured agent roots.
- Never kill `claude`, `codex`, or any process whose `comm` matches `AGENT_TOP_ROOTS`.
- Keep bottom status-line feedback; do not add confirmation prompts or selection UI.

## Single-Target Kill Behavior
- `k` still rescans the full configured agent subtree at keypress time.
- It still selects the highest-CPU non-root descendant.
- The selected process label is rendered as `<comm>[<pid>]`.
- Success message format: `KILLED <comm>[<pid>] (<cpu>%)`.
- Failure message format: `KILL FAILED <comm>[<pid>]`.
- If there is no eligible child process, the status remains `NO TARGET`.

## Bulk-Kill Behavior
- `Ctrl+K` scans the same configured agent subtree but collects all non-root descendants.
- Every collected PID receives `SIGKILL`.
- Root processes remain untouched even if they are using high CPU.
- If there are no eligible child processes, show `NO TARGET`.
- Success message format: `KILLED ALL <count> CHILDREN`.
- Partial-success message format: `KILLED <success>/<total> CHILDREN`.

## Input Handling
- Continue using raw tty single-byte reads in live mode.
- Interpret ASCII `0x6b` as `k`.
- Interpret ASCII `0x0b` as `Ctrl+K`.
- No behavior is assigned to uppercase `K` in this change.

## Testing
- Update the existing single-kill PTY test to expect the shorter `comm[pid]` label.
- Add PTY-driven tests for `Ctrl+K` success, no-target, and partial-failure cases.
- Assert that bulk-kill records only non-root child PIDs and never records root PIDs.
- Keep all existing live-mode, resize, and summary regression tests intact.
