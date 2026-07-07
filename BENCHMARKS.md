# Benchmarking the Flight + Scribe stack

How to stand up the whole stack on a **local k3s cluster** and run the runtime A/B load
tests — Node vs **Bun** at both the edge tier (Flight vs flight-bun) and the data tier
(Scribe vs scribe-bun), behind a shared PgBouncer + Postgres.

> This is the benchmarking guide. For the cluster internals see
> [`deploy/k8s/README.md`](deploy/k8s/README.md); for the load-generator options see
> [`deploy/k8s/loadtest/README.md`](deploy/k8s/loadtest/README.md); for the write-up of
> results see the report artifact.

---

## What gets benchmarked

The stack is a 3-tier pipeline. Each request flows:

```
client ─▶ Caddy :80 ─▶ app / app-bun :3000 ─▶ scribe / scribe-bun :1337 ─▶ pgbouncer :5432 ─▶ postgres :5432
  (edge LB)          (EDGE tier)            (DATA tier)                  (pool)            (db)
                                             │
                              redis :6379 ◀──┘  (schema cache)
```

Two tiers each have a **Node** implementation and a **Bun** rewrite, deployed side by side
so a load test can swap one and hold everything else constant:

| Deployment | Image | Runtime | Tier | Source (sibling folder) |
|------------|-------|---------|------|------|
| `app`        | `my-vue-app:local`     | Node / Koa (Flight)      | edge | `flight` + `my-vue-app` — *not published* |
| `app-bun`    | `my-vue-app-bun:local` | **Bun** (flight-bun)     | edge | `flight-bun` + `my-vue-app-bun` — on GitHub |
| `scribe`     | `scribe:local`         | Node / Express (Scribe)  | data | `scribe` — *not published* |
| `scribe-bun` | `scribe-bun:local`     | **Bun** (scribe-bun)     | data | `scribe-bun` — on GitHub |
| `postgres`   | `postgres:16-alpine`   | —                        | db   | (upstream) |
| `pgbouncer`  | `edoburu/pgbouncer`    | —                        | pool | (upstream) |
| `redis`      | `redis`                | —                        | cache| (upstream) |
| `caddy`      | `caddy`                | —                        | edge LB | (upstream) |

> **Where is "flight-bun"?** There is no standalone flight-bun image — it's the server
> *inside* `my-vue-app-bun:local` (Node/pnpm builds the Vue SPA, then Bun runs flight-bun to
> serve `dist/` + `/api`). The deployment is `app-bun`. Same pattern for `app` = Flight
> inside `my-vue-app:local`.

The two tiers connect through env vars you can flip live:
- `app` / `app-bun` → data tier via **`SCRIBE_BASE_URL`** (`http://scribe:1337` or `http://scribe-bun:1337`)
- `scribe` / `scribe-bun` → **`SCRIBE_APP_DB_HOST=pgbouncer`** → Postgres

---

## Prerequisites

- **Linux host you can `sudo` on** (k3s runs as a root systemd service).
- **Docker** (Desktop or engine) — used to build the images and `docker save` them into k3s.
- **The repos cloned as siblings** under one parent dir — see [Step 0](#step-0--clone-the-repos).
- **k6** is *not* needed locally — the A/B runner pulls `grafana/k6` and runs it **inside the
  cluster**.

All commands below assume you're in the `flight-scribe-setup/` clone and, for `kubectl`:

```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
```

---

## Step 0 — Clone the repos

All repos must sit under **one parent directory** — the build scripts reference each other by
sibling folder name, so the folder names matter (note the **rename** below):

```bash
mkdir -p ~/stack && cd ~/stack

git clone https://github.com/VasilenL/flight-scribe-setup.git          # deploy scripts + this guide
git clone https://github.com/VasilenL/flight-bun.git                   # Bun edge tier
git clone https://github.com/VasilenL/scribe-bun.git                   # Bun data tier
git clone https://github.com/VasilenL/vue-app-flight.git my-vue-app-bun  # ⚠ MUST clone as my-vue-app-bun
```

Then run every command below from the **`flight-scribe-setup/`** clone.

> **Bun-only vs full A/B.** Those four repos are enough to build and run the **Bun** stack
> (`app-bun` + `scribe-bun`) — pass `BUN_ONLY=1` in Steps 1–2. The **Node** side of the
> comparison (`flight`, `my-vue-app`, `scribe`) isn't published; to run Node-vs-Bun, add
> those three as siblings and drop `BUN_ONLY`.

## Step 1 — Build the images

```bash
BUN_ONLY=1 sh deploy/build.sh   # Bun stack only: scribe-bun:local + my-vue-app-bun:local
sh deploy/build.sh              # full: also flightjs / my-vue-app / scribe (needs the Node repos)
```

Builds `scribe-bun:local` + `my-vue-app-bun:local` — and, without `BUN_ONLY`, also the Node
images `flightjs:local`, `my-vue-app:local`, `scribe:local` — from the sibling repos. Re-run
whenever you change a tier's source. (If `docker build` fails on `/var/run/docker.sock`, start
Docker Desktop and `docker context use desktop-linux`.)

