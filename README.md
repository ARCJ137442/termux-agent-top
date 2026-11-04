# termux-agent-top

`termux-agent-top` is a small Termux-first shell monitor for AI agent workloads.

The repository is intentionally narrow in scope:

- one lightweight POSIX shell script
- a focused fixture-based test suite
- one core job: show system pressure plus Claude/Codex process trees

It is not trying to replace `top`, `htop`, `btop`, or full observability stacks.

## Why This Exists

On Termux/Android, the practical failure mode is often simple:

- memory drops too far during builds or tests
- `/data` fills up
- one Claude/Codex session spawns a subtree of `node`, `tsx`, `git`, or `rustc`
- you need a fast answer from a plain shell before the device becomes unstable

This script targets that workflow directly.

## What It Shows

- `MemAvailable`
- `SwapFree`
- `/data` usage
- global CPU usage and a CPU composition bar
- memory availability and a memory composition bar
- Claude/Codex root and descendant counts, CPU, and RSS summaries
- combined Agent CPU (raw core-equivalent) and memory totals
- a parent/child process tree rooted at `claude` and `codex`

## Usage

Run a one-shot snapshot:

```sh
./agent-top.sh --once
```

Run a summary-only snapshot (omit the process tree):

```sh
./agent-top.sh --once --summary-only
```

Run a live view:

```sh
./agent-top.sh
```

Live mode refreshes once per second by default, switches to the terminal's alternate screen, redraws in place, and restores the previous screen when it exits. This reduces visible flicker compared with clearing the whole screen each refresh.

While live mode is running:

- press `j` / `u` (or Down / Up) to move the process-tree focus through all visible agent descendants; `g` / `G` jump to the top / bottom
- press `f` to fold the tree: each agent shows only itself and its direct children, deeper descendants are hidden
- press `c` to shorten the `COMMAND` column to the executable name instead of the full command line
- press `k` once to arm the highest-CPU non-root child, then again within five seconds to `SIGKILL` that same eligible process
- press `Ctrl+K` to `SIGKILL` all non-root child processes under the configured agent roots
- press `q` to leave the live view

The summary stays pinned while the process tree scrolls; tmux rows appear only when they lead to agents, and unrelated tmux branches remain hidden. Root `claude`/`codex` processes are never selected by either kill hotkey. `Ctrl+K` remains immediate; use it deliberately.

The key list is disclosed on demand rather than pinned to the screen: it appears for a few frames whenever you press a key and then fades out, leaving the row free for the process tree. What stays visible is the *state*, not the manual — an active view mode is shown as `[F]` (folding on) and/or `[C]` (short commands on), so you always know which view you are looking at even after the key list has faded.

The refresh interval is a *frame period*, not a sleep length: the monitor measures how long the frame took to render and sleeps only the remainder. A frame that already exceeds the interval starts the next one immediately, so `--interval 1` means one frame per second rather than one second plus the render time.

A keypress ends the idle wait immediately, but the screen changes only when the next frame has been rebuilt. On this device a rebuild costs roughly one second, so a key still takes about that long to become visible; `q` is the exception because it leaves before the rebuild.

Change refresh interval:

```sh
./agent-top.sh --interval 5
```

Configure which processes are treated as agent roots:

```sh
AGENT_TOP_ROOTS=claude,codex,ai-cli ./agent-top.sh --once
```

If `AGENT_TOP_ROOTS` is unset or empty, the default is `claude,codex`.

## Requirements

- POSIX `sh`
- `ps`
- `awk`
- `df`
- `/proc/meminfo`

The script is designed for Termux/Linux environments with procfs available.

## Related Tools

Useful adjacent projects:

- `procs`: modern `ps` replacement with tree view
- `btop`: full-screen system monitor
- `pspy`: process execution monitoring without root
- `codex-cli-farm` / `claude-code-monitor`: agent-session-oriented tooling in other environments

This repository focuses on the gap between those categories: a very small Termux shell tool centered on agent process pressure.

## Limitations

- detection is currently focused on `claude` and `codex` root processes
- on especially short terminals, the summary alone may fill the available rows, leaving no room for the process-tree viewport
- helper subprocesses may still appear briefly on some shells
- output is optimized for quick diagnosis, not for machine-readable export

## License

MIT. See `LICENSE`.

## Detection Notes

Agent roles are classified from process identity evidence rather than tree depth. The monitor recognizes the current loader-backed Claude Code and Claude Exomind forms, Codex Exomind, and the Node launcher at `/usr/bin/codex`. A descendant is displayed as `child` unless it independently matches an Agent identity; a command merely containing `codex` does not promote the process.

