# termux-agent-top contributor guide

## Scope

This repository is a POSIX `sh` plus `awk` Termux monitor. Keep changes small,
fixture-driven, and compatible with the commands listed in `README.md`.

## ANSI Rendering Rules

- Treat every resource bar as visible cells plus a separate ANSI state machine.
- Route styled composition cells through `style_segment()` in `agent-top.sh`.
- Claude and Codex labels use `theme color + reverse + label + reset`.
- The `other` boundary uses `green + reverse + | + reset` for one cell only.
- The following `other` fill uses `green + blocks + reset` independently.
- Never replace a state-boundary bug with an unrelated foreground/background
  combination; fix the reset scope instead.
- Any ANSI change must update or extend `docs/ansi-rendering-contract.md` and
  `tests/test_ansi_rendering.sh` with exact byte-order assertions.

## Required Verification

Run the focused ANSI test first, then the complete suite:

```sh
sh tests/test_ansi_rendering.sh
for test_file in tests/test_*.sh; do sh "$test_file"; done
sh -n agent-top.sh
git diff --check
```

For layout or style changes, also inspect a forced-style narrow snapshot:

```sh
COLUMNS=80 CODEX_TOP_FORCE_STYLE=1 CODEX_TOP_TEST_MODE=diff ./agent-top.sh --once
```

Do not claim a visual fix from source inspection alone. Capture raw bytes with
`sed -n l` or `od`, verify reset boundaries, and compare ANSI-stripped visible
cells with plain output.

## Release Discipline

- Do not use destructive Git recovery commands without explicit authorization.
- Include new regression tests in the commit.
- Re-run the complete verification suite immediately before committing.
- Push `main` first; create and push the next version tag only after the branch
  push succeeds.
