# Add /healthz endpoint with logging middleware

## Context

The web service currently has no liveness probe and no structured request logging. Operators are flying blind: a stuck process looks identical to a healthy one from the outside, and we have no per-request audit trail. We want a minimal, well-tested first cut: one endpoint, one middleware, one contract test that pins their interaction.

This is a single-wave task — the three pieces are independent enough to fan out, but trivial enough that one wave covers everything.

## Scope

**In:**
- A `GET /healthz` endpoint that returns `200 OK` with body `{"status":"ok"}` when the service is up.
- A logging middleware that emits one structured log line per request (method, path, status, duration_ms, request_id).
- A contract test that hits `/healthz` through the middleware and asserts both the response body and the log shape.

**Out:**
- Deep health (DB pings, dependency checks). `/healthz` is liveness only; readiness is a separate spec.
- Log shipping / aggregation config. We just emit to stdout in JSON.
- Tracing, metrics, alerting. Logging only.
- Auth on `/healthz`. It's intentionally unauthenticated.

## Design

Three independent files, one shared interface (the middleware's log-line struct), locked in the scaffold:

- `internal/health/healthz.go` — handler. Imports nothing project-internal except the router registration helper.
- `internal/middleware/logging.go` — net/http middleware wrapping any `http.Handler`. Emits via the shared `LogLine` struct.
- `internal/contract/healthz_test.go` — spins up a test server with the real middleware wrapping the real handler, hits `/healthz`, asserts body and parses the captured log line.

The scaffold commit lands the `LogLine` struct definition and an empty `RegisterRoutes(*http.ServeMux)` hook so all three chunks can compile against a stable contract before any of them is implemented.

## Verification

End-to-end smoke after fold-back:

```
go build ./...
go test ./internal/contract/...
curl -s localhost:8080/healthz
# expect: {"status":"ok"}
# server stdout shows one JSON line: {"method":"GET","path":"/healthz","status":200,...}
```

If the contract test passes and the curl shows both the response and the log line, the wave is done.

## Waves

### Wave 1 — endpoint, middleware, contract test (parallel)

**Scaffold (serial, in this session before dispatch):**
- `internal/health/healthz.go` — empty file with package decl.
- `internal/middleware/logging.go` — empty file with package decl + `LogLine` struct.
- `internal/contract/healthz_test.go` — empty file with package decl.
- `cmd/server/routes.go` — `RegisterRoutes(mux *http.ServeMux)` stub that returns immediately.
- Commit: `scaffold: lock LogLine struct + RegisterRoutes signature for healthz wave`.

**Locked interface contracts:**

```go
// middleware/logging.go
type LogLine struct {
    Method     string `json:"method"`
    Path       string `json:"path"`
    Status     int    `json:"status"`
    DurationMs int64  `json:"duration_ms"`
    RequestID  string `json:"request_id"`
}
```

```go
// cmd/server/routes.go
func RegisterRoutes(mux *http.ServeMux)
```

**Chunks:**

| Branch | Scope | Done-when |
|---|---|---|
| `healthz-handler` | Implement `GET /healthz` handler in `internal/health/`. Register it from `RegisterRoutes`. Returns `{"status":"ok"}` with `Content-Type: application/json`. | `go test ./internal/health/...` passes; `curl localhost:8080/healthz` returns `{"status":"ok"}`. |
| `logging-middleware` | Implement the middleware in `internal/middleware/logging.go`. Wraps any `http.Handler`, captures status via `httptest.ResponseRecorder`-style wrapper, emits `LogLine` as JSON to stdout. | `go test ./internal/middleware/...` passes; manual sanity: middleware around a no-op handler logs one line per request. |
| `healthz-contract-test` | Write the contract test in `internal/contract/healthz_test.go`. Spins up a test server (real middleware + real handler), hits `/healthz`, asserts response body equals expected JSON, captures stdout, asserts a parsed `LogLine` with `Status: 200, Path: "/healthz"`. | `go test ./internal/contract/...` passes against the real handler + real middleware (no mocks). |

**Intra-wave sequencing:** none. All three branch off the scaffold commit and can run fully in parallel. The contract test imports both `health` and `middleware` packages, but those packages already exist (as stubs) after the scaffold commit, so it compiles immediately and the test only starts passing once the other two chunks land.

## Execution

```
Spec format: 1
Delivery mode: solo-local
PR unit: wave
Base strategy: upstream-trunk
Branch naming: swarm/{slug}-wave-{n}
```
