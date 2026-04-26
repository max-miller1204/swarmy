---
name: swarm
description: "Execute a spec in parallel git worktrees, one wave at a time. Scaffolds the foundation serially in the current session, dispatches leaf chunks to parallel Claude agents via tmux, then walks the user through folding each branch back into trunk. Triggers on: 'swarm', 'swarm this', 'parallelize this', 'dispatch swarm', 'run in parallel worktrees', 'execute this spec', 'scaffold and fan out', 'run wave N', 'fan out the work'. Takes optional $1 = path to spec file (defaults to ./SPEC.md). Use /spec first to write the spec; use this skill to execute it."
version: 0.1.0
---

You orchestrate parallel work across git worktrees using the bash scripts shipped with this plugin (under `${CLAUDE_PLUGIN_ROOT}/scripts/`). You are the **coordinator**: you do the serial scaffold work in this session, spawn other Claude agents in tmux panes/windows to do leaf work in parallel, then walk the user through folding each branch back.

Consult `references/operations.md` whenever you need to pick an operation — don't guess at behavior or flags.

This skill supports two **delivery modes**, declared per-spec:

- **solo-local** (default) — fold each wave's work directly onto trunk. No remotes, no PRs. The flow documented inline below.
- **fork-pr** — each wave lands on its own branch, gets pushed to a fork, and is reviewed via PR upstream. Phases 1.5, 3.5, and 8.5 are fork-only and live in `references/fork-mode.md`. Read that file in full before doing fork-mode work.

The term **integration branch** is used throughout. In solo mode it's trunk. In fork mode it's the wave branch. Substitute accordingly.

## Phase 1 — Load the spec

Read `$1` if given, else `./SPEC.md`. If neither exists, tell the user to run `/spec` first and stop.

### 1a — Pick a wave

Look for a **Waves** section in the spec.

- **If waves are present** (the primary path): scan for any line matching `Wave N executed` (case-insensitive; surrounding underscores/italic markers optional, so a hand-edited annotation like `Wave 2 executed 2026-04-20: ...` still detects). Those waves are done. If exactly one wave remains un-executed, surface that choice in plain text and use it directly — no need to prompt for a single option. Otherwise offer the first un-executed wave via `AskUserQuestion`. Use the chosen wave's chunks and scaffold verbatim; do not re-chunk.
- **If no waves section**: treat the spec as one wave. You'll need to analyze parallelizability yourself in the next phase.

### 1b — Resolve delivery mode

Look for an `## Execution` section in the spec. Parse it line-by-line, splitting each line on the first `:` into a key/value pair. Apply these tolerance rules:

- **Case-insensitive keys** — `Delivery mode`, `delivery mode`, `DELIVERY MODE` all match.
- **Whitespace-lenient** — accept any amount of whitespace around `:`, trim values.
- **Ignore unknown keys and free text** — only known `Key: value` lines count.
- **First match wins** — if a key appears twice, take the first and warn.

Then:

- If `Delivery mode: solo-local` is present → solo mode. Continue with this file.
- If `Delivery mode: fork-pr` is present → fork mode. Read `references/fork-mode.md` now, then come back. Don't ask about other fork-mode fields yet (remotes, base strategy) — those are deferred to the phases that need them.
- If the section is missing or `Delivery mode:` is absent → `AskUserQuestion` for delivery mode only:
  - `solo` (current behavior; fold to trunk)
  - `fork` (wave branches; opt-in push/PR — see references/fork-mode.md)

  Hold the answer in memory for this run. **Don't write to the spec yet** — Phase 4 bundles the `## Execution` section update into the scaffold commit. Writing here would dirty the working tree right before Phase 3 verifies it's clean, and bail the run on the user's own well-meaning edit.

The remaining phases are written in solo-mode terms with notes for fork mode. **Solo mode is byte-identical to the previous version of this skill.**

## Phase 2 — Propose the wave plan

Present to the user:

1. **Scaffold** — files/modules to land serially before dispatch. Includes: workspace manifest, shared types, locked interface contracts (trait signatures, type defs), stub modules for each future chunk, CI config.
2. **Chunks** — for each: branch name (kebab-case, will be the worktree suffix), goal, files/areas it owns, explicit interfaces with other chunks, done-when criteria (ideally a smoke test).
3. **Intra-wave sequencing** — any pairs that must be serialized (e.g. chunk B after chunk A because they touch the same crate).

If the spec did not pre-chunk: analyze independence. Good fit: disjoint files/subsystems, clear contracts. Bad fit: single-file refactors, tight sequential deps, shared-state edits. If it doesn't parallelize, say so and stop — recommend serial work.

Use `AskUserQuestion` to confirm the plan before doing anything destructive. Let the user edit the chunk list.

## Phase 3 — Preconditions for scaffold

Verify:
- Inside a git repo: `git rev-parse --git-dir` succeeds
- Working tree clean: `git status --porcelain` is empty
- Starting branch is appropriate for the mode:
  - **solo**: on trunk (`main`, `master`, or whatever `git symbolic-ref refs/remotes/origin/HEAD` resolves to; fall back to asking if unclear).
  - **fork**: on trunk OR on the wave-base branch resolved in Phase 1.5 (see `references/fork-mode.md`). The wave branch itself doesn't exist yet; it's created in Phase 3.5.

