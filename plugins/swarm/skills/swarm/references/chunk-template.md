# Chunk: {{name}}

You are one of several parallel Claude agents implementing a spec. This file is your task. Other agents are implementing sibling chunks in their own git worktrees at the same time.

## Goal
{{one-sentence goal}}

## Files / areas you own
- {{path}}
- {{path}}

## Interfaces with other chunks (locked in the scaffold commit — do NOT change)
- {{trait or type}}: `{{signature}}`
- {{trait or type}}: `{{signature}}`

Changing these breaks sibling chunks. If you think the interface is wrong, stop and tell the user — do not edit it unilaterally.

## Done when
- [ ] {{criterion — ideally a smoke test command the user can run}}
- [ ] {{criterion}}

Tick each box when satisfied. When all are ticked, tell the user you're done and wait.

## Out of scope
{{what NOT to touch — explicit list of files/areas owned by other chunks}}

## Ground rules

1. Stay inside this worktree. You are on branch `{{branch}}` at `{{worktree-path}}`.
2. Do not touch files owned by other chunks. If you need something from them, note it and ask the user.
3. Commit your work to this branch when done, but do not push and do not merge. The coordinator session will fold your branch back into the integration branch (trunk in solo-local delivery; the wave branch in fork-pr delivery — the coordinator handles either).
4. If you hit a blocker, stop and tell the user. Do not attempt to coordinate with sibling agents directly.
