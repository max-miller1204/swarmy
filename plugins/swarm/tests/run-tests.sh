#!/usr/bin/env bash
# run-tests.sh — end-to-end harness for the swarm plugin's bash scripts.
#
# Creates a sandbox git repo under $TMPDIR, exercises each script through
# representative scenarios, asserts expected outcomes, and cleans up on
# exit. Self-contained: no external test framework, no network, no
# pollution of the user's tmux server (uses a private socket).
#
# Usage:
#   bash plugins/swarm/tests/run-tests.sh           # run all
#   bash plugins/swarm/tests/run-tests.sh -v        # verbose (show command output)
#   bash plugins/swarm/tests/run-tests.sh <name>... # run only matching tests
#
# Exit 0 if all tests pass; non-zero if any failed.
#
# What's covered (one section per script + integration scenarios):
#   - swarm-doctor:       preflight checklist exits cleanly under tmux+git
#   - swarm-dispatch:     stdout contract (panes + windows), error surfacing
#   - swarm-cherry-pick:  happy path, no-op (no commits ahead), no-arg-from-worktree,
#                         multi-commit with mixed empty+new (Codex Finding A regression),
#                         all-empty re-fold (Finding 4 regression),
#                         no-arg from worktree triggering empty path (Codex Finding B regression),
#                         real conflict still stops with hint
#   - swarm-apply:        tracked + untracked staging (Finding 3 regression)
#   - swarm-fold-cleanup: branch + worktree + idempotent re-run + slashed-branch parent dir cleanup
#   - swarm-sweep:        list and --confirm filter; main worktree excluded
#   - SWARMY_WORKTREE_BASE: relative path resolves against repo root

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P)
PLUGIN_ROOT=$(cd "$SCRIPT_DIR/.." && pwd -P)
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"

VERBOSE=0
FILTERS=()
for arg in "$@"; do
    case "$arg" in
        -v|--verbose) VERBOSE=1 ;;
        -h|--help)
            sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        -*) echo "unknown flag: $arg" >&2; exit 2 ;;
        *) FILTERS+=("$arg") ;;
    esac
done

WORK=$(mktemp -d -t swarm-tests.XXXXXX)
SANDBOX="$WORK/sandbox"
TMUX_SOCK="swarm-tests-$$"

if [ -t 1 ]; then
    G=$'\033[0;32m'; R=$'\033[0;31m'; Y=$'\033[0;33m'; B=$'\033[0;36m'; N=$'\033[0m'
else
    G=''; R=''; Y=''; B=''; N=''
fi

PASS=0; FAIL=0; SKIP=0
FAILED_NAMES=()

cleanup() {
    tmux -L "$TMUX_SOCK" kill-server 2>/dev/null || true
    rm -rf "$WORK"
}
trap cleanup EXIT

CURRENT=""

log()   { [ "$VERBOSE" -eq 1 ] && printf '    %s\n' "$1" || true; }
pass()  { PASS=$((PASS+1)); printf '  %s[PASS]%s %s\n' "$G" "$N" "$CURRENT"; }
fail()  { FAIL=$((FAIL+1)); FAILED_NAMES+=("$CURRENT"); printf '  %s[FAIL]%s %s\n' "$R" "$N" "$CURRENT"; [ -n "${1:-}" ] && printf '         %s\n' "$1"; }
skip()  { SKIP=$((SKIP+1)); printf '  %s[SKIP]%s %s — %s\n' "$Y" "$N" "$CURRENT" "$1"; }

# Run a test if it matches the filter list (or no filter given).
matches_filter() {
    local name=$1
    [ "${#FILTERS[@]}" -eq 0 ] && return 0
    for f in "${FILTERS[@]}"; do
        case "$name" in *"$f"*) return 0 ;; esac
    done
    return 1
}

