# Load testing the stack

Fire a fixed number of requests at the app (through Caddy) and watch it scale.

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
