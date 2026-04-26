# Operations reference

This file documents the operations the `/swarm` skill performs by invoking bash scripts shipped with the plugin. Consult it whenever you need to pick an operation — don't guess at behavior or flags.

All scripts are invoked via:

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/<name>" <args>
```

Never rely on the executable bit (tarball-based marketplace installs may strip it). Always invoke through `bash`.

## Worktree naming convention

Worktrees live at `<parent-dir>/<repo-basename>--<branch>`. E.g. in `~/code/chatter`, branch `audio-recorder` lives at `~/code/chatter--audio-recorder`. The base path can be overridden via the `SWARMY_WORKTREE_BASE` env var; the default is the parent directory of the current repo. Absolute values are used as-is; relative values are resolved against the main worktree (so `SWARMY_WORKTREE_BASE=.swarmy/worktrees` produces in-repo worktrees at `<repo>/.swarmy/worktrees/<repo>--<branch>`).

All scripts in this reference operate on this convention. The "main worktree" is the original clone (the one whose `git rev-parse --show-toplevel` matches the repo root); chunk worktrees are siblings under the parent dir.

## Dispatch operations

### `swarm-dispatch`

**Purpose:** create one git worktree and one tmux pane (or window) per branch, in a single call.

**Invocation:**

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/swarm-dispatch" <branch1> [branch2 ...]
bash "${CLAUDE_PLUGIN_ROOT}/scripts/swarm-dispatch" --mode windows <branch1> [branch2 ...]
```

- Default mode (`--mode panes`, can be omitted): split the current pane into a tiled grid, one pane per branch. Best for ≤4 chunks so all agents are visible in one window.
- `--mode windows`: create one tmux window per branch instead of splitting panes. Each window is named after the branch. Best for >4 chunks, or when you want each agent in a clean dedicated window.

For each branch, the script:

1. Creates the worktree at `<parent>/<repo>--<branch>` (creating the branch if needed), branching off whatever HEAD is currently checked out in the main worktree.
2. Opens a pane (or window) `cd`'d into that worktree.
3. **Does not run any command in the pane** — the pane is left at a shell prompt so the model can write `CHUNK.md` first and then `tmux send-keys` the launch command without a race.

**stdout contract:** one line per branch, in input order, of the form:

```
<pane_id> <worktree_path>
```

Where `<pane_id>` is the tmux pane (or window) ID like `%17` or `@4`, and `<worktree_path>` is the absolute path to the new worktree.

**Preconditions:**

- `$TMUX` must be set (inside a tmux session).
- Working tree of the main worktree must be clean.
- Invoke from a fresh tmux window with a single full-window pane — the script reflows tiled layout from the current pane.

**Exit codes:** `0` on success; non-zero if any worktree creation or pane split fails. On failure, partially-created worktrees and panes are left as-is so you can inspect and recover.

### Three-step dispatch (race-avoidance pattern)

`swarm-dispatch` only sets up worktrees and panes. The model still drives the actual launch, in this exact order:

1. **Create worktrees + panes silently:**
   ```
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/swarm-dispatch" branch1 branch2 branch3
   ```
   Capture stdout — one `<pane_id> <worktree_path>` per branch.

2. **Write `<worktree_path>/CHUNK.md`** for each chunk, using `chunk-template.md` as the template. Fill in the per-chunk goal, files owned, locked interface signatures from the scaffold commit, done-when criteria, out-of-scope list, branch name, worktree path.

3. **Launch each agent** by sending the start command to its pane, one pane at a time:
   ```
   tmux send-keys -t <pane_id> 'claude "read CHUNK.md and execute it"' C-m
   ```
   Send sequentially and verify each pane got the command (e.g. `tmux capture-pane -p -t <pane_id> | tail -n 5`) before moving to the next. `tmux send-keys` can silently no-op if a pane closed between dispatch and send — sequencing makes the failure visible instead of letting one chunk silently never start.

This sequencing also avoids the race where the agent starts before its `CHUNK.md` exists.

## Fold-back operations