# Reset the sandbox to a clean two-commit repo. Also wipes any sibling
# chunk worktrees from previous tests (left at $WORK/sandbox--*) so each
# test starts from a known-clean filesystem state.
reset_sandbox() {
    rm -rf "$SANDBOX"
    # Sibling chunk worktrees and slashed-branch parent dirs.
    find "$WORK" -mindepth 1 -maxdepth 1 -name 'sandbox--*' -exec rm -rf {} + 2>/dev/null || true
    mkdir -p "$SANDBOX"
    (
        cd "$SANDBOX"
        git init -q -b main
        git config user.email test@test.local
        git config user.name "Swarm Tester"
        git config commit.gpgsign false
        echo "# repo" > README.md
        git add README.md
        git commit -q -m "initial"
        echo "scaffold" > scaffold.txt
        git add scaffold.txt
        git commit -q -m "scaffold"
    )
}

# Make a worktree at the standard path with one committed change.
make_chunk_with_one_commit() {
    local branch=$1 file=$2 content=${3:-content}
    local wt="$WORK/sandbox--$branch"
    git -C "$SANDBOX" worktree add -b "$branch" "$wt" >/dev/null 2>&1
    (
        cd "$wt"
        echo "$content" > "$file"
        git add "$file"
        git commit -q -m "$branch: add $file"
    )
}

# Spawn a private tmux server (separate socket, default-shell bash so
# send-keys lines are bash syntax not the user's fish/zsh).
start_private_tmux() {
    tmux -L "$TMUX_SOCK" set-option -g default-shell /bin/bash 2>/dev/null || true
    tmux -L "$TMUX_SOCK" new-session -d -s test -x 200 -y 50 /bin/bash 2>/dev/null || true
}

# Run a command in the private tmux test session and capture its output
# to a file. Blocks (with timeout) until the marker file appears.
tmux_run() {
    local cmd=$1 outfile=$2 marker=$3 timeout=${4:-10}
    : > "$outfile"
    rm -f "$marker"
    tmux -L "$TMUX_SOCK" send-keys -t test "{ $cmd; } > $outfile 2>&1; touch $marker" C-m
    local i=0
    while [ ! -e "$marker" ] && [ $i -lt $((timeout * 10)) ]; do
        i=$((i + 1))
        sleep 0.1
    done
    [ -e "$marker" ]
}

# ------------------------------------------------------------------
# Tests
# ------------------------------------------------------------------

run() {
    local name=$1 fn=$2
    matches_filter "$name" || return 0
    CURRENT="$name"
    if ! "$fn"; then
        fail "test function returned non-zero before asserting"
    fi
    CURRENT=""
}

t_doctor_passes_under_normal_conditions() {
    if [ -z "${TMUX:-}" ]; then
        skip "this harness's outer shell isn't in tmux; doctor's \$TMUX check would fail"
        return 0
    fi
    reset_sandbox
    if (cd "$SANDBOX" && bash "$PLUGIN_ROOT/scripts/swarm-doctor" >/dev/null); then
        pass
    else
        fail "doctor exited non-zero in a healthy environment"
    fi
}

t_dispatch_stdout_contract_panes() {
    reset_sandbox
    start_private_tmux
    local out="$WORK/dispatch-panes.out" marker="$WORK/dispatch-panes.done"
    tmux_run "cd $SANDBOX && bash $PLUGIN_ROOT/scripts/swarm-dispatch foo bar" "$out" "$marker" 10 \
        || { fail "tmux command did not finish in time"; return 0; }
    local lines
    lines=$(grep -c '^[%@][0-9]\+ /' "$out" || true)
    if [ "$lines" -ne 2 ]; then
        fail "expected 2 lines matching '<pane_id> <abs_path>', got $lines:"
        log "$(cat "$out")"
    elif ! grep -q "sandbox--foo" "$out" || ! grep -q "sandbox--bar" "$out"; then
        fail "missing expected worktree paths"
        log "$(cat "$out")"
    else
        pass
    fi
    bash "$PLUGIN_ROOT/scripts/swarm-fold-cleanup" foo >/dev/null 2>&1 || true
    bash "$PLUGIN_ROOT/scripts/swarm-fold-cleanup" bar >/dev/null 2>&1 || true
    cd "$SANDBOX"
}

