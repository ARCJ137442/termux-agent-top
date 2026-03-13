# Configurable Agent Roots Design

**Goal:** Allow users to configure which root processes are treated as agent roots via an environment variable, replacing the hardcoded `claude/codex` list.

## Requirements

- Introduce `AGENT_TOP_ROOTS` (comma-separated) to define root process names.
- When `AGENT_TOP_ROOTS` is unset or empty after trimming, default to `claude,codex`.
- The root list affects:
  - Agent process tree roots
  - Agent CPU/RSS rollups
  - Summary line labels
- Use `CLAUDE/CODEX` colors for those names only; other roots use default coloring.
- Keep role column width and formatting consistent; non-root rows remain labeled `child`.

## Data Flow

1. Read `AGENT_TOP_ROOTS` at startup.
2. Normalize: trim whitespace, split by `,`, drop empty items, de-duplicate.
3. Build a lookup map for root detection.
4. Use this map for root discovery in both rollup and tree render passes.
5. Build the summary line dynamically based on the configured root list.

## UI Changes

- Summary line becomes dynamic: `<ROOT>: <count> proc  RSS <MiB>` for each configured root.
- Labels use uppercase of the root name (truncated to fit the 9-char role field where needed).
- Existing `CLAUDE/CODEX` styling remains; other roots are unstyled.

## Error Handling

- If `AGENT_TOP_ROOTS` resolves to an empty list, fall back to defaults.
- Unknown root names that have no running processes still appear in summary with zero counts.

## Testing

- Add tests that set `AGENT_TOP_ROOTS` to a custom value and verify:
  - The summary line contains the custom root label.
  - The process table includes that root as a role label.
- Keep default behavior tests intact when env var is not set.
