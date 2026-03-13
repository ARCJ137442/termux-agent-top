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
