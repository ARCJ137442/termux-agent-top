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
quit latency (q)   4.48 s  ->  0.04 s
idle CPU           0.9%    ->  0.2% of one core
```

That 0.04 s is **quit only**, because `q` breaks before `run_once`. Ordinary
keys still pay a full frame rebuild before anything changes on screen; see the
next section.

## Key Handling and Refresh Are One Path

Every key follows the same contract:

```text
read key -> handle_live_keypress -> rebuild the frame (run_once) -> render
```

A key never renders a frame of its own, and no key is special-cased into a
"fast path". `q` is not an exception to the rule: its *handling* is "request
exit", so there is no refresh to wait for. That is why it can be 30 ms while
`j` is not.

The consequence is worth stating plainly, because it is easy to misread a
latency measurement: ending the idle wait early does not make the screen move.
It only removes the *remaining interval*. The floor is the rebuild:

```text
--once (cold, all external commands)   2.0-2.3 s
key -> first byte, while idle          0.7-1.6 s (load-dependent)
```

If a key arrives *during* `run_once`, it queues in the tty buffer and is
handled at the next loop top. Do not "fix" that by rendering a frame composed
before the key was handled: that frame would show the old state and the user
would see two refreshes for one keypress.

## Hotkey Target Naming

The label shown in `ARMED: ... kill <name>[<pid>]` must come from
`display_name()` in both hotkey awk programs (single-target and Ctrl+K list).
It returns the agent kind, else the basename of `argv[0]`, else `comm`.

Never use `comm` for this label on Android: `comm` is the first 15 characters
of `argv[0]`, so any process started by absolute path is displayed as
`/data/data/com.`. The user is being asked to confirm an irreversible
`SIGKILL`; a truncated path fragment is not a confirmation.

`is_armed_target_eligible()` compares against the same emitted field, so the
two awk programs must produce the identical name. If they diverge, the second
`k` is silently rejected and the display re-arms with text that looks unchanged
under diff rendering.

Regression: `tests/test_hotkey_target_label.sh` (it also asserts the old
`comm` form is no longer accepted).

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
