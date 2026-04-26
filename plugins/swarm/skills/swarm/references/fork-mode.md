# Fork-mode reference

This file covers the swarm phases that only run in **fork-pr** delivery mode — where each wave lands on its own branch, gets pushed to the user's fork, and is reviewed as a pull request upstream. Solo-local mode is documented inline in the main `SKILL.md` and isn't repeated here.

The main `SKILL.md` directs you here when it sees `Delivery mode: fork-pr` in the spec's `## Execution` section. Read this file in full before doing fork-mode work — the phases interlock, and the parser/self-heal rules apply across all of them.

## Big picture

The branch shape:

```
upstream/<default-branch>
  └─ swarm/<spec-slug>-wave-<N>          ← integration branch; PR opens against this
     ├─ <chunk-a>                          ← worktree branch, cherry-picks back to wave
     ├─ <chunk-b>
     └─ <chunk-c>
```

Differences from solo mode:

- The **integration branch** is the wave branch, not trunk. All scaffold and fold-back work targets the wave branch. Trunk stays at upstream's HEAD until the PR merges upstream.
- The wave branch is preserved after fold-back (the PR may still be open). Only chunk branches and worktrees are swept.
- After fold-back, you may push the wave branch to the fork and open a PR — **always with explicit user confirmation**, never automatically.

Everywhere the main file says "trunk" or "main," substitute "the integration branch" — which in fork mode is the wave branch.

## Reading the `## Execution` section

The spec carries durable workflow preferences in a markdown section like:

```markdown
## Execution

Delivery mode: fork-pr
PR unit: wave
Base strategy: upstream-trunk
Branch naming: swarm/{slug}-wave-{n}
Fork remote: origin
Upstream remote: upstream
```

Parse it with these rules:

- **Case-insensitive keys** — `Delivery mode`, `delivery mode`, and `DELIVERY MODE` all match.
- **Whitespace-lenient** — accept any amount of whitespace (or none) around the `:`, and trim the value.
- **Ignore unknown keys and free text** — only `Key: value` lines that match a known key are parsed; everything else is skipped (including blank lines, comments, and notes the user added inside the section).
- **First match wins** — if a key appears twice, take the first occurrence and warn the user about the duplicate.

The parser is line-based, not a strict YAML parser. Keep it simple — read the section's lines, split on the first `:`, normalize the key.

### Self-heal pattern

Fields can be missing. When a phase needs a missing field:

1. Resolve it (auto-detect from the repo if possible, otherwise `AskUserQuestion`).
2. Write the resolved value back into the `## Execution` section in the spec.
3. Surface the write in plain text: e.g. "Updated SPEC.md → set Fork remote: origin".

Don't pre-resolve fields a phase doesn't yet need. If the user bails out before reaching Phase 8.5, they should never have been asked about remotes. This keeps the conversation tight and respects the user's time.

When writing back, always re-read the file first (`Read`) — never assume it's unchanged between reads. The user might be editing the spec in another window.

## Phase 1.5 — Wave base selection

Read `Base strategy:` from the `## Execution` section.

- `upstream-trunk` → branch the wave from `<upstream>/<default-branch>`. No prompt.
- `stack-on-previous-wave` → branch from the most recent previous wave's branch (look at the `_Wave N executed …_` annotations in the spec to find it). If no previous wave exists, fall back to `upstream-trunk` silently.
- `ask-per-wave` (also the default if the field is missing) → if a previous wave exists in this spec, `AskUserQuestion`:
  - "Branch off `<upstream>/<default-branch>`" (independent waves)
  - "Branch off `<previous-wave-branch>`" (stacked, dependent)

  Otherwise default to `upstream-trunk` silently.

The result is the **wave base** — the commit the wave branch will be created from. Hold onto it for Phase 3.5.

To resolve `<upstream>/<default-branch>`:
- Upstream remote name comes from `Upstream remote:` in the spec, defaulting to `upstream` if missing. If that remote doesn't exist, fall back to `origin`. If neither works, ask.
- Default branch comes from `git symbolic-ref refs/remotes/<upstream>/HEAD` (strip the `refs/remotes/<upstream>/` prefix). If that fails, ask.

## Phase 3.5 — Create the wave branch

This phase replaces "you must be on trunk" with "you must be on the integration branch."

1. Compose the wave branch name. Default: take `Branch naming:` from the `## Execution` section (e.g. `swarm/{slug}-wave-{n}`), substitute `{slug}` with the spec filename slug and `{n}` with the wave number. Confirm/edit via `AskUserQuestion` so the user can override per-wave if they want.

2. Check whether the branch already exists locally (`git rev-parse --verify <wave-branch>`). If yes, surface this and `AskUserQuestion`:
   - **Resume on existing branch** — useful if a previous run was interrupted and the work is partially done.
   - **Pick a different name** — re-prompt for the branch name.
   - **Abort** — don't clobber.

   Never silently force-create over an existing branch — the user might have unpushed work or an open PR pointing at it.

3. Create and check out the branch:
   ```
   git checkout -b <wave-branch> <wave-base>
   ```
   HEAD is now the wave branch. All subsequent scaffold and chunk work targets this branch.

