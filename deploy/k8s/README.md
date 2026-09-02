# Flight + Scribe on k3s (local perf cluster)

Runs the whole stack on a native k3s cluster (no VM), with independent scaling,
Caddy as the edge balancer, and Prometheus/Grafana observability.

```
                 ┌────────── k3s node (host kernel) ──────────┐
  client ─▶ Caddy(LoadBalancer :80) ─▶ Service app ─▶ app pods (Flight prod: Vue + /api)
                                                          │
                                          Service scribe ─▶ scribe pods ─▶ Service postgres ─▶ postgres
                                          Service redis  ◀─ app + scribe
  Prometheus ◀─ node-exporter / kube-state-metrics / kubelet-cAdvisor / caddy:2019/metrics
  Grafana    ◀─ Prometheus
```

## Prerequisites
- Images built: `cd .. && sh build.sh` → `my-vue-app:local`, `scribe:local` (and `flightjs:local`).
- A host you can `sudo` on (k3s runs as root systemd). Docker (Desktop or engine) to `docker save` the images.

## Bring it up
```bash
sudo sh deploy/k8s/setup-k3s.sh
```
This installs k3s (no Traefik), imports the images, applies the manifests, installs
kube-prometheus-stack, and wires the Caddy ServiceMonitor. Then:
```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
kubectl -n flight-scribe get pods,svc,hpa
kubectl -n flight-scribe get svc caddy          # note the EXTERNAL-IP (node IP)
```
- **App (via Caddy):** `http://<node-ip>/`  → Vue UI; `http://<node-ip>/api/notes` → API
- **Grafana:** `http://<grafana-node-ip>/` (admin / admin) — cluster & pod CPU/mem/network dashboards ship built-in
- **Prometheus:** `kubectl -n monitoring port-forward svc/monitoring-kube-prometheus-prometheus 9090`

## Scale independently
```bash
kubectl -n flight-scribe scale deploy/app    --replicas=6
kubectl -n flight-scribe scale deploy/scribe --replicas=4
kubectl -n flight-scribe get hpa                     # autoscaling on CPU (app 2–10, scribe 2–6)
```
The ClusterIP Services (`app`, `scribe`) round-robin across their pods; Caddy balances
external traffic to the `app` Service.

## Observability (cpu / memory / network / latency)
- **CPU / memory / network** — node-exporter + kubelet cAdvisor + kube-state-metrics → Grafana
  dashboards "Kubernetes / Compute Resources / *". `kubectl top pods -n flight-scribe` also works (metrics-server).
- **Latency (edge)** — Caddy exposes `caddy_http_request_duration_seconds` at `:2019/metrics`.
  In Grafana Explore:
  - p95: `histogram_quantile(0.95, sum(rate(caddy_http_request_duration_seconds_bucket[1m])) by (le))`
  - rps: `sum(rate(caddy_http_requests_total[1m]))`
- **Per-service latency (app/scribe internals)** needs app instrumentation or a mesh
  (e.g. Linkerd gives p50/p95/p99 per deployment with no code change). Ask if you want that added.

## Load testing
Point a generator at `http://<node-ip>/api/notes`. Watch scaling live:
```bash
watch -n2 kubectl -n flight-scribe get pods,hpa
```

## Troubleshooting

**Pods CrashLoop with `EHOSTUNREACH` to another pod's IP (e.g. scribe → postgres).**
Fedora's `firewalld` drops k3s pod/service traffic by default. `setup-k3s.sh` now handles
this, but to fix by hand:
```bash
sudo firewall-cmd --permanent --zone=trusted --add-source=10.42.0.0/16   # pods
sudo firewall-cmd --permanent --zone=trusted --add-source=10.43.0.0/16   # services
sudo firewall-cmd --reload
sudo systemctl restart k3s
```

**Grafana Service stuck `<pending>` for an external IP.** k3s's servicelb can only bind
host port 80 once per node, and Caddy already holds it. Reach Grafana via port-forward
instead: `kubectl -n monitoring port-forward svc/monitoring-grafana 8080:80` → http://localhost:8080.

## Known limits (matter for perf numbers)
1. **Flight prod rate limit** — defaults to 1200 req/min per client IP. Now env-configurable:
   `FLIGHT_RATE_LIMIT_DISABLE=true` (off, for load tests — set in `30-app.yaml`),
   `FLIGHT_RATE_LIMIT_MAX=<n>` (per-IP per window), `FLIGHT_RATE_LIMIT_DURATION_MS=<ms>`.
   Re-enable/raise it for anything but a perf run.
2. **Scribe worker count** — Scribe forks one worker per *host* CPU unless capped, and the
   container CPU limit doesn't change `os.cpus()`. Fixed via the `SCRIBE_WORKERS` env (set to
   `2` in `20-scribe.yaml`); keep it in step with `limits.cpu`. Scale horizontally via `replicas`.

## Opt-in subdirectories

`setup-k3s.sh` applies only the top-level `*.yaml` here. These are deployed by hand:

| Dir | What's in it |
|-----|--------------|
| [`bench/`](bench/) | Cross-runtime peers — `spring-notes` (Java), `fastapi-notes` (Python), and the Bun Zig-vs-Rust A/B |
| [`experiments/`](experiments/) | Day-6 experiments — a second Postgres shard, a fake-DB upstream |
| [`monitoring/`](monitoring/) | Helm values + the Caddy ServiceMonitor (installed by `setup-k3s.sh` through Helm, not `kubectl apply`) |

Load testing: see [loadtest/README.md](loadtest/README.md) (k6 / hey, 50k requests), and
[BENCHMARKS.md](../../BENCHMARKS.md) for the full A/B procedures.

## Teardown
```bash
kubectl delete -f deploy/k8s/            # app stack
helm -n monitoring uninstall monitoring  # observability
sudo /usr/local/bin/k3s-uninstall.sh     # nuke the cluster
```
