# ADR 0001 — Rewrite Flight as a Bun/Elysia service; decouple the frontend; drop Scribe for direct Postgres

- **Status:** Accepted
- **Date:** 2026-07-02
- **Deciders:** Vasilen (+ Claude as reviewer)
- **Supersedes:** the Node/Koa Flight + HTTP-Scribe two-tier design

---

## 1. Context

The current stack is two independently-deployed servers:

- **Flight** — Node + Koa, business-logic/edge tier. Clusters one worker per CPU, auto-discovers `**/*.backend.ts`, and also owns the frontend (spawns Vite in dev, serves `dist` in prod).
- **Scribe** — Node + Express, data tier. Turns JSON-Schema components into Postgres tables on the fly, exposes CRUD + history + a raw `/sql` passthrough, reachable **only over HTTP**.

A review of both codebases (see [../../README.md §5](../../README.md)) surfaced problems that are not incidental bugs but consequences of the architecture:

1. **The HTTP boundary between logic and data destroys transactions.** Every Scribe call is its own connection and its own `BEGIN…COMMIT`. A parent+children insert is N independent transactions, so *every* multi-step operation is forced into a saga with hand-rolled compensation. Scribe doesn't even wrap its own 4-statement `createSingle` in a transaction.
2. **Latency tax.** Serialize → HTTP/1.1 → RTT → deserialize on every data access, even over localhost.
3. **Saga/rollback complexity** across multiple Flight pods, with no durable saga state.
4. **Node/Koa runtime limits.** Single-thread-per-process; `cluster` is the only way to use cores; `os.cpus()` ignores cgroup CPU quotas (over-forks in containers); CPU work (compression, `diff-match-patch`) blocks the event loop; GC tail latency.
5. **Scribe is a weaker reimplementation of solved problems** — migrations, edge validation, query builders, temporal/audit history, PostgREST — each of which is better off-the-shelf.
6. **Frontend and backend are coupled** in one deployable despite having different scaling, caching, and deploy-cadence needs.

The transaction loss, the latency tax, and the saga explosion are **the same root cause**: the HTTP boundary. Collapsing that boundary and moving the transaction into the process that owns the database removes all three by construction.

## 2. Decision

Replace the two-server stack with:

- **A single sound, typed API service on Bun**, using **Elysia + TypeBox** — one schema definition yields runtime validation, static TS types, and JSON Schema simultaneously (the genuinely good idea in Scribe, done correctly).
- **Direct Postgres access via PgCat** (pooling + read/write split), with **real in-process transactions**. The saga tax disappears for all intra-database work.
- **A decoupled frontend** — its own build, deployed static to a CDN, with an end-to-end **type-safe contract via Elysia Eden** (no codegen step).
- **Scribe removed as a service.** Its responsibilities are re-homed: schema → migrations; validation → TypeBox at the edge; CRUD/relationships → a thin query layer; history → audit triggers / temporal tables *if* it remains a requirement.
- **nginx/CDN at the edge** for TLS, static assets, and compression — kept off the runtime.

### Target stack

| Concern | Choice | Notes |
| --- | --- | --- |
| Runtime | **Bun** | Native TS execution, fast I/O, built-in tooling. |
| HTTP + validation | **Elysia + TypeBox** | Validation + static types + JSON Schema from one def; **Eden** typed client for the frontend. |
| DB access | **postgres.js** (or `Bun.sql`) | Real transactions via `sql.begin()`. |
| Pool / routing | **PgCat** | Pooling, read/write split across replicas, graceful prepared-statement handling. |
| Migrations | drizzle-kit or plain SQL + runner | Versioned, reviewable schema — replaces Scribe's DDL-on-write. |
| Sessions / rate-limit | **Redis** | Kept from Flight; correct for multi-process. |
| Edge | **nginx / CDN** | TLS, static, compression off the runtime. |
| Typecheck | **tsc / tsgo in CI** | Bun strips types; soundness is enforced in CI, not at runtime. |

## 3. Alternatives considered

