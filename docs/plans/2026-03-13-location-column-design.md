# Agent LOCATION Column Design

**Goal:** Add a `LOCATION` column between `ROLE` and `COMMAND` in the process table so users can distinguish where each Agent is working.

## Requirements

- Column order: `PID | PPID | RSS_KB | %MEM | MEM | %CPU | CPU | ROLE | LOCATION | COMMAND`.
- Only `claude` / `codex` root process rows show a `LOCATION` value.
- `LOCATION` uses the root process working directory from `/proc/<pid>/cwd`.
- Output format:
  - If the working directory is inside a git repo and on a branch: `branch@folder`.
  - If not in a git repo (or branch not available): `folder` only.
- If `cwd` cannot be resolved, `LOCATION` is empty.
- Child process rows keep `LOCATION` empty.

## Data Flow

1. Resolve root process cwd via `/proc/<pid>/cwd` (readlink).
2. Extract folder name via `basename`.
3. Attempt to read branch via `git -C "$cwd" symbolic-ref --short HEAD`.
4. If branch lookup succeeds, return `branch@folder`. Otherwise return `folder`.

## UI Layout

- Add a fixed-width `LOCATION` column and include it in the table header and row formatting.
- Truncate the location string to the column width with `...` if needed.
- Keep the `COMMAND` column width independent from `LOCATION`.

## Edge Cases

- Detached HEAD: treat as no branch -> `folder`.
- No git repo: `folder` only.
- Permission or missing `/proc/<pid>/cwd`: empty location.

## Testing Updates

- Update `tests/test_agent_top.sh` to expect the `LOCATION` column in the header.
- Update diff-mode sample rows to include `LOCATION` only for root rows.
- Add assertions for `branch@folder` and `folder`-only samples.

## Implementation Notes

- Implement in `render_process_tree()` to keep the location logic close to the table renderer.
- Only compute location for `claude` / `codex` root rows to limit overhead.