t_dispatch_stdout_contract_windows() {
    reset_sandbox
    start_private_tmux
    local out="$WORK/dispatch-windows.out" marker="$WORK/dispatch-windows.done"
    tmux_run "cd $SANDBOX && bash $PLUGIN_ROOT/scripts/swarm-dispatch --mode windows w1 w2" "$out" "$marker" 10 \
        || { fail "tmux command did not finish in time"; return 0; }
    local lines
    lines=$(grep -c '^[%@][0-9]\+ /' "$out" || true)
    if [ "$lines" -ne 2 ]; then
        fail "expected 2 lines, got $lines"
        log "$(cat "$out")"
    else
        pass
    fi
    bash "$PLUGIN_ROOT/scripts/swarm-fold-cleanup" w1 >/dev/null 2>&1 || true
    bash "$PLUGIN_ROOT/scripts/swarm-fold-cleanup" w2 >/dev/null 2>&1 || true
    cd "$SANDBOX"
}

t_dispatch_surfaces_git_diagnostic_on_failure() {
    reset_sandbox
    # Create a registered-but-missing worktree to force a fallback failure.
    git -C "$SANDBOX" worktree add -b stuck "$WORK/sandbox--stuck" >/dev/null 2>&1
    rm -rf "$WORK/sandbox--stuck"  # registered, but dir gone
    start_private_tmux
    local out="$WORK/dispatch-err.out" marker="$WORK/dispatch-err.done"
    tmux_run "cd $SANDBOX && bash $PLUGIN_ROOT/scripts/swarm-dispatch stuck; echo RC=\$?" "$out" "$marker" 10 \
        || { fail "tmux command did not finish in time"; return 0; }
    if grep -q 'failed to create worktree' "$out" \
            && grep -q 'git: ' "$out" \
            && grep -q 'missing but already registered' "$out" \
            && grep -q 'RC=1' "$out"; then
        pass
    else
        fail "expected 'failed' + 'git:' prefix + git's diagnostic + RC=1; got:"
        log "$(cat "$out")"
    fi
}

t_cherry_pick_happy_path() {
    reset_sandbox
    make_chunk_with_one_commit chunk-a a.txt "from chunk-a"
    if (cd "$SANDBOX" && bash "$PLUGIN_ROOT/scripts/swarm-cherry-pick" chunk-a >/dev/null) \
            && [ -f "$SANDBOX/a.txt" ]; then
        pass
    else
        fail "expected a.txt on main"
    fi
}

t_cherry_pick_no_commits_ahead() {
    reset_sandbox
    git -C "$SANDBOX" worktree add -b idle "$WORK/sandbox--idle" >/dev/null 2>&1
    local out
    out=$(cd "$SANDBOX" && bash "$PLUGIN_ROOT/scripts/swarm-cherry-pick" idle 2>&1) || true
    if echo "$out" | grep -q "no commits on 'idle' ahead of 'main'"; then
        pass
    else
        fail "expected 'no commits ahead' hint; got: $out"
    fi
}

t_cherry_pick_all_empty_skips_cleanly() {
    # Re-fold scenario: chunk's commits are patch-equivalent to commits
    # already on main. Should --skip them all and exit 0 with a clear
    # message. Working tree must be clean afterwards (no CHERRY_PICK_HEAD).
    reset_sandbox
    # Build divergent main and chunk-a where they each commit identical content.
    git -C "$SANDBOX" worktree add -b chunk-a "$WORK/sandbox--chunk-a" HEAD >/dev/null 2>&1
    (cd "$WORK/sandbox--chunk-a" && echo "from chunk-a" > a.txt && git add a.txt && git commit -q -m "chunk-a: add a.txt")
    (cd "$SANDBOX" && echo "main extra" > m.txt && git add m.txt && git commit -q -m "main: extra")
    # Apply the same content to main with a different SHA.
    (cd "$SANDBOX" && echo "from chunk-a" > a.txt && git add a.txt && git commit -q -m "main: also add a.txt")
    # Now chunk-a's commit will be empty when cherry-picked.
    local out rc
    out=$(cd "$SANDBOX" && bash "$PLUGIN_ROOT/scripts/swarm-cherry-pick" chunk-a 2>&1) && rc=0 || rc=$?
    if [ "$rc" -ne 0 ]; then
        fail "expected rc=0, got rc=$rc"; log "$out"; return 0
    fi
    if ! echo "$out" | grep -q "are already on 'main'"; then
        fail "expected 'already on main' message; got: $out"; return 0
    fi
    if [ -e "$SANDBOX/.git/CHERRY_PICK_HEAD" ]; then
        fail "CHERRY_PICK_HEAD still set after empty cherry-pick"; return 0
    fi
    if [ -n "$(git -C "$SANDBOX" status --porcelain)" ]; then
        fail "working tree dirty after empty cherry-pick"; return 0
    fi
    pass
}

