# ANSI Rendering Contract

Date: 2026-09-26

## Purpose

`agent-top.sh` emits terminal control sequences directly from a POSIX shell and
embedded `awk`. That is appropriate for a small Termux monitor, but it makes
style state part of the program's output protocol. A visual fix is incomplete
if it only changes the visible character while leaving foreground, background,
reverse-video, or reset state ambiguous.

This document is the source of truth for resource-bar styling and the required
regression discipline.

## Canonical Cell Model

The resource bar is divided into visible cells. ANSI sequences do not consume a
cell; they only change the terminal state used to draw subsequent cells.

```text
Claude label       = ClaudeColor + Reverse + label + Reset
Codex label        = CodexColor  + Reverse + label + Reset
Other boundary     = GreenColor  + Reverse + "|" + Reset
Other fill         = GreenColor  + "█..." + Reset
Idle/available     = "░..."                       (plain)
```

The resulting visual semantics are:

```text
      black text on orange background: Claude label
      black text on cyan background:   Codex label
      black text on green background:  | boundary cell
      green foreground blocks:         other fill cells
      plain light blocks:              idle/available cells
```

The `|` is one boundary cell, not a label for the whole `other` segment. Its
reverse-video state must end before the first green `█`, otherwise the fill can
become a dark block. The fill must then receive its own green foreground and
reset.

## ROLE Field Protocol

The `ROLE` column of the process tree is a fixed nine-cell field rendered as:

```text
Role field          = Color + 9 visible cells + Reset
```

- Color carries **attribution**, the label carries **identity**:
  - an Agent started by the user keeps its type color — `ClaudeColor` for
    Claude, `CodexColor` for Codex;
  - an Agent managed by a host (for example a T3 Code server) wears the
    **host color**, and the host's own row wears that same color, so a group
    reads as one color block.
- The color code sits immediately before the label; no indentation is used to
  mark attribution. The `ROLE` column is only nine cells wide, and the
  `child` rows already spend two of them on an indent — spending more of the
  column on attribution would fight the tree hierarchy for the same space.
- The nine-cell width is a hard limit: `CLAUDE` uses six cells and `CODEX`
  uses five; the padding to nine is what keeps the following columns aligned.
- The process tree is the only place where the `ROLE` field appears; the
  resource bars never carry one.

## Root-Cause Review

The repeated presentation failures came from five concrete process defects:

1. **No single style contract.** Claude/Codex labels used the generic
   theme-plus-reverse path, while the `other` marker grew a special white-text
   and green-background path. Two implementations described the same kind of
   boundary without sharing semantics.
2. **Cell state and segment state were conflated.** The `|` marker and the
   following `█` cells share a color theme but not the same SGR state. Treating
   them as one styled string caused reverse-video leakage and black fill.
3. **The repair optimized for the symptom.** White text on a green background
   avoided one dark-fill symptom, but it broke the visual rule that all active
   labels use black text produced by theme color plus reverse video.
4. **Tests checked fragments, not transitions.** Earlier assertions verified
   that a green code, a `|`, and a reset existed somewhere. They did not verify
   the exact order `theme → reverse → marker → reset → theme → fill → reset`.
5. **Narrow labels were under-tested.** Real terminals produced `c` and `cod`,
   while broad fixtures mostly exercised full labels. The failure lived at the
   cell boundary, so wide-label tests missed it.

## Engineering Rules

- Route every styled composition cell through the shared `style_segment()`
  helper in `agent-top.sh`.
- Apply reverse video only to a label or the one-cell `|` marker.
- Apply the fill color in a separate style segment with a separate reset.
- Never introduce a foreground/background combination solely to hide a style
  leak; fix the state boundary instead.
- Test raw ANSI byte order, not only visible text or substring existence.
- Test both `CPU:` and `Mem:` paths, because they share the renderer but have
  different proportions and truncation behavior.
- Test narrow widths (`c`, `co`, and one-cell marker cases) and plain output.
- Compare ANSI-stripped visible widths with plain output widths.
- When changing a color or marker, update this contract before changing the
  implementation so the intended visual semantics are explicit.

## Verification Matrix

| Case | Required assertion |
|---|---|
| Normal agent label | theme + reverse + label + reset |
| Narrow Claude/Codex label | same protocol for `c`/short labels |
| Marker only | green + reverse + `|` + reset |
| Marker plus fill | marker reset before green `█` fill and final fill reset |
| CPU line | marker and reset sequence present |
| Memory line | marker and reset sequence present |
| Plain mode | no CSI/ANSI sequences |
| Visible width | styled and plain lines have equal visible width |
| No rejected path | no white-on-green marker codes |
| Host-managed role | host color immediately before the label, no indent |
| Unmanaged role | type color immediately before the label |
| Host row (`T3`) | the same host color as the Agents it manages |

The executable regression suite is `tests/test_ansi_rendering.sh`; the broader
resource and dashboard suites remain required as well.

## Change Checklist

Before merging an ANSI change:

1. Reproduce the visual complaint with `CODEX_TOP_FORCE_STYLE=1` and a fixed
   `COLUMNS` value.
2. Capture the raw line with `sed -n l` or `od`, identifying every SGR code.
3. State the intended cell-by-cell style contract.
4. Add or update a failing byte-order assertion.
5. Make one renderer change, then run the focused test.
6. Run the full suite, syntax checks, `git diff --check`, and a narrow-width
   manual snapshot.
7. Update this document and `README.md` if the visual contract changes.

## Current Outcome

As of 2026-09-26, the `other` marker uses the same black-text-through-reverse
model as Claude/Codex labels, with green as its theme color. The marker's reset
is independent from the subsequent green fill reset. This closes the specific
white-text regression and the earlier black-fill regression without changing
the intended color distinction between Claude, Codex, other, and idle.

As of 2026-11-04, the `ROLE` field follows the protocol above: a nine-cell
field where the color states the attribution — type color for an Agent the
user started, host color for an Agent a host manages — and the label states
the identity. The byte-order assertions live in
`tests/test_ansi_rendering.sh`; the grouping contract itself is pinned by
`tests/test_t3_managed_agents.sh`.
