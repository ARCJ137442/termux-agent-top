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

## Shell ↔ awk Data Channel

`-v` carries **configuration**: numbers and fixed constants the script itself
composes. Data — process argv, directory names, branch names, whole frame
text — must go through the environment instead:

```sh
ATD_X="$data" awk -v width="$w" 'BEGIN { x = ENVIRON["ATD_X"]; ... }'
```

`gawk`'s `-v` applies C string escape rules (`\n \t \b \f \r \v \\ \" \ooo`),
while `ENVIRON` is a raw byte channel. The difference is observable data loss,
not a theoretical hazard:

```text
'a\nb'    --v-->  "a<LF>b"     4 bytes become 3
'proj\q'  --v-->  "projq"      backslash swallowed, plus a stderr warning
```

The predicate is "could this value contain a backslash", **not** "does this use
`-v`". Passing bare ESC bytes through `-v` (e.g. `-v ansi_reset="$ANSI_RESET"`)
is safe, because `gawk` only rewrites backslash sequences.

The cost of the two channels is the same (both end up in the exec'd argv/env),
measured: 588 ms vs 587 ms frame median. There is no performance reason to keep
data on `-v`.

Regression: `tests/test_awk_data_channel.sh`. It asserts both the concrete
handlers and the class — a grep guard fails the build if a data variable
reappears on `-v`.

## Live Input and Frame Pacing

`/bin/sh` on this device is dash 0.5.12, which has no `read -t`. Do not work
around that with a busy poll: polling costs one fork per 100 ms while idle.

The wait between frames is a **blocking read carrying a kernel timeout**:

```sh
stty -icanon -echo min 0 time <deciseconds> </dev/tty
key=$(dd bs=1 count=1 if=/dev/tty)
```

`min 0 time N` makes `read(2)` return 0 after N×0.1 s with no input, and `dd`
treats that as EOF; with input, `read(2)` returns at once. One process covers a
whole idle slice, and a keypress ends the wait immediately instead of at the
next frame boundary.

Measured on this device with `--interval 5`:

```text
keypress-to-exit   4.48 s  ->  0.04 s
idle CPU           0.9%    ->  0.2% of one core
```

Two invariants must not regress:

- `read_live_keypress()` re-applies `min 0 time 0` before its non-blocking read.
  A trapped signal can interrupt the blocking wait before its restore runs, and
  a termios left on `time N` would silently stall the next frame.
- `KEY_WAIT_SLICE_MS` is the resize response time, not the refresh rate. The
  `WINCH` trap only runs once the current foreground command finishes, so a
  single block covering the whole interval would delay resizes.

Regression: `tests/test_live_wait.sh`.

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
