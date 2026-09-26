# ANSI rendering review and follow-up plan

Date: 2026-09-26

## Objective

Stop recurring ANSI presentation regressions in the CPU and memory composition
bars by turning the visual rules into an explicit renderer contract, executable
byte-order tests, and a documented review checklist.

## Task List

- [x] Reproduce the `c|` and `cod|` style mismatch at fixed widths.
- [x] Compare current style bytes with the Claude/Codex label protocol.
- [x] Replace white-on-green marker styling with green-theme reverse styling.
- [x] Route marker and fill through one shared segment-style helper.
- [x] Add narrow-width, CPU/Mem, plain-mode, reset-order, and visible-width tests.
- [x] Document root causes, invariants, and the pre-merge checklist.
- [x] Publish the verified v0.3.1 patch release.

## Acceptance Criteria

- `c`/`cod` and `|` use black text on their respective theme-colored reverse
  cells.
- The `|` reverse state ends before green `█` fill cells begin.
- Styled output and plain output have the same visible resource-line width.
- No white-on-green marker output path remains in the implementation; tests may retain the old bytes only as a negative assertion.
- Focused and full regression suites pass before release.
