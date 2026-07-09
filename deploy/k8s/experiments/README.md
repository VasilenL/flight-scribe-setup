# Experiment scaffolding (opt-in — NOT auto-deployed)

`setup-k3s.sh` only applies the top-level `deploy/k8s/*.yaml`; this subdirectory is skipped
(same as `monitoring/`). Apply these by hand to reproduce the Day-6 experiments. Neither is
part of the default stack.

## `50-shard-b.yaml` — a second, independent Postgres shard
Adds `postgres-b` + `pgbouncer-b` + `scribe-bun-b`, plus a `scribe-sharded` Service that
fronts **both** scribe tiers so `app-bun` round-robins writes across two independent DBs
(each with its own WAL + lock space).

```bash
kubectl apply -f deploy/k8s/experiments/50-shard-b.yaml
# bring shard A's scribe-bun under the shared service too:
kubectl -n flight-scribe patch deploy scribe-bun --type merge \
  -p '{"spec":{"template":{"metadata":{"labels":{"shardsvc":"bun"}}}}}'
kubectl -n flight-scribe set env deploy/app-bun SCRIBE_BASE_URL=http://scribe-sharded:1337
```

**Finding:** no throughput gain — both shards sat idle at ~2.8 cores while throughput held at
~35k. The write ceiling is the **single node**, not the database.

## `55-fakedb.yaml` — a trivial "ok" upstream (DB stand-in)
A keep-alive nginx that returns 200. Set `SCRIBE_APP_FAKE_UPSTREAM_URL=http://fakedb` on
scribe-bun to skip Postgres and do one HTTP round-trip instead.

```bash
kubectl apply -f deploy/k8s/experiments/55-fakedb.yaml
kubectl -n flight-scribe set env deploy/scribe-bun   SCRIBE_APP_FAKE_UPSTREAM_URL=http://fakedb
kubectl -n flight-scribe set env deploy/scribe-bun-b SCRIBE_APP_FAKE_UPSTREAM_URL=http://fakedb
# revert with: kubectl -n flight-scribe set env deploy/scribe-bun SCRIBE_APP_FAKE_UPSTREAM_URL-
```

**Finding (confounded):** an *unpooled* per-request HTTP hop is **slower** than the warm,
pooled DB connection, so this can't cleanly separate "hop cost" from "insert cost." The real
lesson: **connection pooling is what makes the write path fast** — the DB was never the villain.
