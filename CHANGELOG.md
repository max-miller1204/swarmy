# Changelog

## Unreleased

- `swarm`: new `Dispatch:` field in the spec's `## Execution` section. Defaults to `tmux` (current behavior, backward-compatible). Opt in to `Dispatch: agents` to use Claude Code's experimental Agent fork feature with `isolation: "worktree"` instead of tmux panes — forks inherit coordinator context, surface in the in-TUI agent panel, and auto-notify on completion. Gated on `CLAUDE_CODE_FORK_SUBAGENT=1` and Claude Code v2.1.117+. New reference: `references/agents-dispatch.md` (Phases 5–7 for agents mode; other phases unchanged).
- `swarm`: Phase 7 (tmux dispatch) rewritten from passive "user reports done" to active completion watching via the harness's `Monitor` tool plus per-worktree sentinel files (`.swarm-done` / `.swarm-blocker`). Coordinator gets one notification per chunk transition, plus `ALL_DONE` when the wave finishes. Long waves use `persistent: true` since `Monitor`'s timeout caps at 1h.
- `swarm`: chunk template instructs each agent to `touch .swarm-done` (or write `.swarm-blocker` with a one-line reason) before going idle. Required for the new Phase 7 watcher to surface completion.

## 0.1.0 — Initial release

- Two plugins under one marketplace: `spec` and `swarm`.
- `spec`: interview-driven SPEC.md writer with explicit wave structure.
- `swarm`: execute spec waves in parallel git worktrees and tmux panes. Solo-local and fork-pr delivery modes.
- `swarm-doctor`: preflight check for `git`, `tmux`, `claude`, `$TMUX`, and a git repo.
- Spec format: `1`.