| Option | Why not (now) |
| --- | --- |
| **Harden Node/Koa Flight in place** | Fixes worker-sizing, backoff, static/compression offload — but leaves the HTTP-boundary transaction loss and the Scribe redundancy untouched. Treats symptoms. |
| **Rust (axum + sqlx)** | Best ceiling: one process saturates all cores, no GC tail latency, max density, compile-checked SQL. Rejected *for now* because the team + frontend are TS and we want end-to-end type sharing and velocity. **Reserved** for if p999/no-GC latency or density become hard, numeric requirements. |
| **Go (chi/echo + sqlc)** | ~85% of Rust's runtime benefit at higher velocity, but weaker type system and still leaves the TS type-sharing win on the table. Not chosen given the TS-everywhere advantage. |
| **Keep Scribe, add a `/tx` batch endpoint + keep-alive + gRPC** | Mitigates the boundary but keeps a distributed system we don't need. Only justified if a **non-Node** client must hit the data tier — no such requirement exists. |
| **PgBouncer (session mode)** instead of PgCat | Simpler, but no read/write split and less graceful prepared-statement handling. PgCat chosen for replica routing headroom. |
| **PostgREST / Supabase / Hasura** | The mature versions of "auto-API over Postgres." Viable if the product goal is that DX — but we want business logic in code, so a typed service fits better. Revisit only if a polyglot auto-API becomes a requirement. |

## 4. Consequences

**Positive**
- Multi-entity operations become atomic again (in-process transactions) — saga complexity confined to genuine cross-service flows.
- One language end-to-end; frontend and backend share types with no codegen.
- The HTTP data hop, in-process compression, static-on-event-loop, and per-worker Vite build all cease to exist.
- Schema is versioned and reviewable; validation lives at the boundary with static types.

**Negative / costs**
- A rewrite, not a port. Flight's auto-mount component-colocation DX is intentionally abandoned (it was the source of the coupling). Routes become explicit.
- Still **GC + multiprocess-for-cores** — Bun does not give Rust's no-GC, single-process-multicore profile. Cores need multiple Bun processes (`reusePort`) with Redis-shared state, and the container CPU-sizing discipline still applies.
- **Bun maturity** — Node-compat is strong but not 100%; less battle-tested at extreme scale.

**Caveats to honor**
- Bun executes TS but does **not** typecheck it → `tsc`/`tsgo` gate in CI is mandatory.
- **PgCat + prepared statements**: confirm statement handling for our pooling mode before finalizing the pool config; pick transaction vs session pooling deliberately.
- Multi-process means no in-memory state: sessions, rate-limit, cache stay in Redis.
- If **history/time-machine** stays a feature, implement it with audit triggers / temporal tables — not `diff-match-patch` on JSON.

## 5. Migration path (strangler, off the current Node stack)

**Phase 0 — Foundation**
- Harness infra: swap Caddy → **nginx** at the edge, add **PgCat** + Postgres + Redis to the compose stack.
- Stand up the Bun service skeleton: Elysia + TypeBox + postgres.js, CI running `bun test` + `tsc`/`tsgo` typecheck.

**Phase 1 — Schema as migrations**
- Define the entities that Scribe currently materializes implicitly as real **migrations** (typed columns, constraints, indexes) — starting with `students`. No more DDL-on-write.

**Phase 2 — First vertical slice end-to-end**
- Port **students** fully into the Bun service: TypeBox schema → Elysia route → validation → `sql.begin()` transaction via PgCat → typed response → **Eden** client.
- Repoint the existing React/shadcn `student-app` frontend at the new service via the Eden client (drops the Flight proxy + the jsonb-column workaround; uses real typed columns).

**Phase 3 — Strangle**
- Move remaining entities/endpoints off Scribe one vertical at a time. Run new and old in parallel behind nginx (new `/api/*` → Bun service; legacy → old Flight) until Scribe sees no traffic.
- **Data:** existing rows already live in the same Postgres; migration is mostly reshaping Scribe's `data` jsonb into typed columns. Note: reconstructing history from the `diff-match-patch` patches is **lossy** — decide per-entity whether history is worth backfilling.

**Phase 4 — Decommission**
- Delete Scribe and the Node Flight. Replace `/sql` passthrough usage with real endpoints. Stand up trigger-based audit/history only where required.

## 6. Open follow-ups
- PgCat pooling mode (transaction vs session) + prepared-statement config.
- Migration tool: drizzle-kit vs plain SQL + runner.
- Is history/time-machine a real requirement? If so, audit-trigger design.
- AuthN/AuthZ ownership (Scribe had none) — the Bun service owns it: session (Redis) + edge validation + row-level checks.
- Multi-process model: `reusePort` process count derived from the container CPU **limit**, plus SIGTERM draining for zero-downtime deploys.
