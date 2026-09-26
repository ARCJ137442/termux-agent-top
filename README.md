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
- press `k` once to arm the highest-CPU non-root child, then again within five seconds to `SIGKILL` that same eligible process
- press `Ctrl+K` to `SIGKILL` all non-root child processes under the configured agent roots
- press `q` to leave the live view

The summary stays pinned while the process tree scrolls; tmux rows appear only when they lead to agents, and unrelated tmux branches remain hidden. Root `claude`/`codex` processes are never selected by either kill hotkey. `Ctrl+K` remains immediate; use it deliberately.

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

The CPU and memory rows include proportional Claude, Codex, other, and idle/available segments; the Claude and Codex segments use their theme colors in styled terminals and show a truncated name when space allows. Active labels use black text through theme color plus reverse video: orange for Claude, cyan for Codex, and green for the `other` boundary `|`. The marker and its following green fill blocks are separate style segments with explicit resets, so reverse video cannot turn later blocks into dark squares. Agent totals include each root and its full descendant tree, while the per-type summary separates root and child RSS. The separate `AgentsCPU(norm)` line remains normalized against the CPUs available to the monitor. Global CPU is shown as both normalized percent and core-equivalent usage (`used/available cores`); it is an approximate whole-process measurement and does not require Termux:API or Android permissions.

The ANSI resource-bar rules and review checklist live in `docs/ansi-rendering-contract.md`; the focused byte-order regression suite is `tests/test_ansi_rendering.sh`.

The process table compacts paths under Termux's `files` directory (`/data/data/com.termux/files/usr/bin/node` becomes `~/../usr/bin/node`). Child roles use a fixed two-space indent. One shared `LOCATION` width is sized from the longest detected Git branch plus five characters, allowing shorter branches to use that same available width; long directory suffixes are truncated with `..`, while short values remain whole. The longest non-Git directory name also informs the width, while preserving command space on narrow terminals.
