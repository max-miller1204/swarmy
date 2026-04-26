# swarmy

Spec-and-swarm for Claude Code: write a wave-structured spec, then execute it in parallel git worktrees + tmux panes.

## What it is

`/spec` is an interview-driven spec writer. It walks you through context, scope, design, and verification, then probes whether the work has a serial-foundation-then-parallel-leaves shape. If it does, the resulting `SPEC.md` carries explicit waves, locked interface contracts, and an `## Execution` block that downstream tooling can parse. The output format is plain markdown — readable on its own, consumable by anything that wants to act on it.

`/swarm` is the executor. It reads a spec, then has the coordinator (your current Claude session) write the scaffold and lock the interface contracts on trunk **before** any parallel work starts. Once the scaffold is committed, swarm dispatches each wave's leaf chunks to parallel Claude agents, one per chunk, each in its own git worktree and its own tmux pane. When chunks are done, swarm walks you through fold-back one branch at a time. Two delivery modes: **solo-local** (cherry-pick chunks straight onto trunk in your local repo) and **fork-pr** (each wave lands on its own branch, gets pushed to a fork, and is reviewed as a PR upstream).

## How swarmy compares

swarmy fills the gap between vanilla Claude AgentTeams primitives and heavy custom multi-agent orchestrators.

|  | **swarmy** | **vanilla AgentTeams** | **other multi-agent orchestrators** |
|---|---|---|---|
| Engine | Current Claude session + bash scripts | `Agent({isolation: "worktree"})`, `SendMessage` | Custom Node/TS daemon, supervisor agent, or plugin scaffold |
| Workers you can watch live | Yes — `tmux attach` to raw stdout | No — opaque, summary on return | Sometimes (web dashboard, SSE) |
| Spec as durable artifact | `SPEC.md` with explicit waves | None | Per-task `PROMPT.md` |
| Coordinator commits scaffold first | Yes — interface contracts locked before fan-out | DIY | No — every chunk is fungible parallel work |
| Wave-by-wave history | Annotations appended to the spec | None | DIY or via dashboard |
| Fold-back | Interactive walkthrough, conflict-stop | DIY | Auto-merge, sometimes with reviewer agents |
| Hard deps | `git`, `tmux`, `claude`, `bash` 3.2+ | None extra | Often Node, custom runtime, dashboard server |
| Distribution | Native Claude Code plugin | Built into Claude Code | Per-project scaffold or npm install |

### vs vanilla Claude AgentTeams

AgentTeams gives you primitives: `Agent({ isolation: "worktree" })`, `SendMessage`, `Monitor`. Subagents run *inside* the Claude Code harness, invisibly — you only see the summary they return. That's perfect for delegating one or two opaque sub-tasks.

swarmy is the workflow layer on top: a spec format with explicit waves, locked interface contracts committed before dispatch, full `claude` CLI processes in tmux panes you can attach to live, and an interactive fold-back walkthrough. Workers survive the harness dying, and you can watch them think. AgentTeams answers *"how do I run another agent in isolation."* swarmy answers *"how do I parallelize a ten-chunk feature without the chunks stomping each other."*

### vs other multi-agent orchestrators

Most multi-agent orchestrators treat every piece of work as a fungible parallel chunk. The foundation that makes parallelism safe — locked trait signatures, agreed schemas, scaffolded module structure — either happens implicitly inside one parallel agent (where it gets stomped by siblings working from a different mental model), or as a manual pre-step you do outside the tool.

swarmy formalizes that step. The coordinator writes and commits the scaffold *serially* in your current session before any agent fans out. Sub-agents read each other's signatures from the scaffold commit, not from a moving target. *Five agents implementing against a `trait Storage` that's already in the repo* is a fundamentally different problem from *five agents trying to agree on what `trait Storage` should look like.*

No dashboard, no SSE, no background daemon to keep alive. Observability is `tmux attach`. State is git. If the orchestrator dies, the work doesn't.

## Why use this

- **Spec-first.** The spec is a durable artifact, not throwaway context. You can hand it to a teammate, archive it, or feed it to other tooling — it isn't trapped inside one session.
- **Coordinator does the scaffold.** Interface contracts get locked in a single serial commit before parallel chaos starts. Sub-agents read each other's signatures from the scaffold, not from a moving target.
- **Human as the clock.** No autonomous wave-to-wave overnight surprises. You decide when each wave kicks off, when chunks are done, when to fold back. swarm doesn't poll, doesn't time out chunks, doesn't retry.
- **Real isolation.** Each chunk runs in its own git worktree and its own tmux pane. No shared working directory, no stomping, no "wait, who edited this?". Worktrees are sibling directories of your repo, easy to inspect, easy to throw away.
- **Works on any Claude Code install.** No Node, no daemons, no custom orchestrator. Just `git`, `tmux`, the `claude` CLI, and bash. Installs through the native Claude Code plugin marketplace.
- **Two plugins, install only what you need.** `/spec` has zero runtime deps and is useful standalone — write a spec, hand it off to anything. `/swarm` is the heavier piece; install it only if you want the executor.

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

If your repo lives somewhere with a locked-down or shared parent (e.g. a workspace root), set `SWARMY_WORKTREE_BASE` to redirect worktree creation. Two forms:

- **Absolute path** (`SWARMY_WORKTREE_BASE=/some/other/path`) — used verbatim. Worktrees land at `/some/other/path/<repo>--<branch>`.
- **Relative path** (`SWARMY_WORKTREE_BASE=.swarmy/worktrees`) — resolved against your repo root. Worktrees land at `<repo>/.swarmy/worktrees/<repo>--<branch>`, i.e. **inside the repo**. Useful when you don't have write access to the parent dir. Add the base path to `.gitignore` so the main checkout doesn't see the nested copies as untracked, and be aware that ripgrep/IDE indexers will walk into the nested worktrees unless you configure them to skip the base path.

The `<repo-name>--<branch>` naming is preserved in both cases; only the parent changes.

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
