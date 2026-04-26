# Rewrite the storage layer in three waves

## Context

The current storage layer is a single file (`storage.go`, ~1400 lines) that hardcodes Postgres calls into business logic. We want to split it into a small `Store` interface, a set of adapters (filesystem, in-memory, postgres, sqlite), and a migration path that lets us flip backends behind a feature flag without rewriting callers.

Three dependency-ordered waves: lock the interface (so adapters can be written in parallel), then write the adapters in parallel, then migrate the call sites once the adapters are real.

We're contributing this back upstream, so each wave gets its own PR. Reviewers see one self-contained change at a time.

## Scope

**In:**
- A `Store` interface in `internal/storage/store.go` with the operations we actually use today: `Get`, `Put`, `Delete`, `List`, `Tx`.
- Four adapters: `fs` (local files), `mem` (in-memory map for tests), `postgres` (the existing behavior, extracted), `sqlite` (new).
- A contract test suite that runs against any adapter — adapters are conformant if they pass it.
- Migration of every call site from direct Postgres to the `Store` interface, gated by a `STORAGE_BACKEND` env var.

**Out:**
- Removing the old `storage.go`. We keep it during the migration window; deletion is a follow-up after the flag is forced-on for two weeks.
- New storage features (TTLs, bulk ops, async writes). Behavior parity only.
- Performance work. We expect a small regression from the indirection; a separate spec covers tuning.
- Changing the on-disk Postgres schema.

## Design

The `Store` interface is the load-bearing contract; everything else hangs off it. We lock its signature in Wave 1's scaffold commit and never change it inside this spec — if Wave 2 or 3 reveals a missing method, that's a follow-up spec, not a mid-flight edit.

Adapters live in `internal/storage/{fs,mem,postgres,sqlite}/`. Each is a leaf package importing only the `Store` interface and its own backend driver. Adapters are constructed by a single registry in `internal/storage/registry.go` keyed on `STORAGE_BACKEND`.

Migration in Wave 3 is mechanical: replace direct `db.Query(...)` calls with `store.Get/Put/...`, lifting transactions through `Store.Tx`. Each call site gets its own commit so reverts are surgical.

## Verification

```
go build ./...
go test ./internal/storage/... -tags=contract
STORAGE_BACKEND=mem go test ./...
STORAGE_BACKEND=postgres go test ./...   # against the test container
STORAGE_BACKEND=sqlite go test ./...
```

All four backends must pass the contract suite. With `STORAGE_BACKEND=postgres` set, the full integration suite must pass with no behavior diff against trunk.

## Waves

### Wave 1 — foundation

**Scaffold (serial):**
- `internal/storage/store.go` — `Store` interface with finalized method set.
- `internal/storage/registry.go` — `New(backend string) (Store, error)` returning `ErrUnknownBackend` for any non-empty value (adapters register in Wave 2).
- `internal/storage/contract/contract.go` — table-driven test suite, exported as `RunContractTests(t *testing.T, factory func() Store)`. Empty body — Wave 2 fills it in.
- `internal/storage/errors.go` — sentinel errors (`ErrNotFound`, `ErrConflict`, `ErrUnknownBackend`).
- Commit: `scaffold: lock Store interface + registry + contract suite hook`.

**Locked interface contracts:**

```go
// store.go
type Store interface {
    Get(ctx context.Context, key string) ([]byte, error)
    Put(ctx context.Context, key string, value []byte) error
    Delete(ctx context.Context, key string) error
    List(ctx context.Context, prefix string) ([]string, error)
    Tx(ctx context.Context, fn func(Store) error) error
}

// registry.go
func New(backend string) (Store, error)
func Register(name string, factory func() (Store, error))

// contract/contract.go
func RunContractTests(t *testing.T, factory func() Store)
```

**Chunks:**

| Branch | Scope | Done-when |
|---|---|---|
| `storage-interface` | Define `Store`, the registry, sentinel errors. Write doc comments on every interface method describing the exact semantics adapters must honor (key constraints, error mapping, Tx isolation expected). | `go build ./internal/storage/...` succeeds; `go vet ./internal/storage/...` clean; `go doc internal/storage` reads cleanly. |
| `storage-contract-suite` | Implement `RunContractTests` — table of cases covering get-after-put, get-missing, list-by-prefix, delete-then-get, Tx-commit, Tx-rollback, error-classification. No adapter exists yet; suite gets exercised in Wave 2. | `go test ./internal/storage/contract/...` (vacuous pass, no factory registered yet); test cases reviewed against the locked interface doc. |

