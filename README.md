# termux-agent-top

`termux-agent-top` is a small Termux-first shell monitor for AI agent workloads.

The repository is intentionally narrow in scope:

- one lightweight script
- one smoke test
- one focused job: show system pressure plus Claude/Codex process trees

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
- Agent CPU (raw core-equivalent)
- Agent CPU normalized to 0-100 based on detected CPU count
- Claude process count and total RSS
- Codex process count and total RSS
- a parent/child process tree rooted at `claude` and `codex`

## Usage

Run a one-shot snapshot:

```sh
./agent-top.sh --once
```

Run a live view:

```sh
./agent-top.sh
```

Live mode switches to the terminal's alternate screen, redraws in place, and restores the previous screen when it exits. This reduces visible flicker compared with clearing the whole screen each refresh.

Change refresh interval:

```sh
./agent-top.sh --interval 5
```

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
- helper subprocesses may still appear briefly on some shells
- output is optimized for quick diagnosis, not for machine-readable export

## License

MIT. See `LICENSE`.