t_cherry_pick_mixed_empty_and_new() {
    # Codex Finding A regression: chunk has [A_dup, B_new]. A is patch-equivalent
    # to a commit already on main; B is new. The script must apply B (not silently
    # drop it after aborting on A's empty cherry-pick).
    reset_sandbox
    # main: scaffold, then add a.txt
    (cd "$SANDBOX" && echo "from chunk-a" > a.txt && git add a.txt && git commit -q -m "main: add a.txt")
    # chunk-a (off scaffold): same a.txt content (will be empty), then a brand-new b.txt.
    git -C "$SANDBOX" worktree add -b chunk-a "$WORK/sandbox--chunk-a" HEAD~1 >/dev/null 2>&1
    (cd "$WORK/sandbox--chunk-a"
        echo "from chunk-a" > a.txt && git add a.txt && git commit -q -m "chunk-a: add a.txt"
        echo "new b" > b.txt && git add b.txt && git commit -q -m "chunk-a: add b.txt")
    local out rc
    out=$(cd "$SANDBOX" && bash "$PLUGIN_ROOT/scripts/swarm-cherry-pick" chunk-a 2>&1) && rc=0 || rc=$?
    if [ "$rc" -ne 0 ]; then
        fail "expected rc=0, got rc=$rc"; log "$out"; return 0
    fi
    if [ ! -f "$SANDBOX/b.txt" ]; then
        fail "b.txt was NOT applied to main — empty-handling dropped a real commit"
        log "out: $out"
        return 0
    fi
    if [ -e "$SANDBOX/.git/CHERRY_PICK_HEAD" ]; then
        fail "CHERRY_PICK_HEAD still set after mixed cherry-pick"; return 0
    fi
    pass
}

t_cherry_pick_no_arg_from_chunk_worktree() {
    # Codex Finding B regression: invoking without an arg from a chunk worktree
    # must still detect the main worktree's CHERRY_PICK_HEAD correctly when a
    # cherry-pick goes empty. If the path resolution were CWD-relative, the
    # empty-detection would miss and we'd hit the "stopped" branch.
    reset_sandbox
    # Same setup as the all-empty test, but call with no args from inside the chunk worktree.
    git -C "$SANDBOX" worktree add -b chunk-a "$WORK/sandbox--chunk-a" HEAD >/dev/null 2>&1
    (cd "$WORK/sandbox--chunk-a" && echo "from chunk-a" > a.txt && git add a.txt && git commit -q -m "chunk-a: add a.txt")
    (cd "$SANDBOX" && echo "from chunk-a" > a.txt && git add a.txt && git commit -q -m "main: also add a.txt")
    local out rc
    out=$(cd "$WORK/sandbox--chunk-a" && bash "$PLUGIN_ROOT/scripts/swarm-cherry-pick" 2>&1) && rc=0 || rc=$?
    if [ "$rc" -ne 0 ]; then
        fail "expected rc=0, got rc=$rc"; log "$out"; return 0
    fi
    if ! echo "$out" | grep -q "are already on 'main'"; then
        fail "expected 'already on main' message; got: $out"; return 0
    fi
    if [ -e "$SANDBOX/.git/CHERRY_PICK_HEAD" ]; then
        fail "CHERRY_PICK_HEAD still set in main worktree"; return 0
    fi
    pass
}

