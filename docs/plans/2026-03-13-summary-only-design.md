# Design: --summary-only

## Goal
Add a `--summary-only` flag to `agent-top.sh` that prints the existing summary panel without the process tree. This reduces `ps` overhead for quick checks and preserves all summary metrics and risk logic.

## Non-Goals
- No new metrics or risk heuristics.
- No changes to default output when the flag is not used.
- No machine-readable output format changes.

## Approach
- Add a `SUMMARY_ONLY` flag defaulting to `0`, set to `1` when `--summary-only` is passed.
- Update the usage message to include `--summary-only`.
- In `render_dashboard`, after the summary lines, skip `render_process_tree` and related panel separators when `SUMMARY_ONLY=1`.
- Preserve all metric collection and rendering logic. Only the process tree rendering is omitted.

## Behavior Details
- `--once` and live modes behave the same; both omit the process tree when `--summary-only` is set.
- In non-styled output, the panel still opens with the same header lines. The summary ends with a single closing border line when `--summary-only` is set.
- In styled output, the summary renders as usual, then ends without the process header or tree.

## Error Handling
- Argument parsing rejects unknown flags as today.
- `--summary-only` does not change validation for `--interval`.

## Testing
- Extend `tests/test_agent_top.sh` to assert that `--summary-only` output includes summary markers (e.g., `Tasks:`) and excludes the process header (e.g., `PID` and `COMMAND`).
- Keep existing tests unchanged for default behavior.
