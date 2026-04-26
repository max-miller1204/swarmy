# swarmy

Spec-and-swarm for Claude Code: write a wave-structured spec, then execute it in parallel git worktrees + tmux panes.

## What it is

`/spec` is an interview-driven spec writer. It walks you through context, scope, design, and verification, then probes whether the work has a serial-foundation-then-parallel-leaves shape. If it does, the resulting `SPEC.md` carries explicit waves, locked interface contracts, and an `## Execution` block that downstream tooling can parse. The output format is plain markdown — readable on its own, consumable by anything that wants to act on it.

`/swarm` is the executor. It reads a spec, then has the coordinator (your current Claude session) write the scaffold and lock the interface contracts on trunk **before** any parallel work starts. Once the scaffold is committed, swarm dispatches each wave's leaf chunks to parallel Claude agents, one per chunk, each in its own git worktree and its own tmux pane. When chunks are done, swarm walks you through fold-back one branch at a time. Two delivery modes: **solo-local** (cherry-pick chunks straight onto trunk in your local repo) and **fork-pr** (each wave lands on its own branch, gets pushed to a fork, and is reviewed as a PR upstream).

## Why use this

- **Spec-first.** The spec is a durable artifact, not throwaway context. You can hand it to a teammate, archive it, or feed it to other tooling — it isn't trapped inside one session.
- **Coordinator does the scaffold.** Interface contracts get locked in a single serial commit before parallel chaos starts. Sub-agents read each other's signatures from the scaffold, not from a moving target.
- **Human as the clock.** No autonomous wave-to-wave overnight surprises. You decide when each wave kicks off, when chunks are done, when to fold back. swarm doesn't poll, doesn't time out chunks, doesn't retry.
- **Real isolation.** Each chunk runs in its own git worktree and its own tmux pane. No shared working directory, no stomping, no "wait, who edited this?". Worktrees are sibling directories of your repo, easy to inspect, easy to throw away.
- **Works on any Claude Code install.** No Node, no daemons, no custom orchestrator. Just `git`, `tmux`, the `claude` CLI, and bash. Installs through the native Claude Code plugin marketplace.
- **Two plugins, install only what you need.** `/spec` has zero runtime deps and is useful standalone — write a spec, hand it off to anything. `/swarm` is the heavier piece; install it only if you want the executor.

Compared to alternatives like orcha, orchas, taskplane-claude, or vanilla AgentTeams: those tend to be either heavier (custom orchestrators, daemons, dashboards) or thinner (a single agent prompt that hopes for the best). swarmy sits in the middle: durable spec, deterministic scaffold, real OS-level parallelism, human-driven fold-back.

## Prerequisites

**`/spec`:** nothing. It only uses Claude Code's built-in tools.

**`/swarm`:**
- `git`
- `tmux`
- `claude` CLI on `PATH`
- `bash` 3.2 or newer (macOS default works)
- macOS or Linux

**Optional for `/swarm`:** `gh` CLI for the `fork-pr` delivery mode (used to open pull requests against upstream).

### Worktree convention — read this before you install

`/swarm` creates one git worktree per chunk, and **the worktrees live as sibling directories of your repo, NOT inside it.** A repo at `~/code/foo` with a chunk on branch `bar` produces a worktree at `~/code/foo--bar`. swarm needs write access to the parent directory of your repo for this to work.

If your repo lives somewhere with a locked-down or shared parent (e.g. a workspace root), set `SWARMY_WORKTREE_BASE=/some/other/path` to redirect worktree creation to a directory you control. The `<repo-name>--<branch>` naming is preserved; only the parent changes.

## Install

Add the marketplace, then install one or both plugins:

```
/plugin marketplace add https://github.com/<your-github-username>/swarmy.git
/plugin install spec@swarmy
/plugin install swarm@swarmy
```

Both plugins are independently installable. If you only want the spec writer, install just `spec@swarmy` and skip `swarm@swarmy` — `/spec` works fine on its own and the resulting SPEC.md is consumable by any other tool you'd rather hand it to.

## Quickstart

In a tmux session, inside a clean git repo:

```
/spec               # interview, writes SPEC.md
# ...spec gets written, with waves...
/swarm-doctor       # verify preconditions (git, tmux, claude on PATH, etc.)
/swarm              # execute the next un-executed wave
# watch the panes; tell /swarm when chunks are done; it folds back
```

After Wave 1 folds back, run `/swarm` again to dispatch Wave 2. swarm reads the `_Wave N executed_` annotations in the spec to know which wave is next.

## Migrating from local skills

If you previously had `~/.claude/skills/spec/` or `~/.claude/skills/swarm/` (the pre-plugin versions), move them aside before installing — local skills and installed plugins with the same name can collide.

```
mv ~/.claude/skills/spec ~/.claude/skills/spec.bak
mv ~/.claude/skills/swarm ~/.claude/skills/swarm.bak
```

Then install via `/plugin install spec@swarmy` / `/plugin install swarm@swarmy`.

For ongoing development on swarmy itself, hack on a clone with the local skills renamed (e.g. `/spec-dev`, `/swarm-dev`) so they don't collide with the installed plugin you're using day-to-day.

## Commands

| Command | Description |
|---|---|
| `/spec [path]` | Interview the user and write a spec (default output: `./SPEC.md`) |
| `/swarm [path]` | Execute the next un-executed wave of a spec (default input: `./SPEC.md`) |
| `/swarm-doctor` | Preflight check for swarm's runtime preconditions |

## Examples

- [`examples/small-spec.md`](examples/small-spec.md) — one wave with three parallel chunks. Useful as a minimal template for "I want to add one feature with a couple of independent pieces."
- [`examples/multi-wave-spec.md`](examples/multi-wave-spec.md) — three dependency-ordered waves with their own scaffolds and chunks. Demonstrates the `_Wave N executed_` annotations swarm appends after each wave folds back, plus `fork-pr` delivery mode.

## Status

v0.1.0 — initial release. File issues at the GitHub repo.

## License

MIT.
