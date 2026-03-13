# AgentsCPU Normalization Design

**Goal:** Add a normalized AgentsCPU percentage (0-100%) alongside the existing raw core-equivalent percentage to avoid misinterpretation on multi-core Termux devices.

## Requirements

- Keep existing `AgentsCPU` (raw, core-equivalent) output and risk thresholds unchanged.
- Add a new `AgentsCPU(norm)` line showing normalized percentage capped at 100%.
- Normalized CPU uses a reliable CPU-count detection order:
  1. `/proc/self/status` → `Cpus_allowed_list`
  2. `/sys/devices/system/cpu/online`
  3. `nproc`
- If CPU count cannot be determined or is <= 0, default to 1.
- Update tests to validate the new normalized line in diff/test modes.

## Data Flow

1. Collect raw `AGENT_CPU_PERCENT` as today.
2. Detect `CPU_COUNT` via cpuset/online/nproc fallback.
3. Compute `AGENT_CPU_NORM_PERCENT = min(100, AGENT_CPU_PERCENT / CPU_COUNT)`.
4. Render:
   - `AgentsCPU:` (raw)
   - `AgentsCPU(norm):` (normalized)

## UI Changes

- Add a second summary line under `AgentsCPU`:
  - `AgentsCPU(norm): <bar> <percent>`
- Reuse the same bar style and color thresholds as raw.

## Error Handling

- Parsing `Cpus_allowed_list` and `cpu/online` supports ranges like `0-3,6,8-9`.
- If parsing fails, fallback to the next source.
- If all sources fail, use CPU count = 1.

## Testing

- Extend diff/test mode to emit a deterministic `CPU_COUNT` and normalized value.
- Update `tests/test_agent_top.sh` with:
  - Presence of `AgentsCPU(norm)` line.
  - Correct normalized percentage string for test mode.

## Notes

- Risk thresholds remain based on raw `AGENT_CPU_PERCENT` to preserve current behavior.
- Documentation update to clarify raw vs normalized CPU semantics.
