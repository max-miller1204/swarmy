---
name: agents-dispatch
description: Phases 5–7 for the experimental `Dispatch: agents` mode — uses Claude Code's Agent fork feature with `isolation: "worktree"` instead of tmux panes.
---

# Agents dispatch mode

Use this file when the spec's `## Execution` section contains `Dispatch: agents`. It **replaces Phases 5–7** of the main `SKILL.md`. Phases 1–4, 8, 9, and 10 are unchanged.

This mode uses Claude Code's experimental Agent fork feature with `isolation: "worktree"` instead of spawning Claude CLI sessions in tmux panes. Each chunk runs as a background fork inside this Claude session. The running forks appear in the TUI panel below the prompt — `↑`/`↓` to navigate, `Enter` to open a fork's transcript, `x` to stop one, `Esc` to return to the prompt. Named forks surface as `@<name>` tags.

The forks **inherit the coordinator's full context** (spec, plan, locked interface signatures, conversation), so you do not need to write `CHUNK.md` files — the chunk briefing goes inline in each fork's prompt.

## Phase 5 — Preconditions for dispatch (agents mode)

Verify:
- `$CLAUDE_CODE_FORK_SUBAGENT` is set to `1`. If not, surface this and stop — this dispatch mode is gated on the experimental flag. Tell the user how to enable it (e.g. `export CLAUDE_CODE_FORK_SUBAGENT=1` in bash/zsh, `set -gx CLAUDE_CODE_FORK_SUBAGENT 1` in fish — then restart the Claude session).
- Claude Code is v2.1.117 or later. Check with `claude --version`. If older, surface and stop.
- The scaffold commit you just made is HEAD on the integration branch.
- Working tree still clean (`git status --porcelain` empty).

If any fail, explain what's wrong and stop. Do not force state. Do not silently fall back to tmux dispatch.

## Phase 6 — Dispatch (agents mode)

Launch all chunks in **a single message** as parallel `Agent` tool calls. Sequential `Agent` calls block on each other — true parallelism requires one message with N tool-use blocks.

For each chunk, the `Agent` call uses:
- `subagent_type`: **omit** (this is a fork — inherits coordinator context).
- `name`: the chunk's branch name (so it surfaces as `@<branch>` in the TUI panel).
- `isolation`: `"worktree"` — the harness creates a temporary git worktree branched from local HEAD.
- `description`: short, e.g. `"chunk: <branch>"`.
- `prompt`: the chunk's full briefing. Use `references/chunk-template.md` as the structure, but inline the content into the prompt rather than writing a `CHUNK.md` file. Include:
  - Goal
  - Files / areas owned
  - Locked interfaces — copy the trait/type signatures from the scaffold commit verbatim, with the "do NOT change" warning
  - Done-when criteria
  - Out-of-scope list
  - Ground rules (commit work to the branch, do not push, do not merge, stay inside the worktree)

The fork inherits the spec and the wave plan from your context, so you do not need to re-explain them — just brief the chunk-specific bits.

After launching, report the fork names so the user can navigate to them in the TUI. Tell them: "↑/↓ to navigate the agent panel, Enter to view a fork's live transcript, x to stop one."

## Phase 7 — Wait for completion (agents mode)

Forks auto-notify on completion as user-role messages in later turns. You do **not** poll, do **not** `Read` the output files (that pulls the fork's tool noise into your context and defeats the point of forking), and do **not** wake yourself up. The user may chat with you about other things while forks run; notifications arrive on their own.

As each notification arrives:
- Record the `(chunk → branch → worktree path)` mapping from the result. The `Agent` tool returns the worktree path and branch name for any fork that produced changes.
- If a fork returns with **no changes** (worktree was auto-cleaned because the fork made no edits), surface this immediately — the chunk produced nothing. The user decides whether to retry, abandon, or treat as a no-op.
- If a fork returns with a result that suggests it stopped on a blocker (asks a clarifying question, reports an error), surface that and ask the user how to proceed before launching follow-up work.

The user can press `Enter` on a fork in the TUI to inspect its transcript live — that's their tool, not yours. They can `x` to stop a fork. If they stop one, treat it as abandoned for fold-back purposes.

When all N forks have notified (completed, errored, or been stopped), advance to Phase 8 with the resulting branch list.

## Phase 8+ (unchanged)

Fold-back (`swarm-cherry-pick` / `swarm-apply`), cleanup (`swarm-fold-cleanup`, `swarm-sweep`), and recording are identical to the main `SKILL.md`. The worktrees created by `isolation: "worktree"` are real git worktrees registered in `.git/worktrees/`, so they appear in `git worktree list` and the plugin's fold-back scripts cherry-pick them into the integration branch the same way.

Caveat to verify on first use: the harness picks the branch name when `isolation: "worktree"` is set — it may not match the `name` you passed to the `Agent` call. Trust the branch name returned in each fork's result; do not assume it matches the chunk's intended branch name. If the auto-generated names are inconvenient for the spec annotations in Phase 10, consider renaming the branches before fold-back (`git branch -m <auto-name> <intended-name>`).