4. Update the dispatch precondition from the main file: instead of "scaffold commit is on trunk," verify "scaffold commit is on `<wave-branch>` and is HEAD."

The dispatch and fold scripts (`swarm-dispatch`, `swarm-cherry-pick`) all branch off / fold onto whatever the main worktree has currently checked out, so no script changes are needed — checking out the wave branch in the coordinator before dispatch is sufficient. (See `operations.md`.)

## Phase 8.5 — Push and open the PR

Run this only after Phase 8 (fold-back) has fully completed and the working tree is clean. **Only the wave branch is pushed.** Chunk branches stay local.

### Step 1 — Resolve fork and upstream remotes

1. Read `Fork remote:` and `Upstream remote:` from the `## Execution` section. If both present, use them.
2. Otherwise, list `git remote -v` and apply the heuristic:
   - If `origin` and `upstream` both exist, propose `origin` = fork, `upstream` = canonical.
   - If only one remote exists, surface this — the user likely needs to add a fork remote first. Ask before proceeding.
   - If multiple remotes exist with non-standard names, `AskUserQuestion` with options for each.
3. Write any resolved remote back to the `## Execution` section.

### Step 2 — Detect upstream's default branch and `owner/repo`

- Default branch: `git symbolic-ref refs/remotes/<upstream>/HEAD`, strip the `refs/remotes/<upstream>/` prefix. Fall back to asking.
- Upstream slug: parse `git remote get-url <upstream>`. Both SSH (`git@github.com:owner/repo.git`) and HTTPS (`https://github.com/owner/repo.git`) forms need handling — strip the prefix and the `.git` suffix.
- Fork owner: parse `git remote get-url <fork>` the same way. Take just the owner (the part before the `/repo`).

### Step 3 — Confirm push and PR

`AskUserQuestion`:
- **Yes — push and open PR**
- **Push but don't open PR** — for when the user wants to inspect the pushed branch before opening
- **No — leave local** — wave is done locally, do nothing remote

On any "push" choice, run:
```
git push <fork> <wave-branch>
```
Never pass `--force`. If the push fails (rejected, etc.), surface the output and stop — let the user diagnose.

### Step 4 — Compose the PR title and body

Compose **before** running `gh`, and show the user before sending.

**Title**: extract the first H1 (`# ...`) line from the spec. Strip the leading `# ` and any trailing whitespace. Append `: wave <N>`.
- Example: spec heading `# Audio recording pipeline` + wave 2 → `Audio recording pipeline: wave 2`.
- Fallback: if no H1 exists, use the spec filename slug → `SPEC: wave 2`. Warn the user that no title was found.

**Body**: use this template literally, substituting placeholders. Use the spec's relative path (relative to repo root) for the link.

```
Wave <N> of [<spec-title>](<spec-relative-path>).

## Chunks in this wave

- `<chunk-branch-1>` — <chunk-goal>
- `<chunk-branch-2>` — <chunk-goal>

## Verification

<copy the spec's Verification section verbatim, or "See SPEC.md" if it's longer than ~30 lines>

---
_Generated by `/swarm`. Spec: `<spec-relative-path>`._
```

If the spec isn't tracked by git (`git ls-files --error-unmatch <spec-path>` fails), drop the markdown link and just reference the path in plain text — the link would 404 in the PR description.

### Step 5 — Run `gh pr create`

Show the user the composed title, body, and exact command. Get explicit confirmation. Then run:

```
gh pr create \
  --repo <upstream-owner>/<upstream-repo> \
  --base <upstream-default-branch> \
  --head <fork-owner>:<wave-branch> \
  --title "<composed-title>" \
  --body "<composed-body>"
```

`--repo` is required because the wave branch's tracking remote is the fork, not the canonical. Without it, `gh` opens the PR in the wrong repository.

Capture the PR URL from `gh`'s output for the wave annotation in Phase 10.

### Step 6 — Fallback if `gh` is missing or unauthenticated

If `gh` is not installed or `gh auth status` fails, don't abort. Print:

1. The exact `gh pr create` command (with the composed title and body) so the user can run it once they install/auth.
2. The GitHub compare URL: `https://github.com/<upstream-owner>/<upstream-repo>/compare/<upstream-default-branch>...<fork-owner>:<wave-branch>`. This opens a pre-filled PR creation page in the browser — the manual fallback path.

Mark the PR URL as `not pushed` (or `pending — see compare URL`) in the wave annotation.

## Phase 9 considerations

Wave branches live in the main worktree (just `git checkout`ed there) and are NOT in the sweep set. The existing sweep filter `<parent>/<repo>--*` only matches chunk worktrees, so wave branches are excluded by construction. Don't add the wave branch to the cleanup. The PR may still be open and depending on it.

## Phase 10 annotation

Use the fork-mode annotation format:

```
_Wave <N> executed YYYY-MM-DD on branch <wave-branch>; chunks <list>; PR <url-or-"not pushed">_
```

This complements (does not replace) the `## Execution` section. Execution captures durable preferences; wave annotations capture per-run history. Don't conflate them.
