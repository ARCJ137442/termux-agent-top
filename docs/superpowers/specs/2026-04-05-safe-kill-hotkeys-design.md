# Safer Live Kill Hotkeys Design

## Summary

`agent-top.sh` currently treats `k` as an immediate destructive action in live mode. That is fast, but too easy to trigger by accident for first-time users on a fragile Termux session. This design keeps the existing emergency escape hatch for bulk cleanup while making single-target kill intentional and user-visible.

## Goals

- Reduce accidental process kills in live mode.
- Preserve a fast emergency path when the system is close to instability.
- Keep the interaction shell-friendly and realistic for Termux terminals.
- Avoid changing the existing target-selection rules: never kill configured root agent processes such as `claude` or `codex`.

## Non-Goals

- No interactive cursor selection UI.
- No modal help screen or full-screen onboarding flow.
- No change to the process-selection algorithm itself.
- No requirement for `Ctrl+Alt+K` or other terminal combinations with poor portability.

## Chosen Approach

Use a two-step "armed" flow for single-target kill and keep `Ctrl+K` as the immediate bulk-kill shortcut:

- First `k`: arm the highest-CPU non-root child target, but do not kill it.
- Second `k` while armed: kill that armed target.
- `Ctrl+K`: immediately kill all non-root descendants under the configured agent roots.
- Show a short persistent help hint in live mode so the user can discover the controls without reading the README first.

This is preferred over moving everything to modifier keys because `Ctrl+Alt+K` is not reliable across Termux keyboards and terminal emulators.

## User Interaction

### Default Live Hint

Live mode should show a compact help hint in the status area whenever no higher-priority status message is active.

Preferred copy:

`k: arm kill-one  Ctrl+K: kill-all-children`

The hint should be short, always safe to show, and fit the existing bottom-status style.

### Single-Target Kill Flow

When the user presses `k`:

1. Select the same highest-CPU non-root child process used by the current single-kill implementation.
2. If no candidate exists, show `NO TARGET`.
3. If a candidate exists and no target is armed, store that target as the armed target and show:
   `ARMED: press k again to kill rustc[4002] (87.5%)`
4. If the same target is still armed and the user presses `k` again before the arm expires, execute the kill and show the existing success/failure message:
   - `KILLED rustc[4002] (87.5%)`
   - `KILL FAILED rustc[4002]`

### Arm Expiration

The armed state should auto-clear under predictable conditions:

- after a short timeout measured in refresh cycles or elapsed time
- after `Ctrl+K` is used
- after the user exits live mode
- after the previously armed target no longer exists or is no longer a valid kill candidate

When the arm expires naturally, no extra warning is required; the default hint can resume.

### Bulk Kill Flow

`Ctrl+K` should remain immediate:

- no arming step
- no confirmation step
- same current targeting semantics
- same current status messages:
  - `KILLED ALL N CHILDREN`
  - `KILLED X/Y CHILDREN`
  - `NO TARGET`

This preserves the fast "save the shell before collapse" path.

## State Model

Live mode needs one small new state block:

- `armed_target_pid`
- `armed_target_cpu`
- `armed_target_command`
- `armed_until_tick` or equivalent timeout marker

The implementation should treat this as ephemeral UI state only. It must not affect snapshot mode or process collection.

## Data Flow

1. Live input reads a keypress.
2. `k` routes through an arm-or-confirm handler instead of directly calling kill.
3. The handler selects the current top candidate using the existing selector.
4. If not armed, store the selected candidate and publish an armed status message.
5. If already armed and still valid, execute the existing kill path for that PID.
6. After each refresh, validate whether the armed state has expired and clear it if needed.

Bulk kill continues to use the existing multi-target selection and kill loop.

## Error Handling

- If no candidate exists during the first `k`, show `NO TARGET`.
- If the armed target disappears before confirmation, clear the arm and treat the next `k` as a fresh arm attempt.
- If the second `k` finds that the armed PID is now invalid or no longer killable, clear the arm and show `NO TARGET`.
- If the kill syscall fails, reuse `KILL FAILED <label>`.
- Root processes remain excluded exactly as they are today.

## Compatibility

- `--once` and `--summary-only` remain unchanged.
- Existing `Ctrl+K` behavior remains unchanged from the user's perspective.
- README documentation must be updated so `k` is described as an arming key, not an immediate kill key.

## Testing

Add or update smoke tests for:

- first `k` arms instead of killing
- second `k` kills the armed target
- armed message includes the short target label and CPU percentage
- armed state expires and does not kill on a later unrelated `k`
- `k` with no candidate still reports `NO TARGET`
- `Ctrl+K` still immediately bulk-kills children
- root `claude`/`codex` processes are never killed by either path

Fixture coverage should prefer deterministic test modes rather than timing-sensitive real process behavior.

## Rejected Alternatives

### Keep Immediate `k` and Add Help Text Only

This improves discoverability but does not materially reduce accidental destructive input.

### Move to `Ctrl+K` / `Ctrl+Alt+K`

This reduces accidental single-key input, but `Ctrl+Alt` combinations are unreliable in Termux and some Android keyboard setups. It also removes the simple discoverable `k` flow that can be made safe with arming.

### Require Confirmation for Bulk Kill Too

That is safer in theory, but it weakens the emergency escape hatch that motivated the hotkey feature in the first place.
