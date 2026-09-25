# termux-agent-top bug-fix plan

Date: 2026-09-25

## Goal

Make current Claude Code and Codex processes discoverable by semantic identity rather than process-tree depth or a single `comm` value. Keep the display compact enough for Termux work-state monitoring.

## Work items

1. Normalize Claude/Codex identity evidence.
   - Recognize wrappers, loader-backed Claude, Node-launched Codex, and current process names.
   - Treat recognized identities as canonical `claude`/`codex` for summaries and colors.
   - Treat descendants as `child` unless they independently match an agent identity.
2. Add deterministic process fixtures and regression tests.
   - Cover the reported Codex child false-positive.
   - Cover loader-backed Claude and Codex launcher forms.
3. Represent tmux as context only.
   - Show a tmux ancestor when it leads to a recognized agent.
   - Hide unrelated tmux siblings and non-agent branches.
   - Show all descendants after entering the recognized agent subtree.
4. Add a global CPU resource line above memory.
   - Normalize total process CPU by available CPU count.
   - Keep the existing agent CPU metrics separate.
5. Verify and publish.
   - Run syntax, smoke, fixture, and diff checks.
   - Inspect history/remotes/tags before commit, push, and fix-tag creation.

## Invariants

- A process is an agent root only from identity evidence or an explicitly configured exact custom root.
- Tree depth never promotes a child to `CLAUDE` or `CODEX`.
- The non-nesting assumption is used as a guardrail, not as the sole detector.
- No unverified commit, push, or tag.

## Current checkpoint

- Completed: semantic identity classification and canonical Claude/Codex roles.
- Completed: global CPU resource line above memory.
- Completed: deterministic identity regression fixture.
- Completed: tmux context-root rendering and filtering with deterministic fixture coverage.
- Pending: post-release system-wide design discussion using `$super-questioning`.
