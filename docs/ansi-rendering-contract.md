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

Three signals share this one column, and each answers exactly one question:

| Signal | Question | Rule |
|---|---|---|
| Color | what is this? | `ClaudeColor` for Claude, `CodexColor` for Codex, none otherwise |
| Brackets | is this a group? | a hub row's label is `[T3]` / `[TMUX]` and carries **no** color |
| Indent | who owns it? | an Agent under a hub gets one leading space; `child` rows are unaffected |

- Color is **type only**. It must not encode attribution: an Agent hosted by
  T3 keeps its own orange/cyan, so its identity does not change with its host.
  A hosted Agent and a standalone one of the same type are the same color by
  design — the indent, not the color, separates them.
- A hub row is a section title. It is deliberately uncolored so it does not
  compete with the Agents beneath it, and the brackets are what say "a group
  starts here".
- The indent is a single ASCII space. It must stay single-byte: `gawk`'s
  `length()` counts **bytes** under the C locale, so a multibyte marker (`·`)
  makes `sprintf("%-9s")` pad the field short and shifts every column to its
  right. See the width note below.
- The nine-cell width is a hard limit: `*CLAUDE`-style prefixes are gone, and
  the longest label in use is `[TMUX]` at six cells, so no label may exceed
  nine. The padding to nine is what keeps the following columns aligned.
- The process tree is the only place where the `ROLE` field appears; the
  resource bars never carry one.

### Width is a locale-dependent property

`length()`, `substr()` and `sprintf("%-*s")` in `gawk` measure **characters**
under a UTF-8 locale and **bytes** under the C locale. The `ROLE` field depends
on this because it is padded to a fixed cell count, as do the resource bars
inside `render_panel_lines_wrapped()`.

Verified on this device:

```text
$ awk 'BEGIN { printf "[%-9s]\n", "\302\267CLAUDE" }'              # UTF-8 locale
[·CLAUDE  ]          # 9 visible cells — correct
$ LC_ALL=C awk 'BEGIN { printf "[%-9s]\n", "\302\267CLAUDE" }'
[·CLAUDE ]           # length("\302\267CLAUDE") == 8 — one cell short
```

The current implementation avoids the problem by using single-byte ASCII for
the indent. The bars (`█`, `░`) are still multibyte, so a C-locale run can
still under-pad a wrapped panel line — that remains an open defect rather than
a solved one.

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
| Hub title | bracketed label (`[T3]` / `[TMUX]`) with no color code before it |
| Hosted Agent | its own type color, then exactly one indent space before the label |
| Standalone Agent | its own type color, then the label with no indent |
| Child row | plain two-cell indent, unaffected by hub membership |
| Retired host color | the violet host color must not reappear |

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

As of 2026-11-04, the `ROLE` field follows the three-signal protocol above:
type color, bracketed hub titles, and a one-cell indent for hosted Agents.
The byte-order assertions live in `tests/test_ansi_rendering.sh`; the grouping
contract itself is pinned by `tests/test_t3_managed_agents.sh`.

A related rendering defect was fixed in the same revision and is worth
recording, because it is a *class* of bug rather than a typo: the frame
clipper located the process-table header with `/^PID[[:space:]]+PPID/`, but
under `CODEX_TOP_FORCE_STYLE=1` (and therefore in every live frame) that
header is prefixed with `ESC[7m`. The probe never matched, the clipper took
its "no header found" fallback, and `clamp_tree_focus` pinned the focus to
zero — the entire `j`/`u`/`g`/`G` scroll feature was dead in the only mode
users actually run. **Any regex used as a structural probe over a styled
frame must strip CSI sequences first.** The regression is pinned in
`tests/test_live_navigation.sh`, which asserts the styled path explicitly;
both assertions were confirmed to fail against the pre-fix source.

A second class bug was closed on 2026-11-04, and it is the same *kind* of
defect: a channel used for something it does not promise. `awk -v` applies C
escape rules to its value, so the whole-frame diff lost line boundaries the
moment any process on screen had a backslash in its command line. The frame
really had 12 lines; `awk` saw 13. Every line after the injection point was
written one row too low and the last row kept the previous frame's bytes.

Worse than misalignment, the payload itself was truncated: a row whose content
was `a\nb` came out as `a`, with `b` pushed into the next row. Measured bytes
for a two-frame diff differing only at line 3:

```text
actual   ESC[3;1H ESC[2K a   ESC[4;1H ESC[2K b   ESC[5;1H ESC[2K L4
expected ESC[3;1H ESC[2K a\nb
```

The same channel was carrying `location_map`, which turned a directory named
`proj\name` into a cell reading only `proj` — `name` leaked out as a separate
record and was dropped. Both are fixed by moving data to `ENVIRON`; the rule
and its regression guard live in `AGENTS.md` and
`tests/test_awk_data_channel.sh`.
