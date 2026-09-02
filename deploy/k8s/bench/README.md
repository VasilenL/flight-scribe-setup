# Cross-runtime benchmark peers (opt-in — NOT auto-deployed)

`setup-k3s.sh` only applies the top-level `deploy/k8s/*.yaml`; this subdirectory is skipped
(same as `experiments/` and `monitoring/`). Apply these by hand.

Three peers, all speaking the **same contract** so they drop straight into `ab.sh`:

| Manifest | Stack | Image | Port |
|----------|-------|-------|------|
| `spring-notes.yaml` | Java — Spring Boot 4 + Hibernate, virtual threads | `spring-notes:local` | Service `:3000` → `:8080` |
| `fastapi-notes.yaml` | Python — FastAPI + asyncpg + uvicorn | `fastapi-notes:local` | Service `:3000` → `:8000` |
| `scribe-bun-ab.yaml` | Bun **Zig vs Rust** runtime A/B (two scribe-bun deploys) | `scribe-bun-{zig,rust}:local` | `:1337` |

The contract every peer implements:

```
POST /api/notes {title, body}  -> 201 {id, title, body, created_at}
GET  /api/notes                -> the most recent 100 rows
```

Service port **3000** is deliberate — `ab.sh` hits `http://<target>:3000`, so any deployment
that exposes this shape can be benchmarked with no change to the harness.

---

## The peers are handicapped on purpose

A naive Spring/FastAPI CRUD endpoint does **one** INSERT. scribe-bun does **two** — the row
plus a version-history row (`db.ts` `createSingle`). Left alone, the peers would be doing
half the database work and the comparison would be meaningless.

So both peers write to `bench_notes` **and** `bench_notes_history`, matching scribe's table
shape (same json column, same FK with `ON DELETE CASCADE`) and doing the second insert as a
raw parameterized statement — which is what scribe does too:

- Java: `NoteHistory.java`, raw `JdbcTemplate` + `CAST(? AS JSON)`
- Python: `main.py` `create()`, asyncpg + `$2::json`

Everything else is matched in the manifests: **8 cores** of CPU ceiling per stack and
**100 DB connections per pod** (FastAPI splits this as 4 workers × 25, because the GIL means
one worker saturates one core).

**What is deliberately NOT equalized:** the Bun stack routes through two pods
(`app-bun` → `scribe-bun`) where the peers are one. That hop is the architecture under
test — scribe is an independently-scalable data tier, not a library — so its cost belongs in
the number. See [`docs/scribe-topologies.md`](../../../docs/scribe-topologies.md).

The peers write `bench_notes*`; scribe writes `notes*`. Separate tables, so the two families
never interfere, and `truncate-notes.sh` resets whichever ones exist.

---

## Run them

```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# build + import (the import needs root; docker save must NOT be sudo'd)
docker build -t spring-notes:local  spring-notes
docker build -t fastapi-notes:local fastapi-notes
docker save spring-notes:local  | sudo k3s ctr images import -
docker save fastapi-notes:local | sudo k3s ctr images import -

kubectl apply -f deploy/k8s/bench/spring-notes.yaml
kubectl apply -f deploy/k8s/bench/fastapi-notes.yaml
kubectl -n flight-scribe rollout status deploy/spring-notes deploy/fastapi-notes

# same load, same duration, back to back
VUS=3000 DURATION=3m WARMUP=60s sh deploy/k8s/loadtest/ab.sh app-bun
VUS=3000 DURATION=3m WARMUP=60s sh deploy/k8s/loadtest/ab.sh spring-notes
VUS=3000 DURATION=3m WARMUP=60s sh deploy/k8s/loadtest/ab.sh fastapi-notes
```

**Use `WARMUP` on all three.** Java is the one that genuinely needs it — a cold JVM is still
interpreting bytecode, so an unwarmed run measures the JIT compiler. But warming only Java
invites the obvious objection, and identical treatment costs two minutes.

### Smoke test before trusting a run

Verifies the *second* insert actually lands — the failure mode that's silent under load:

```bash
kubectl -n flight-scribe run smoke --rm -i --restart=Never --image=curlimages/curl --command -- \
  curl -s -o /dev/null -w '%{http_code}\n' -X POST http://spring-notes:3000/api/notes \
  -H 'Content-Type: application/json' -d '{"title":"smoke","body":"test"}'

kubectl -n flight-scribe exec -i postgres-0 -- psql -U scribe -d scribe -c \
  "select 'bench_notes' as t, count(*) from bench_notes
   union all select 'bench_notes_history', count(*) from bench_notes_history;"
```

Expect `201`, and the two counts equal. A history count of `0` means the second insert is
failing silently — check `kubectl -n flight-scribe logs deploy/spring-notes`.

---

## Zig vs Rust (`scribe-bun-ab.yaml`)

Two identical scribe-bun deployments differing only in the Bun binary — 1.3.14 (the last Zig
build) vs latest (the Rust rewrite). Built from `deploy/scribe-bun-ab.Dockerfile`:

```bash
docker build --build-arg BUN_TAG=1.3.14 -f deploy/scribe-bun-ab.Dockerfile -t scribe-bun-zig:local  ../scribe-bun
docker build --build-arg BUN_TAG=latest  -f deploy/scribe-bun-ab.Dockerfile -t scribe-bun-rust:local ../scribe-bun
docker save scribe-bun-zig:local  | sudo k3s ctr images import -
docker save scribe-bun-rust:local | sudo k3s ctr images import -
kubectl apply -f deploy/k8s/bench/scribe-bun-ab.yaml

# A/B by swapping which data tier app-bun talks to
kubectl -n flight-scribe set env deploy/app-bun SCRIBE_BASE_URL=http://scribe-bun-zig:1337
kubectl -n flight-scribe rollout status deploy/app-bun
VUS=3000 DURATION=3m sh deploy/k8s/loadtest/ab.sh app-bun
# then repeat with scribe-bun-rust
```

Confirm you're actually testing what you think:
`kubectl -n flight-scribe exec deploy/scribe-bun-zig -- bun --version`

---

## Tear down

Back to the plain Bun stack, in one command:

```bash
NO_LOADTEST=1 NO_CONNTRACK=1 sh deploy/k8s/loadtest/bench-reset.sh
```

Removes every peer here plus the `experiments/` deployments, clears stuck k6 pods, and
re-applies the Bun manifests so any live `set env` / `set resources` tuning is reverted.