t_cherry_pick_real_conflict_stops_with_hint() {
    reset_sandbox
    git -C "$SANDBOX" worktree add -b chunk "$WORK/sandbox--chunk" HEAD >/dev/null 2>&1
    (cd "$WORK/sandbox--chunk" && echo "from chunk" > scaffold.txt && git add scaffold.txt && git commit -q -m "chunk: change scaffold")
    (cd "$SANDBOX"             && echo "from main"  > scaffold.txt && git add scaffold.txt && git commit -q -m "main: change scaffold")
    local out rc
    out=$(cd "$SANDBOX" && bash "$PLUGIN_ROOT/scripts/swarm-cherry-pick" chunk 2>&1) && rc=0 || rc=$?
    if [ "$rc" -eq 0 ]; then
        fail "expected non-zero exit, got 0"; log "$out"; return 0
    fi
    if ! echo "$out" | grep -q "cherry-pick stopped"; then
        fail "missing 'cherry-pick stopped' hint; got: $out"; return 0
    fi
    if [ ! -e "$SANDBOX/.git/CHERRY_PICK_HEAD" ]; then
        fail "CHERRY_PICK_HEAD missing — should be left for the user"; return 0
    fi
    if ! git -C "$SANDBOX" status --porcelain | grep -q "^UU"; then
        fail "expected UU markers in porcelain"; return 0
    fi
    git -C "$SANDBOX" cherry-pick --abort >/dev/null 2>&1 || true
    pass
}

t_apply_stages_tracked_and_untracked() {
    # Finding 3 regression: untracked files copied by swarm-apply must be staged.
    reset_sandbox
    git -C "$SANDBOX" worktree add -b apply-test "$WORK/sandbox--apply-test" >/dev/null 2>&1
    (cd "$WORK/sandbox--apply-test"
        echo "modified" >> README.md       # tracked diff
        echo "new" > new.txt               # untracked, top-level
        mkdir -p sub/dir
        echo "deep" > sub/dir/deep.txt)    # untracked, nested
    if ! (cd "$SANDBOX" && bash "$PLUGIN_ROOT/scripts/swarm-apply" apply-test >/dev/null); then
        fail "swarm-apply exited non-zero"; return 0
    fi
    local porcelain
    porcelain=$(git -C "$SANDBOX" status --porcelain)
    # All three changes must be staged (no leading '??').
    if echo "$porcelain" | grep -q '^??'; then
        fail "found unstaged ('??') entries after swarm-apply:"; log "$porcelain"; return 0
    fi
    if ! echo "$porcelain" | grep -q '^M  README.md'; then
        fail "README.md modification not staged"; log "$porcelain"; return 0
    fi
    if ! echo "$porcelain" | grep -q '^A  new.txt'; then
        fail "untracked new.txt not staged"; log "$porcelain"; return 0
    fi
    if ! echo "$porcelain" | grep -q '^A  sub/dir/deep.txt'; then
        fail "nested untracked file not staged"; log "$porcelain"; return 0
    fi
    pass
}

t_fold_cleanup_slashed_branch_clears_parent_dir() {
    reset_sandbox
    git -C "$SANDBOX" worktree add -b "swarm/wave-2-deep" "$WORK/sandbox--swarm/wave-2-deep" >/dev/null 2>&1
    [ -d "$WORK/sandbox--swarm" ] || { fail "expected nested parent dir to exist after add"; return 0; }
    if ! (cd "$SANDBOX" && bash "$PLUGIN_ROOT/scripts/swarm-fold-cleanup" "swarm/wave-2-deep" >/dev/null); then
        fail "fold-cleanup returned non-zero"; return 0
    fi
    if [ -d "$WORK/sandbox--swarm" ]; then
        fail "empty parent dir <repo>--swarm/ not cleaned up"; return 0
    fi
    if git -C "$SANDBOX" rev-parse --verify "swarm/wave-2-deep" >/dev/null 2>&1; then
        fail "branch not deleted"; return 0
    fi
    pass
}

t_fold_cleanup_idempotent() {
    reset_sandbox
    git -C "$SANDBOX" worktree add -b once "$WORK/sandbox--once" >/dev/null 2>&1
    (cd "$SANDBOX" && bash "$PLUGIN_ROOT/scripts/swarm-fold-cleanup" once >/dev/null)
    if (cd "$SANDBOX" && bash "$PLUGIN_ROOT/scripts/swarm-fold-cleanup" once >/dev/null); then
        pass
    else
        fail "second invocation returned non-zero"
    fi
}

