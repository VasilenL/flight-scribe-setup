# Load testing the stack

Fire a fixed number of requests at the app (through Caddy) and watch it scale.

## Which script do I want?

| Script | Path | Use it for |
|--------|------|-----------|
| **`ab.sh`** | k6 pod → a Service's ClusterIP, **Caddy out of the path** | **runtime A/B** — the only variable is the tier under test |
| `run.sh` | k6 pod → through Caddy, the full chain | sustained load that looks right in Grafana |
| `truncate-notes.sh` | — | reset the tables by hand |
| `bench-reset.sh` | — | return the cluster to a clean Bun-only baseline |

## `ab.sh` — the A/B runner

```bash
sh deploy/k8s/loadtest/ab.sh app-bun                        # Bun edge → Bun data tier
VUS=3000 DURATION=3m sh deploy/k8s/loadtest/ab.sh app-bun
VUS=3000 DURATION=3m WARMUP=60s sh deploy/k8s/loadtest/ab.sh spring-notes
```

Targets are any Service exposing `/api/notes` on port **3000** — `app`, `app-bun`, and the
cross-runtime peers in [`../bench/`](../bench/) (`spring-notes`, `fastapi-notes`).

| Env | Default | Meaning |
|-----|---------|---------|
| `VUS` | `1000` | concurrent virtual users |
| `DURATION` | `3m` | length of the measured run |
| `WARMUP` | *(off)* | run a throwaway load of this length first, truncate, **then** measure |
| `WRITE_RATIO` | `1` | fraction of requests that POST (1 = all inserts) |
| `NO_TRUNCATE` | *(off)* | skip the post-run truncate |
| `K6_NAME` | `k6-<target>` | pod name — override to run a second concurrent generator |
| `K6_CPU_REQ` / `K6_CPU_LIMIT` | `6` / `16` | k6 pod cores (see the warning below) |
| `K6_MEM_REQ` / `K6_MEM_LIMIT` | `6Gi` / `12Gi` | k6 pod memory |

**`WARMUP` exists for the JVM.** A cold `spring-notes` is still interpreting bytecode, so an
unwarmed run measures the JIT compiler rather than the runtime. Apply it to *every* stack in
a comparison, not just Java — identical treatment costs two minutes and removes the
"you warmed one of them" objection.

> ⚠️ **Don't raise the k6 limits to "use the whole box."** k6 and the stack under test share
> the same 24 cores: every core k6 reserves is one the stack can't have, and a generator that
> starves its target produces a number about the generator. If throughput plateaus while
> every tier coasts, check `kubectl top pods` — if k6 is pegged at its limit, run the
> generator off-node rather than giving it more of this one.

## Insert load + auto-truncate (one command)

Runs the note-**insert** test (50k POSTs by default) then truncates the table so each
run starts clean:
```bash
sh deploy/k8s/loadtest/run.sh                       # 50k inserts, then TRUNCATE
ITERATIONS=100000 VUS=200 sh deploy/k8s/loadtest/run.sh
WRITE_RATIO=0.2 sh deploy/k8s/loadtest/run.sh        # read-heavy mix instead
NO_TRUNCATE=1 sh deploy/k8s/loadtest/run.sh          # keep rows to inspect
```
Truncate on its own any time:
```bash
sh deploy/k8s/loadtest/truncate-notes.sh
```

It covers **both** table families — `notes` / `notes_history` (scribe, scribe-bun) and
`bench_notes` / `bench_notes_history` (the cross-runtime peers) — truncating each only if it
exists, so it's a no-op on a Bun-only cluster. Each family is truncated in a single
statement because the history table carries an `ON DELETE CASCADE` foreign key.

The manual building blocks are below.

First grab the node IP:
```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
IP=$(kubectl -n flight-scribe get svc caddy -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "$IP"
```

## Option A — k6 (recommended: p95/p99 latency, rps, error rate)

No install, via Docker:
```bash
docker run --rm -i -e BASE_URL=http://$IP grafana/k6 run - < notes-loadtest.js
```
Native (Fedora): `sudo dnf install k6` (or grab the binary), then:
```bash
k6 run -e BASE_URL=http://$IP notes-loadtest.js
```

Tunables:
```bash
# 50k reads, 200 concurrent
k6 run -e BASE_URL=http://$IP -e VUS=200 -e ITERATIONS=50000 notes-loadtest.js
# 50k requests, 20% writes (POST notes)
k6 run -e BASE_URL=http://$IP -e WRITE_RATIO=0.2 notes-loadtest.js
```

## Option B — hey (dead simple, one line)
```bash
# 50,000 requests, 100 concurrent
hey -n 50000 -c 100 http://$IP/api/notes
```
Install: `sudo dnf install hey` or `go install github.com/rakyll/hey@latest`.

## Watch what happens (separate terminals)
```bash
watch kubectl -n flight-scribe get pods,hpa           # replicas scaling on CPU
kubectl -n flight-scribe top pods                     # live cpu/mem
```
And in Grafana (`kubectl -n monitoring port-forward svc/monitoring-grafana 8080:80`):
- edge latency p95: `histogram_quantile(0.95, sum(rate(caddy_http_request_duration_seconds_bucket[1m])) by (le))`
- rps: `sum(rate(caddy_http_requests_total[1m]))`

> The Flight rate limit must be OFF for a clean run — `30-app.yaml` sets
> `FLIGHT_RATE_LIMIT_DISABLE=true`. Confirm with:
> `kubectl -n flight-scribe exec deploy/app -- printenv FLIGHT_RATE_LIMIT_DISABLE`
