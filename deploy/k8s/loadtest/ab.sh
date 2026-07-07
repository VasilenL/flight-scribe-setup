#!/bin/sh
# A/B load test — run the SAME test in-cluster against a target Service, hitting its
# ClusterIP directly (no Caddy in the path, so the only variable is the app runtime).
#
#   sh deploy/k8s/loadtest/ab.sh app        # Node / Koa
#   sh deploy/k8s/loadtest/ab.sh app-bun    # Bun / Bun.serve
#   VUS=1000 DURATION=3m WRITE_RATIO=1 sh deploy/k8s/loadtest/ab.sh app-bun
#
# Runs a throwaway k6 pod inside the cluster (grafana/k6), then truncates the table.
set -e
export KUBECONFIG=${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

TARGET=${1:-app}
: "${VUS:=1000}"
: "${DURATION:=3m}"
: "${WRITE_RATIO:=1}"
# k6 pod resources. Guaranteed floor (requests) so the scheduler reserves it and it can't be
# throttled/evicted under memory pressure at high VU; burstable ceiling (limits) so it can grab
# more cores when generating tens of thousands of VUs. Override via env, e.g. K6_CPU_LIMIT=20.
: "${K6_CPU_REQ:=6}"
: "${K6_MEM_REQ:=6Gi}"
: "${K6_CPU_LIMIT:=16}"
: "${K6_MEM_LIMIT:=12Gi}"

echo "==> A/B load vs '$TARGET'  (VUS=$VUS DURATION=$DURATION WRITE_RATIO=$WRITE_RATIO) — hitting http://$TARGET:3000"
echo "    k6 resources: requests ${K6_CPU_REQ}cpu/${K6_MEM_REQ}  limits ${K6_CPU_LIMIT}cpu/${K6_MEM_LIMIT}"
# Clear any leftover k6 pod from an interrupted run (--rm can't clean up on Ctrl-C).
kubectl -n flight-scribe delete pod "k6-$TARGET" --ignore-not-found --force --grace-period=0 >/dev/null 2>&1 || true
# --overrides sets the container's resources (kubectl run has no stable resource flags). The
# container spec here fully replaces the flag-built one, so command/env/stdin are restated.
OVERRIDES=$(cat <<JSON
{
  "spec": {
    "containers": [
      {
        "name": "k6-$TARGET",
        "image": "grafana/k6",
        "stdin": true,
        "stdinOnce": true,
        "command": ["k6", "run", "-"],
        "env": [
          { "name": "BASE_URL", "value": "http://$TARGET:3000" },
          { "name": "VUS", "value": "$VUS" },
          { "name": "DURATION", "value": "$DURATION" },
          { "name": "WRITE_RATIO", "value": "$WRITE_RATIO" }
        ],
        "resources": {
          "requests": { "cpu": "$K6_CPU_REQ", "memory": "$K6_MEM_REQ" },
          "limits": { "cpu": "$K6_CPU_LIMIT", "memory": "$K6_MEM_LIMIT" }
        }
      }
    ]
  }
}
JSON
)
kubectl -n flight-scribe run "k6-$TARGET" --rm -i --restart=Never --image=grafana/k6 \
  --overrides="$OVERRIDES" \
  --command -- k6 run - < "$HERE/notes-loadtest.js" || true

# reset the shared table so the next side starts clean
sh "$HERE/truncate-notes.sh"
