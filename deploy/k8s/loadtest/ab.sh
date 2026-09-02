#!/bin/sh
# A/B load test — run the SAME test in-cluster against a target Service, hitting its
# ClusterIP directly (no Caddy in the path, so the only variable is the app runtime).
#
#   sh deploy/k8s/loadtest/ab.sh app             # Node / Koa
#   sh deploy/k8s/loadtest/ab.sh app-bun         # Bun / Bun.serve
#   sh deploy/k8s/loadtest/ab.sh spring-notes    # Java / Spring Boot + Hibernate
#   sh deploy/k8s/loadtest/ab.sh fastapi-notes   # Python / FastAPI + asyncpg
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
# WARMUP — run a throwaway load of this duration first, truncate, THEN measure. Required for
# a fair Java number: a cold JVM is still interpreting bytecode and hasn't JIT-compiled the
# hot path, so an unwarmed spring-notes run measures the compiler, not the runtime. Harmless
# (just slower) for the others, which have no warm-up phase to speak of.
#   WARMUP=60s sh deploy/k8s/loadtest/ab.sh spring-notes
: "${WARMUP:=}"
# Pod name — override K6_NAME to run a SECOND concurrent generator against the same target
# (e.g. K6_NAME=k6-b) without colliding on the default name. Pair with NO_TRUNCATE=1 so the
# two runs don't wipe each other's rows mid-flight.
: "${K6_NAME:=k6-$TARGET}"
# k6 pod resources. Guaranteed floor (requests) so the scheduler reserves it and it can't be
# throttled/evicted under memory pressure at high VU; burstable ceiling (limits) so it can grab
# more cores when generating tens of thousands of VUs. Override via env, e.g. K6_CPU_LIMIT=20.
#
# DON'T raise these to "use the whole box". k6 and the stack under test share the same 24
# cores / 30Gi: every core k6 reserves is one the stack can't have, and a generator that
# starves its target produces a number about the generator. The floor of 6 is what one k6 pod
# actually needs at VUS=3000; the ceiling of 16 is headroom for bursts, not a target.
: "${K6_CPU_REQ:=6}"
: "${K6_MEM_REQ:=6Gi}"
: "${K6_CPU_LIMIT:=16}"
: "${K6_MEM_LIMIT:=12Gi}"

# Fire one k6 pod. $1 = duration, $2 = label for the banner.
run_k6() {
  _dur=$1
  _label=$2
  echo "==> $_label vs '$TARGET'  (VUS=$VUS DURATION=$_dur WRITE_RATIO=$WRITE_RATIO) — hitting http://$TARGET:3000"
  echo "    k6 resources: requests ${K6_CPU_REQ}cpu/${K6_MEM_REQ}  limits ${K6_CPU_LIMIT}cpu/${K6_MEM_LIMIT}"
  # Clear any leftover k6 pod from an interrupted run (--rm can't clean up on Ctrl-C).
  kubectl -n flight-scribe delete pod "$K6_NAME" --ignore-not-found --force --grace-period=0 >/dev/null 2>&1 || true
  # --overrides sets the container's resources (kubectl run has no stable resource flags). The
  # container spec here fully replaces the flag-built one, so command/env/stdin are restated.
  _overrides=$(cat <<JSON
{
  "spec": {
    "containers": [
      {
        "name": "$K6_NAME",
        "image": "grafana/k6",
        "stdin": true,
        "stdinOnce": true,
        "command": ["k6", "run", "-"],
        "env": [
          { "name": "BASE_URL", "value": "http://$TARGET:3000" },
          { "name": "VUS", "value": "$VUS" },
          { "name": "DURATION", "value": "$_dur" },
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
  kubectl -n flight-scribe run "$K6_NAME" --rm -i --restart=Never --image=grafana/k6 \
    --overrides="$_overrides" \
    --command -- k6 run - < "$HERE/notes-loadtest.js" || true
}

if [ -n "$WARMUP" ]; then
  run_k6 "$WARMUP" "WARM-UP (discarded)"
  # Always truncate after the warm-up, even under NO_TRUNCATE — otherwise the measured run
  # starts against a table the warm-up already filled, which is exactly what we're avoiding.
  sh "$HERE/truncate-notes.sh"
  echo
fi

run_k6 "$DURATION" "A/B load"

# reset the shared table so the next side starts clean (skip with NO_TRUNCATE=1 when running a
# second concurrent generator, so the two runs don't wipe each other's rows mid-flight)
if [ -z "${NO_TRUNCATE:-}" ]; then
  sh "$HERE/truncate-notes.sh"
fi