Swarm agents commit their work (per the chunk template's "Commit your work to this branch when done" rule), so the **default fold primitive is `swarm-cherry-pick`**. It preserves each commit (with its message) as its own entry on the integration branch. `swarm-apply` is the fallback when the agent left work uncommitted.

In fork mode, the main worktree must have the wave branch checked out before any cherry-pick — `swarm-cherry-pick` cherry-picks onto whatever HEAD is.

### `swarm-cherry-pick`

**Purpose:** cherry-pick every commit on `<branch>` that is ahead of the main worktree's currently-checked-out branch (the integration branch — trunk in solo mode, the wave branch in fork mode), in order, onto the main worktree.

**Invocation:**

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/swarm-cherry-pick" <branch>
```

**Behavior:**

- Looks up the worktree at `<parent>/<repo>--<branch>` and the main worktree.
- Computes `<integration>..<branch>` and cherry-picks each commit onto the main worktree's HEAD.
- **No-op if the branch has no commits ahead of the integration branch.** Prints a hint pointing at `swarm-apply` in that case.
- **Does not hardcode `main`** — it targets whatever branch the main worktree currently has checked out. So in fork mode, make sure the wave branch is checked out before invoking.

**Conflict semantics:** cherry-pick stops with markers in the main worktree. The script exits non-zero. Surface the conflicted files to the user, wait for manual `git cherry-pick --continue` or `--abort`, do not advance to the next branch.

Lockfile conflicts are common when parallel chunks each add deps. **General recipe:** take the integration branch's lock (`git checkout --ours <lockfile> && git add <lockfile>`), regenerate by running the package manager's install or check command (so the new deps from the cherry-picked commit get re-resolved into the lock), then `git add <lockfile> && git cherry-pick --continue`. Common lockfiles and their regen commands:

| Lockfile | Regen |
| --- | --- |
| `Cargo.lock` | `cargo check` (or `cargo check --workspace`) |
| `package-lock.json` | `npm install` |
| `pnpm-lock.yaml` | `pnpm install` |
| `bun.lockb` / `bun.lock` | `bun install` |
| `go.sum` | `go mod tidy` |
| `uv.lock` | `uv lock` |
| `poetry.lock` | `poetry lock --no-update` |
| `Gemfile.lock` | `bundle install` |
| `mix.lock` | `mix deps.get` |

**This recipe is for *derived* lockfiles only.** When the conflict is in the manifest itself (e.g. `pyproject.toml`'s `dependencies = [...]` line, `package.json`'s `dependencies` block, `Cargo.toml`'s `[dependencies]`), the manifest IS the source of truth — there's no upstream to regenerate from. `--ours` would silently drop the chunk branch's contribution and the regenerator wouldn't restore it. Resolve manifest-level conflicts by hand: edit the conflicted region to union both branches' changes, `git add <manifest>`, then `git cherry-pick --continue`. The general "stop on conflict, surface, resolve, continue" discipline still applies — just don't reach for the lockfile recipe when the conflict is in the manifest.

**Use when:** folding back a swarm chunk whose agent already committed (the default case).

**Worked example:**

```
# user said chunks are done; folding chunk-a back onto trunk:
bash "${CLAUDE_PLUGIN_ROOT}/scripts/swarm-cherry-pick" chunk-a
# on success, all of chunk-a's commits are now on trunk in the main worktree.
# on conflict, surface the failing files and stop.
```

### `swarm-apply`

**Purpose:** apply uncommitted changes (diff + untracked files) from a worktree branch into the integration branch. Fallback for chunks whose agent left work uncommitted.

**Invocation:**

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/swarm-apply" <branch>
```

**Behavior:**

- Operates on the worktree at `<parent>/<repo>--<branch>`.
- Runs `git diff HEAD | git apply --index -` against the main worktree, falling back to `--3way` on failure.
- Copies untracked files into the main worktree.
- **Only applies uncommitted work.** If the chunk branch has commits ahead of the integration branch, the script reports "Nothing to apply" — use `swarm-cherry-pick` for that case.

**Conflict semantics:** the `--3way` fallback may leave conflict markers in the main worktree. The script exits non-zero. Surface the conflicted files, wait for manual resolution, do not continue.

**Use when:** the chunk's agent didn't commit (rare — the chunk template tells them to). Or for integrating an in-progress worktree's changes into the integration branch without deleting the worktree.

**Worked example:**

```
# chunk-a was left with uncommitted work; integrate without deleting the worktree:
bash "${CLAUDE_PLUGIN_ROOT}/scripts/swarm-apply" chunk-a
# on success, the diff is staged on the main worktree's HEAD; the chunk worktree is unchanged.
```

### `swarm-fold-cleanup`

**Purpose:** after the chunk's commits are on the integration branch, remove the worktree, delete the branch, and kill any tmux panes/windows whose `pane_current_path` matches the worktree.

**Invocation:**

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/swarm-fold-cleanup" <branch>
```

**Behavior:**

1. Resolves the worktree path: `<parent>/<repo>--<branch>`.
2. Runs `git worktree remove --force <path>` from the main worktree.
3. Runs `rmdir -p "$(dirname <path>)"` (silently — ignores failures) to clean up empty intermediate parent dirs that result from slashed branch names. Example: branch `swarm/foo-wave-2-bar` produces worktree path `<parent>/<repo>--swarm/foo-wave-2-bar`; `git worktree remove` only removes the leaf, leaving `<parent>/<repo>--swarm/` empty after the last sibling is gone. `rmdir -p` walks up and stops at the first non-empty parent, so it's safe.
4. Runs `git branch -D <branch>` from the main worktree.
5. Lists tmux panes via `tmux list-panes -a -F "#{pane_id} #{pane_current_path}"`, filters for any pane whose path equals the worktree path or starts with `<worktree-path>/`, and kills each via `tmux kill-pane -t <pane_id>`.

The script is idempotent — if the worktree is already gone, the branch already deleted, or no panes match, it succeeds with a no-op for that step.

**Worked example:**

```
# chunk-a is fully folded; tear it down:
bash "${CLAUDE_PLUGIN_ROOT}/scripts/swarm-cherry-pick" chunk-a
bash "${CLAUDE_PLUGIN_ROOT}/scripts/swarm-fold-cleanup" chunk-a
# worktree removed, branch deleted, tmux panes for this chunk gone.
```

## Sweep operations

### `swarm-sweep`

**Purpose:** at the end of a wave, sweep any remaining chunk worktrees in one shot. Two-step interaction so the model can confirm the list with the user before destruction.

**Invocation (list):**

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/swarm-sweep"
```

Prints one line per candidate of the form `<worktree-path> <branch>`, suitable for showing the user verbatim. Does **not** delete anything.

**Invocation (confirm):**

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/swarm-sweep" --confirm
```

For each candidate: `git worktree remove --force <path>` + `rmdir -p "$(dirname <path>)" 2>/dev/null` (cleans up empty intermediate parent dirs from slashed branch names) + `git branch -D <branch>`, plus the tmux pane kill (same logic as `swarm-fold-cleanup`).

**Filter:** matches paths under `<parent>/<repo>--*` that are not the main worktree itself.

**Wave branches are preserved.** In fork mode, wave branches live in the main worktree (just `git checkout`ed there), so they're already excluded by the `<parent>/<repo>--*` filter — no special-casing needed. Their PR may still be open and depending on the branch.

**Worked example:**

```
# end of wave; ask the user whether to clean up:
bash "${CLAUDE_PLUGIN_ROOT}/scripts/swarm-sweep"
# show the printed list to the user via AskUserQuestion ("delete these N worktrees?")
# on yes:
bash "${CLAUDE_PLUGIN_ROOT}/scripts/swarm-sweep" --confirm
```

## Doctor

### `swarm-doctor`

**Purpose:** check that swarm's runtime preconditions are met. Prints a green/red checklist (one line per check) and exits non-zero on any failure.

**Invocation:**

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/swarm-doctor"
```

**Checks:**

- `git`, `tmux`, `claude`, `bash` ≥ 3.2 are on `PATH`.
- `$TMUX` is set (running inside a tmux session).
- Inside a git repo (`git rev-parse --git-dir` succeeds).

The slash command `/swarm-doctor` is a thin wrapper that runs this script and reports the output. Use the slash command for user-driven preflight; invoke the script directly inside other operations only when you need a programmatic check.
