#!/bin/sh
# Run the note-insert load test, then truncate the table.
#
#   sh deploy/k8s/loadtest/run.sh
#   ITERATIONS=100000 VUS=200 sh deploy/k8s/loadtest/run.sh
#
# Defaults: 50,000 POSTs (WRITE_RATIO=1) at 100 VUs. Set WRITE_RATIO=0.2 for a
# read-heavy mix, or NO_TRUNCATE=1 to keep the rows for inspection.
set -e
export KUBECONFIG=${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

: "${VUS:=100}"
: "${ITERATIONS:=50000}"
: "${WRITE_RATIO:=1}"

IP=$(kubectl -n flight-scribe get svc caddy -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
[ -n "$IP" ] || { echo "caddy has no external IP yet"; exit 1; }

if [ -n "${DURATION:-}" ]; then
  echo "==> load: sustained ${DURATION}, $VUS VUs, WRITE_RATIO=$WRITE_RATIO -> http://$IP"
else
  echo "==> load: $ITERATIONS requests, $VUS VUs, WRITE_RATIO=$WRITE_RATIO -> http://$IP"
fi
docker run --rm -i \
  -e BASE_URL="http://$IP" -e VUS="$VUS" -e ITERATIONS="$ITERATIONS" -e WRITE_RATIO="$WRITE_RATIO" \
  -e DURATION="${DURATION:-}" -e RAMP="${RAMP:-}" \
  grafana/k6 run - < "$HERE/notes-loadtest.js" || true

if [ "${NO_TRUNCATE:-0}" = "1" ]; then
  echo "==> NO_TRUNCATE=1 set; leaving rows in place"
else
  sh "$HERE/truncate-notes.sh"
fi