**Intra-wave sequencing:** `storage-contract-suite` imports `Store` from `storage-interface`, but the scaffold commit already exports the interface, so both branches build independently from the scaffold and the contract suite only needs the interface to be present (which it is).

### Wave 2 — adapters

**Scaffold (serial, after Wave 1 lands):**
- `internal/storage/fs/fs.go`, `internal/storage/mem/mem.go`, `internal/storage/postgres/postgres.go`, `internal/storage/sqlite/sqlite.go` — empty package files, each with an `init()` that calls `storage.Register(...)` with a constructor returning `nil, errors.New("not implemented")`.
- `internal/storage/registry_test.go` — verifies all four names register.
- Commit: `scaffold: register fs/mem/postgres/sqlite adapter slots`.

**Locked interface contracts:** same as Wave 1; no new contracts here. Each adapter implements `Store`.

**Chunks:**

| Branch | Scope | Done-when |
|---|---|---|
| `fs-adapter` | Implement the filesystem adapter. Keys map to file paths under a configured root; values to file contents. `Tx` uses a directory-level lockfile. | `STORAGE_BACKEND=fs go test ./internal/storage/contract/...` passes. |
| `mem-adapter` | Implement the in-memory adapter. `map[string][]byte` behind a sync.RWMutex. `Tx` snapshots the map and swaps on commit. | `STORAGE_BACKEND=mem go test ./internal/storage/contract/...` passes. |
| `postgres-adapter` | Lift the existing Postgres calls out of `storage.go` into the adapter, mapping each method to the existing query. `Tx` uses `BEGIN`/`COMMIT`/`ROLLBACK`. | `STORAGE_BACKEND=postgres go test ./internal/storage/contract/...` passes against the test container. |
| `sqlite-adapter` | New adapter using `mattn/go-sqlite3`. Schema migration in `init()`. `Tx` via SQLite transactions. | `STORAGE_BACKEND=sqlite go test ./internal/storage/contract/...` passes. |

**Intra-wave sequencing:** none. Four leaves, four packages, zero shared files. The contract suite from Wave 1 is the conformance gate; each chunk is done when its backend passes the suite.

### Wave 3 — migration

**Scaffold (serial, after Wave 2 lands):**
- `internal/storage/factory.go` — production wiring that reads `STORAGE_BACKEND` (default: `postgres`) and calls `storage.New(...)` once at startup.
- Plumb a `Store` field through the top-level `App` struct in `cmd/server/app.go` so call sites have something to pull from.
- Commit: `scaffold: wire Store factory into App struct`.

**Locked interface contracts:** the `App.Store` field becomes the load-bearing handle. Each call site receives `app.Store` and stops touching the old `storage.go` directly.

**Chunks:**

| Branch | Scope | Done-when |
|---|---|---|
| `migrate-users` | Replace direct DB calls in `internal/users/...` with `app.Store` calls. Preserve all existing tests. | `go test ./internal/users/...` passes; `STORAGE_BACKEND=mem go test ./internal/users/...` also passes. |
| `migrate-billing` | Same, for `internal/billing/...`. Tx semantics matter here — billing flows that span multiple writes use `Store.Tx`. | `go test ./internal/billing/...` passes under both `postgres` and `mem` backends. |
| `migrate-jobs` | Same, for `internal/jobs/...`. The job queue uses `List` + `Delete` heavily; verify ordering against the contract suite's documented guarantees. | `go test ./internal/jobs/...` passes under both backends. |

**Intra-wave sequencing:** none — three independent subsystems, three leaf branches. The old `storage.go` stays in place during the migration; deleting it is a separate cleanup after the flag has been forced on in production for two weeks.

## Execution

```
Spec format: 1
Delivery mode: fork-pr
PR unit: wave
Base strategy: upstream-trunk
Branch naming: swarm/{slug}-wave-{n}
Fork remote: origin
Upstream remote: upstream
```

---

_Wave 1 executed 2026-04-01 on branch swarm/storage-rewrite-wave-1; chunks storage-interface, storage-contract-suite; PR https://github.com/example/foo/pull/123_

_Wave 2 executed 2026-04-08 on branch swarm/storage-rewrite-wave-2; chunks fs-adapter, mem-adapter, postgres-adapter, sqlite-adapter; PR not pushed_
