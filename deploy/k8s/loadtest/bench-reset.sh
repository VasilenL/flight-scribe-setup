#!/bin/sh
# bench-reset.sh — return the cluster to a clean, minimal Bun-only benchmark baseline.
#
# WHY THIS EXISTS: repeated deploys + node re-registration silt up the two things the
# write path is throughput-bound on — kube-proxy's iptables ruleset and the conntrack
# (NAT) table. That makes the benchmark decay session over session (35k -> 33k -> 28k...).
# This tears the cluster back down to just the Bun write path, flushes the stale NAT state,
# shows you the result, and (optionally) runs a clean baseline — so every session STARTS
# from the same place instead of inheriting last session's cruft.
#
#   sh deploy/k8s/loadtest/bench-reset.sh                 # reset + baseline (VUS=3000, 2m)
#   VUS=1500 DURATION=90s sh .../bench-reset.sh           # reset + custom baseline
#   NO_LOADTEST=1 sh .../bench-reset.sh                   # reset only, skip the k6 run
#   NO_CONNTRACK=1 sh .../bench-reset.sh                  # skip the sudo conntrack flush
#   PURGE_NODE=1 sh .../bench-reset.sh                    # also delete the Node app/scribe originals
#
set -e
export KUBECONFIG=${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}
NS=flight-scribe
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../../.." && pwd)   # deploy/k8s/loadtest -> repo root

: "${VUS:=3000}"
: "${DURATION:=2m}"

echo "==> bench-reset: tearing the cluster down to the Bun write path only"

# --- 1. remove cross-runtime peers, Bun A/B variants, and experiment cruft -------------
# delete -f removes BOTH the Deployment and its Service from each manifest.
for f in \
  deploy/k8s/bench/spring-notes.yaml \
  deploy/k8s/bench/fastapi-notes.yaml \
  deploy/k8s/bench/scribe-bun-ab.yaml \
  deploy/k8s/experiments/50-shard-b.yaml \
  deploy/k8s/experiments/55-fakedb.yaml ; do
  if [ -f "$ROOT/$f" ]; then
    kubectl -n "$NS" delete -f "$ROOT/$f" --ignore-not-found --wait=false >/dev/null 2>&1 || true
    echo "    removed: $f"
  fi
done

# Node originals (app / scribe) — opt-in, since they're the Node-vs-Bun A/B baseline.
if [ -n "${PURGE_NODE:-}" ]; then
  kubectl -n "$NS" delete deploy app scribe --ignore-not-found --wait=false >/dev/null 2>&1 || true
  echo "    removed: Node originals (app, scribe)"
fi

# Any leftover k6 pod from an interrupted run — including the cross-runtime peers'.
kubectl -n "$NS" delete pod k6-app-bun k6-app k6-spring-notes k6-fastapi-notes \
  --ignore-not-found --force --grace-period=0 >/dev/null 2>&1 || true

# --- 2. wire the write path to a known-good, right-sized shape --------------------------
# Re-APPLY the manifests first, so anything changed by hand during a session (`set env`,
# `set resources`, `scale`) goes back to the committed baseline — pool size, CPU limits and
# all. Without this the reset only removes pods and silently inherits last session's tuning.
kubectl apply -f "$ROOT/deploy/k8s/25-scribe-bun.yaml" >/dev/null 2>&1 || true
kubectl apply -f "$ROOT/deploy/k8s/35-app-bun.yaml"    >/dev/null 2>&1 || true
kubectl -n "$NS" set env  deploy/app-bun SCRIBE_BASE_URL=http://scribe-bun:1337 >/dev/null 2>&1 || true
kubectl -n "$NS" scale deploy/app-bun    --replicas=2 >/dev/null 2>&1 || true
kubectl -n "$NS" scale deploy/scribe-bun --replicas=2 >/dev/null 2>&1 || true

# --- 3. flush the stale NAT/conntrack state (needs root) -------------------------------
if [ -z "${NO_CONNTRACK:-}" ]; then
  RULES=$(sudo iptables-save 2>/dev/null | grep -c '^-A KUBE' || echo '?')
  echo "==> kube-proxy iptables KUBE-rule count: $RULES  (only a k3s restart clears these fully)"
  echo "==> flushing conntrack (sudo)"
  sudo conntrack -F 2>/dev/null || echo "    (conntrack unavailable — skipped)"
fi

# --- 4. wait for the lean cluster to settle, then show it ------------------------------
echo "==> waiting for the write path to be ready"
kubectl -n "$NS" rollout status deploy/app-bun    --timeout=120s >/dev/null 2>&1 || true
kubectl -n "$NS" rollout status deploy/scribe-bun --timeout=120s >/dev/null 2>&1 || true
echo "==> surviving pods:"
kubectl -n "$NS" get pods --no-headers 2>/dev/null | awk '{printf "    %-34s %s\n",$1,$3}'
echo "==> node utilization:"
kubectl top nodes 2>/dev/null | sed 's/^/    /' || echo "    (metrics-server not ready)"

# --- 5. clean baseline -----------------------------------------------------------------
if [ -z "${NO_LOADTEST:-}" ]; then
  echo "==> baseline: VUS=$VUS DURATION=$DURATION vs app-bun"
  VUS="$VUS" DURATION="$DURATION" sh "$HERE/ab.sh" app-bun
fi

echo "==> bench-reset complete"