If any fail, explain what's wrong and stop. Do not force state.

In fork mode, the next step is Phase 3.5 (create the wave branch) before scaffolding — see `references/fork-mode.md`.

## Phase 4 — Build the scaffold in this session

You (the coordinator) write the scaffold files yourself. The other agents aren't running yet — this is all you.

- Write the workspace/package manifest, shared types, interface contracts, stub modules for each chunk, CI.
- If Phase 1b resolved a delivery mode that wasn't already in the spec, append a minimal `## Execution` section to the spec now. Place it just before the first existing `##` section (typically `## Waves`); if the spec has only an H1 and no other `##` headers, append at the end.
- Run the stack's standard build or typecheck command — whatever's fast enough to fail on a broken scaffold (`cargo check`, `tsc --noEmit`, `go build ./...`, `mypy`/`pyright`, `mvn compile -q`, `bun run typecheck`, etc.). **Do not proceed if it fails.** Fix and re-check.
- Commit everything (scaffold + the spec's new Execution section, if any) in a single commit with a message describing what contracts were locked. Example: `scaffold: lock SttEngine + LlmProvider + Recorder + … contracts`.

The scaffold commit lands on the integration branch — trunk in solo mode, the wave branch in fork mode (since Phase 3.5 already checked it out). Either way, it's load-bearing: every parallel chunk imports from it. Nail it down before dispatch.

In fork mode, this means trunk is **not** modified — it stays at upstream's HEAD until the PR merges upstream.

## Phase 5 — Preconditions for dispatch

Verify:
- `$TMUX` is set (inside a tmux session)
- The scaffold commit you just made is HEAD on the integration branch (trunk in solo mode, the wave branch in fork mode). Check with `git rev-parse HEAD` and compare to the scaffold commit's SHA.
- Working tree still clean (`git status --porcelain` empty)
- Invoke from a fresh tmux window with a single full-window pane — the dispatch script reflows tiled layout from the current pane.

If any fail, explain what's wrong and stop. Do not force state.

## Phase 6 — Dispatch

Pick the dispatch mode by chunk count:
- **≤4 chunks** → default mode (panes in the current window)
- **>4 chunks** → `--mode windows` (one tmux window per branch)

Three-step dispatch, in this order (avoids a race where Claude starts before its `CHUNK.md` exists):

1. **Create worktrees + panes/windows silently.** Invoke the dispatch script:
   ```
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/swarm-dispatch" branch1 branch2 ...
   ```
   or
   ```
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/swarm-dispatch" --mode windows branch1 branch2 ...
   ```
   This creates the worktrees at `<parent>/<repo>--<branch>` and opens panes/windows cd'd into each. The script prints one line per branch on stdout, in input order, of the form `<pane_id> <worktree_path>` — capture this output for step 3.

2. **Write `<worktree>/CHUNK.md`** for each chunk, using `references/chunk-template.md` as the template. Fill in: name, goal, files owned, interfaces (copy the locked signatures from the scaffold commit verbatim), done-when, out-of-scope, branch name, worktree path.

3. **Launch the agents.** Using the pane IDs from step 1's stdout, send the start command to each pane in turn:
   ```
   tmux send-keys -t <pane_id> 'claude "read CHUNK.md and execute it"' C-m
   ```
   Send sequentially and verify the command landed in each pane (a quick `tmux capture-pane -p -t <pane_id> | tail -n 5` is cheap) before moving to the next. `tmux send-keys` can silently no-op if a pane closed between dispatch and send — sequencing makes the failure visible instead of letting one chunk silently never start.

Report the pane/window IDs and worktree paths so the user can navigate.

## Phase 7 — Hand off

Do not poll. Do not wake up and check on agents. The user watches the panes and tells you when chunks are done. If the user asks you to check in on a specific chunk, you can inspect its worktree via `Read`/`Bash` — but don't steer the sub-agent unless asked.

## Phase 8 — Fold back

When the user says chunks are done, walk through each branch **one at a time**. For each, ask via `AskUserQuestion`:

- **Apply only** — keep the worktree for inspection
- **Full fold** — apply + stage + remove worktree + delete branch
- **Skip** — leave this one for later

**Primitive choice:** swarm agents commit their work (per the CHUNK.md template), so the default fold primitive is **`swarm-cherry-pick`**. It cherry-picks every commit on the chunk branch that is ahead of the main worktree's currently-checked-out branch — i.e. the integration branch — preserving each commit's message as its own entry on the integration branch. Fall back to `swarm-apply` only if the agent left work uncommitted — `swarm-apply` only applies the uncommitted diff and will say "Nothing to apply" on a committed branch.

In fork mode, make sure the main worktree has the wave branch checked out before running `swarm-cherry-pick`. The scripts don't hardcode `main`; they target whatever HEAD is.

So:

- **Apply only** → run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/swarm-cherry-pick" <branch>` (committed) or `bash "${CLAUDE_PLUGIN_ROOT}/scripts/swarm-apply" <branch>` (uncommitted).
- **Full fold** → cherry-pick (or apply), then tear down. From the main repo root (`cd` into it first):
  ```
  bash "${CLAUDE_PLUGIN_ROOT}/scripts/swarm-cherry-pick" <branch>
  # OR for uncommitted work:
  # bash "${CLAUDE_PLUGIN_ROOT}/scripts/swarm-apply" <branch>

  bash "${CLAUDE_PLUGIN_ROOT}/scripts/swarm-fold-cleanup" <branch>
  ```
  `swarm-fold-cleanup` removes the worktree at `<parent>/<repo>--<branch>`, cleans up empty intermediate parent dirs (relevant when branch names contain `/`, e.g. `swarm/foo-wave-2-bar` → `<repo>--swarm/foo-wave-2-bar`, leaving `<repo>--swarm/` empty after the last sibling), deletes the branch, and kills any tmux panes whose `pane_current_path` matches.

**On conflict** (either the cherry-pick or `swarm-apply`'s `--3way` fallback leaves markers): stop immediately. Print the conflicted files. Resolve in the main repo, then `git cherry-pick --continue`. Lockfile conflicts (`Cargo.lock`, `package-lock.json`, `pnpm-lock.yaml`, `bun.lockb`, `go.sum`, `uv.lock`, `poetry.lock`, `Gemfile.lock`, etc.) are common when parallel chunks each add deps — see `references/operations.md` → `swarm-cherry-pick` conflict semantics for the standard recipe. **Do not advance to the next branch until the current state is clean.** Check with `git -C <main> status --porcelain`.

**If a chunk's pane was closed before fold-back** (the user accidentally killed it, or tmux exited), the branch and worktree still exist — `swarm-cherry-pick <branch>` and `swarm-fold-cleanup <branch>` work the same way. The pane-kill step inside `swarm-fold-cleanup` is a no-op when no panes match.

In fork mode, after Phase 8 completes successfully, continue to Phase 8.5 (push and open PR) — see `references/fork-mode.md`. In solo mode, skip Phase 8.5 and go straight to Phase 9.

## Phase 9 — Cleanup

After all branches are folded or skipped, ask the user whether to sweep remaining swarm worktrees. The sweep is two-step so you can show the candidate list before destruction:

1. **List candidates:**
   ```
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/swarm-sweep"
   ```
   Prints one `<worktree-path> <branch>` line per candidate. Show the list to the user via `AskUserQuestion` and get explicit confirmation.

2. **Confirmed delete:**
   ```
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/swarm-sweep" --confirm
   ```
   Removes each worktree, deletes its branch, and kills lingering tmux panes the same way `swarm-fold-cleanup` does.

**Wave branches are preserved**, never swept. They live in the main worktree (just `git checkout`ed there), so they're already excluded by the `<parent>/<repo>--*` filter — no special-casing needed. Their PR may still be open and depending on the branch.

## Phase 10 — Record the wave

Append a one-line note to the spec file. The format depends on delivery mode:

- **solo**:
  ```
  _Wave {{N}} executed {{YYYY-MM-DD}}: branches {{comma-separated list}}_
  ```
- **fork**:
  ```
  _Wave {{N}} executed {{YYYY-MM-DD}} on branch {{wave-branch}}; chunks {{list}}; PR {{url-or-"not pushed"}}_
  ```

Use today's date (from the environment context). This is per-run history — on the next `/swarm` invocation, this note is how you know which wave to offer next.

**Commit the annotation** (e.g. `chore: record wave N`). Leaving the spec edit uncommitted dirties the working tree, which breaks the next `/swarm` invocation's Phase 3 cleanliness check on the same repo. In solo mode the commit lands on trunk alongside the cherry-picked chunk commits. In fork mode it lands on the wave branch after Phase 8.5 has already pushed — so this commit is local-only unless the user pushes the wave branch again to update the PR description's history. That's fine; the PR's diff is unaffected.

The annotation lives at the bottom of the spec, **not** inside the `## Execution` section. Execution captures durable preferences; annotations capture per-run history. Don't conflate them.

If the spec had no Waves section, append instead:

```
_Executed {{YYYY-MM-DD}}: branches {{list}}_
```

## Ground rules

- **You don't merge.** Even in fork mode, opening a PR is the boundary — merging is the human's decision upstream.
- **You push only with explicit confirmation, only in fork mode, and only the wave branch.** Chunk branches are never pushed by this skill. Solo mode never pushes anything.
- **You never `--force` push.** If a push is rejected, surface the output and let the user diagnose.
- **You don't skip hooks** (no `--no-verify`). If a commit hook fails during the scaffold, fix the underlying issue.
- **You stop on conflict.** Never pass `-Xtheirs` or similar to paper over a 3way conflict.
- **You do not unilaterally edit locked interfaces.** If a chunk turns out to need a different signature mid-dispatch, that's a spec change — stop and surface it.
- **The human is the clock.** You don't poll agents, don't time out chunks, don't retry. The user drives when each phase advances.