On Android the `comm` column of `ps` is `argv[0]` truncated to fifteen characters, so every process started through an absolute path shows `comm` as `/data/data/com.` and cannot be classified by name at all. Classification therefore matches argument tokens with explicit boundaries: a token ending in `/claude-exomind`, a token ending in `@anthropic-ai/claude-code/bin/claude`, a token ending in `/codex` (the native Codex binary), or a `node`/`MainThread` process whose arguments contain a `/codex` token. Whole-line substring matching is deliberately avoided: `t3-serve`, `t3-termux`, and `codex-child.mjs` must never be promoted to Agent roots.

The process snapshot is read with `ps -ww`. Without it, `ps` truncates every command line at the terminal width — it honours `COLUMNS` even when the output is piped — and the Agent identity tokens usually sit past column eighty, so a narrow terminal makes the whole Agent population silently vanish.

The CPU and memory rows include proportional Claude, Codex, other, and idle/available segments; the Claude and Codex segments use their theme colors in styled terminals and show a truncated name when space allows. Active labels use black text through theme color plus reverse video: orange for Claude, cyan for Codex, and green for the `other` boundary `|`. The marker and its following green fill blocks are separate style segments with explicit resets, so reverse video cannot turn later blocks into dark squares. Agent totals include each root and its full descendant tree, while the per-type summary separates root and child RSS. The separate `AgentsCPU(norm)` line remains normalized against the CPUs available to the monitor. Global CPU is shown as both normalized percent and core-equivalent usage (`used/available cores`); it is an approximate whole-process measurement and does not require Termux:API or Android permissions.

The ANSI resource-bar rules and review checklist live in `docs/ansi-rendering-contract.md`; the focused byte-order regression suite is `tests/test_ansi_rendering.sh`.

The process table compacts paths under Termux's `files` directory (`/data/data/com.termux/files/usr/bin/node` becomes `~/../usr/bin/node`). Child roles use a fixed two-space indent. One shared `LOCATION` width is sized from the longest detected Git branch plus five characters, allowing shorter branches to use that same available width; long directory suffixes are truncated with `..`, while short values remain whole. The longest non-Git directory name also informs the width, while preserving command space on narrow terminals.

Some processes do not do work themselves — they are **Agent hubs** that host other Agents. T3 Code is one (`t3 serve` runs its own Claude and Codex provider processes); a tmux server is another. Both are rendered as a section title and the Agents they host are grouped underneath.

Three orthogonal signals carry the whole structure:

| Signal | Answers | How |
|---|---|---|
| Color | what is this? | orange for Claude, cyan for Codex; hubs and `child` rows stay uncolored |
| Brackets | is this a group? | a hub's `ROLE` is wrapped — `[T3]`, `[TMUX]` — and left uncolored, because a title should not compete with the Agents it hosts |
| Indent | who does it belong to? | an Agent under a hub is indented one cell (` CLAUDE`); `child` rows are unaffected and keep their plain two-cell indent |

Keeping those three separate is the point. Earlier revisions tried to encode "who manages this" with color, which forced a fourth color into the palette and made an Agent's own identity depend on its host; the indent is also what distinguishes a hub's members from a standalone Agent that happens to be rendered right after the group.

The indent is a plain ASCII space, not a bullet glyph. `·` is multibyte, and `gawk` counts `length()` in *bytes* under the C locale — one missing UTF-8 locale and `sprintf("%-9s")` pads the nine-cell `ROLE` column short, shifting everything to its right. A space is the same visual language the `child` rows already use, and it has no locale prerequisite.

A tmux session is rendered only when it has Claude/Codex children of its own. A tmux that merely hosts the T3 server has none — its Agents belong to the `T3` row — so that session is not shown, and the `[T3]` title stands on its own. Empty sessions carry no information and would only take up tree space. The fixture for this contract is `tests/test_t3_managed_agents.sh`.

"Which processes are hubs" lives in one place, the `hub_kind()` function. Both the bracketed title and the tree's child enumeration read from it, so adding another host kind is a one-line change there rather than a new branch in every renderer. Keeping the *ancestor* search on the same predicate matters too: an earlier revision walked upwards looking for anything whose arguments merely mentioned `tmux`, which matched `sh -c tmux new-session ...` wrapper processes. An Agent under such a wrapper was registered to a PID that is never itself rendered — so the Agent vanished from the tree entirely while still being counted in the summary.
