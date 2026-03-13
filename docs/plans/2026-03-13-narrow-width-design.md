# Design: Narrow Width Command Column Clamp

## Goal
Ensure process table rows never exceed the configured panel width when the terminal is narrow (e.g., `COLUMNS=90`).

## Non-Goals
- No changes to summary metrics or risk logic.
- No changes to process sorting or inclusion rules.
- No new flags or output modes.

## Root Cause
Child rows include a `prefix` (indent + `|- `) that is printed outside the command column width budget. When the command column is narrow, the prefix alone can exceed the allotted width, causing lines longer than the panel width.

## Approach
- Treat the prefix as part of the command field for width calculations.
- Build the command text as `prefix + args`, then clamp it to `command_width` using the existing `short_args` helper.
- Print only the clamped command field (instead of printing prefix and summary separately).

## Behavior Details
- Root rows (no prefix) remain unchanged.
- Child rows now truncate the combined prefix+command to fit the command column width.
- Output alignment stays consistent with the existing header.

## Testing
- The existing narrow-width test in `tests/test_agent_top.sh` should pass after the change.
- Run full test script to confirm no regressions.

## Additional Fix: Live-Mode ANSI Reliability

### Goal
Ensure live-mode output always includes the cursor-home (`\033[H`) and clear-to-end (`\033[J`) sequences even if the process is terminated quickly.

### Root Cause
The sequences are emitted during the first frame diff. If `timeout 1` kills the process before the first frame is drawn, the sequences never appear.

### Approach
Emit `\033[H\033[J` in `enter_live_screen` along with the alternate-screen and hide-cursor sequences. This guarantees the sequences appear before any frame rendering.