t_sweep_lists_and_confirms() {
    reset_sandbox
    git -C "$SANDBOX" worktree add -b a "$WORK/sandbox--a" >/dev/null 2>&1
    git -C "$SANDBOX" worktree add -b b "$WORK/sandbox--b" >/dev/null 2>&1
    local listed
    listed=$(cd "$SANDBOX" && bash "$PLUGIN_ROOT/scripts/swarm-sweep")
    # Two lines, one per chunk; main worktree excluded.
    local n
    n=$(echo "$listed" | grep -c "sandbox--" || true)
    if [ "$n" -ne 2 ]; then
        fail "expected 2 candidates, got $n: $listed"; return 0
    fi
    if echo "$listed" | grep -q "$SANDBOX$"; then
        fail "main worktree should not appear in sweep list"; return 0
    fi
    (cd "$SANDBOX" && bash "$PLUGIN_ROOT/scripts/swarm-sweep" --confirm >/dev/null)
    if [ -d "$WORK/sandbox--a" ] || [ -d "$WORK/sandbox--b" ]; then
        fail "worktree dirs still present after --confirm"; return 0
    fi
    pass
}

t_swarmy_worktree_base_relative() {
    reset_sandbox
    export SWARMY_WORKTREE_BASE=".swarmy/worktrees"
    git -C "$SANDBOX" worktree add -b w "$SANDBOX/.swarmy/worktrees/sandbox--w" >/dev/null 2>&1
    (cd "$SANDBOX/.swarmy/worktrees/sandbox--w" && echo x > x.txt && git add x.txt && git commit -q -m "w: x")
    if ! (cd "$SANDBOX" && bash "$PLUGIN_ROOT/scripts/swarm-cherry-pick" w >/dev/null); then
        fail "cherry-pick under SWARMY_WORKTREE_BASE failed"; unset SWARMY_WORKTREE_BASE; return 0
    fi
    local listed
    listed=$(cd "$SANDBOX" && bash "$PLUGIN_ROOT/scripts/swarm-sweep")
    if ! echo "$listed" | grep -q ".swarmy/worktrees/sandbox--w"; then
        fail "sweep didn't see worktree under SWARMY_WORKTREE_BASE: $listed"
        unset SWARMY_WORKTREE_BASE
        return 0
    fi
    (cd "$SANDBOX" && bash "$PLUGIN_ROOT/scripts/swarm-sweep" --confirm >/dev/null)
    unset SWARMY_WORKTREE_BASE
    pass
}

# ------------------------------------------------------------------
# Driver
# ------------------------------------------------------------------

printf '%sswarm tests — sandbox: %s%s\n\n' "$B" "$WORK" "$N"

run "doctor"                 t_doctor_passes_under_normal_conditions
run "dispatch-stdout-panes"  t_dispatch_stdout_contract_panes
run "dispatch-stdout-windows" t_dispatch_stdout_contract_windows
run "dispatch-error-surface" t_dispatch_surfaces_git_diagnostic_on_failure
run "cherry-happy"           t_cherry_pick_happy_path
run "cherry-no-op"           t_cherry_pick_no_commits_ahead
run "cherry-all-empty"       t_cherry_pick_all_empty_skips_cleanly
run "cherry-mixed"           t_cherry_pick_mixed_empty_and_new
run "cherry-no-arg-empty"    t_cherry_pick_no_arg_from_chunk_worktree
run "cherry-real-conflict"   t_cherry_pick_real_conflict_stops_with_hint
run "apply-staging"          t_apply_stages_tracked_and_untracked
run "fold-cleanup-slashed"   t_fold_cleanup_slashed_branch_clears_parent_dir
run "fold-cleanup-idempotent" t_fold_cleanup_idempotent
run "sweep"                  t_sweep_lists_and_confirms
run "worktree-base-relative" t_swarmy_worktree_base_relative

echo
total=$((PASS + FAIL + SKIP))
if [ "$FAIL" -eq 0 ]; then
    printf '%sAll %d/%d tests passed%s' "$G" "$PASS" "$total" "$N"
    [ "$SKIP" -gt 0 ] && printf ' (%d skipped)' "$SKIP"
    printf '\n'
    exit 0
else
    printf '%s%d failed, %d passed%s of %d total\n' "$R" "$FAIL" "$PASS" "$N" "$total"
    for n in "${FAILED_NAMES[@]}"; do
        printf '  - %s\n' "$n"
    done
    exit 1
fi