## Step 2 — Bring up the cluster

```bash
BUN_ONLY=1 sh deploy/k8s/setup-k3s.sh   # Bun stack only — run as your user, NOT sudo
sh deploy/k8s/setup-k3s.sh              # full stack (needs the Node images built)
```

This one-shot script:
1. installs k3s (no Traefik — Caddy fronts instead; keeps servicelb + metrics-server),
2. on Fedora/RHEL, trusts the pod/service CIDRs in `firewalld` (else pods can't reach each other),
3. imports the local images into k3s's containerd (`deploy/k8s/load-images.sh` — `BUN_ONLY` imports only the Bun images),
4. applies the manifests in `deploy/k8s/` (namespace, postgres, pgbouncer, redis, scribe,
   scribe-bun, app, app-bun, caddy) — with `BUN_ONLY=1` it **skips the `app` and `scribe`
   Node deployments** whose images aren't built,
5. installs kube-prometheus-stack (Grafana/Prometheus) + the Caddy ServiceMonitor.

> **Bun-only caveat:** with `BUN_ONLY`, only the `app-bun` + `scribe-bun` tiers exist, so use
> the in-cluster A/B runner (`ab.sh app-bun`, below). The through-Caddy `run.sh` path targets
> the Node `app` deployment, which isn't present in a Bun-only cluster.

## Step 3 — Verify it's up

```bash
kubectl -n flight-scribe get pods                 # all Running
kubectl -n flight-scribe get svc caddy -o wide    # note the EXTERNAL-IP (node IP)
curl http://<node-ip>/api/notes                    # [] once scribe has a table
```

---

## Step 4 — Run a benchmark

### The A/B runner (recommended)

[`deploy/k8s/loadtest/ab.sh`](deploy/k8s/loadtest/ab.sh) runs k6 **in-cluster, hitting a
Service's ClusterIP directly** — so Caddy is *out* of the path and the only variable is the
tier under test. It fires a load, prints the k6 summary, then truncates the `notes` table so
the next run starts clean.

```bash
sh deploy/k8s/loadtest/ab.sh app-bun                       # default: 1000 VUs, 3m
VUS=3000 DURATION=3m sh deploy/k8s/loadtest/ab.sh app-bun  # tune load
```

Targets: **`app`** (Node/Koa edge) or **`app-bun`** (Bun edge). Env knobs: `VUS`,
`DURATION`, `WRITE_RATIO` (1 = all inserts), and k6 pod resources `K6_CPU_LIMIT` /
`K6_MEM_LIMIT` / `K6_CPU_REQ` / `K6_MEM_REQ` (raise these when driving very high VU so the
generator itself isn't the bottleneck).

### Data-tier A/B — Node scribe vs scribe-bun (the main experiment)

Hold the **Bun front-end (`app-bun`) constant** and swap only its data tier, so the result
isolates the *data-tier* runtime. Run `ab.sh app-bun` for **both** sides:

```bash
# Side A — Bun data tier
kubectl -n flight-scribe set env deploy/app-bun SCRIBE_BASE_URL=http://scribe-bun:1337
kubectl -n flight-scribe rollout status deploy/app-bun
VUS=3000 DURATION=3m sh deploy/k8s/loadtest/ab.sh app-bun

# Side B — Node data tier (SAME front-end)
kubectl -n flight-scribe set env deploy/app-bun SCRIBE_BASE_URL=http://scribe:1337
kubectl -n flight-scribe rollout status deploy/app-bun
VUS=3000 DURATION=3m sh deploy/k8s/loadtest/ab.sh app-bun
```

> ⚠️ **Do not** use `ab.sh app` for side B. `app` is the separate Node/Koa front-end (small
> CPU budget) — testing through it confounds the data-tier comparison. Always drive
> `app-bun` and swap `SCRIBE_BASE_URL`.

### App-tier A/B — Node/Koa Flight vs flight-bun

Point both edges at the same data tier, then compare the edges directly:

```bash
VUS=1000 DURATION=3m sh deploy/k8s/loadtest/ab.sh app       # Node/Koa edge
VUS=1000 DURATION=3m sh deploy/k8s/loadtest/ab.sh app-bun   # Bun edge
```

### Full-path / sustained load (Grafana-friendly)

To exercise the whole chain *through Caddy* (nicer for the Grafana dashboards), use
[`deploy/k8s/loadtest/run.sh`](deploy/k8s/loadtest/run.sh):

```bash
sh deploy/k8s/loadtest/run.sh                          # 50k inserts via Caddy, then truncate
DURATION=3m VUS=1000 sh deploy/k8s/loadtest/run.sh     # sustained
RAMP=1 sh deploy/k8s/loadtest/run.sh                   # step VUs to trace the knee
```

---

## Watching what happens

In separate terminals during a run:

```bash
watch -n2 kubectl -n flight-scribe top pods            # per-pod CPU/mem (find the bottleneck)
kubectl top node                                        # whole-box CPU (24 cores) — the hard ceiling
watch -n2 kubectl -n flight-scribe get pods,hpa        # replicas / autoscaling
```

Grafana (`kubectl -n monitoring port-forward svc/monitoring-grafana 8080:80`, `admin/admin`):
- edge p95: `histogram_quantile(0.95, sum(rate(caddy_http_request_duration_seconds_bucket[1m])) by (le))`
- rps: `sum(rate(caddy_http_requests_total[1m]))`

**Reading the result:** compare throughput (`http_reqs/s` in the k6 summary), p95, and which
tier's CPU is pegged in `top pods`. A tier at its CPU limit is the bottleneck; a tier
coasting while throughput is flat means the wall is *downstream* of it (see the DB knobs
below).

---

## Scaling & DB tuning (pushing the ceilings)

Scale a tier's replicas:
```bash
kubectl -n flight-scribe scale deploy/scribe-bun --replicas=4
```

Postgres write path — edit [`deploy/k8s/10-postgres.yaml`](deploy/k8s/10-postgres.yaml)
(`max_connections`, `synchronous_commit`, cpu/mem `limits`) then:
```bash
kubectl apply -f deploy/k8s/10-postgres.yaml
kubectl -n flight-scribe rollout restart statefulset/postgres
```

Connection pool — edit [`deploy/k8s/45-pgbouncer.yaml`](deploy/k8s/45-pgbouncer.yaml)
(`DEFAULT_POOL_SIZE`, `MAX_CLIENT_CONN`) then:
```bash
kubectl apply -f deploy/k8s/45-pgbouncer.yaml
kubectl -n flight-scribe rollout restart deploy/pgbouncer
```

Verify a config landed:
```bash
kubectl -n flight-scribe exec statefulset/postgres -- psql -U scribe -tAc \
  "show max_connections; show synchronous_commit;"
```

---

## Reset between runs

`ab.sh` and `run.sh` truncate `notes` automatically at the end. To reset by hand:
```bash
sh deploy/k8s/loadtest/truncate-notes.sh
```

---

## Gotchas (they affect the numbers)

- **Keep the load path clean.** For a runtime A/B, leave the edge middleware off — the
  Flight rate limit is disabled via `FLIGHT_RATE_LIMIT_DISABLE=true` in `30-app.yaml`, and
  flight-bun's middleware is dormant by default. Turning logging/rate-limit/sessions on
  perturbs throughput; do it only for functional verification, in a separate run.
- **The load generator can become the bottleneck.** At tens of thousands of req/s the single
  in-cluster k6 pod burns several cores; if throughput plateaus while every tier coasts,
  raise `K6_CPU_LIMIT` (or run k6 off-node) before concluding you hit a stack limit.
- **Node identity churn (multi-day gaps).** If the host's node re-registers under a new name/
  IP, `postgres-0` + its PVC can get stranded on the dead node (requests hang, no `postgres`
  endpoints). Fix: `kubectl delete node <stale>`, force-delete `postgres-0`, delete PVC
  `data-postgres-0` (data is disposable for a benchmark), let the StatefulSet recreate, then
  `kubectl -n flight-scribe rollout restart deploy/pgbouncer` to clear its DNS cache.
- **Docker Desktop drops out** across reboots — restart it (`docker desktop start`,
  `docker context use desktop-linux`) if `build.sh` fails on the socket.

---

## Teardown

```bash
kubectl delete -f deploy/k8s/            # app stack
helm -n monitoring uninstall monitoring  # observability
sudo /usr/local/bin/k3s-uninstall.sh     # remove the cluster entirely
```

---

## See also

- [`deploy/k8s/README.md`](deploy/k8s/README.md) — cluster architecture, observability, troubleshooting
- [`deploy/k8s/loadtest/README.md`](deploy/k8s/loadtest/README.md) — k6 / hey load-generator options
- `../flight-bun/README.md` — the Bun edge tier (how it works, feature parity)
- `../scribe-bun/README.md` — the Bun data tier (how it works, setup)
