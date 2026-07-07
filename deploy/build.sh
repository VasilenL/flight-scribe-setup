#!/bin/sh
# Build all local images for the Flight + Scribe + my-vue-app stack.
# Order matters: the app image is FROM flightjs:local.
set -e

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(cd -- "$HERE/../.." && pwd)   # /home/vasilen

echo "==> flightjs:local   (context: $ROOT/flight)"
docker build -f "$HERE/flight.Dockerfile" -t flightjs:local "$ROOT/flight"

echo "==> my-vue-app:local (context: $ROOT/my-vue-app)"
docker build -f "$HERE/app.Dockerfile" -t my-vue-app:local "$ROOT/my-vue-app"

echo "==> scribe:local     (context: $ROOT/scribe)"
docker build -f "$HERE/scribe.Dockerfile" -t scribe:local "$ROOT/scribe"

echo "==> scribe-bun:local (context: $ROOT/scribe-bun)"
docker build -f "$HERE/scribe-bun.Dockerfile" -t scribe-bun:local "$ROOT/scribe-bun"

# Bun A/B twin of the app (flight-bun). Context is $ROOT (needs flight-bun + my-vue-app-bun).
echo "==> my-vue-app-bun:local (context: $ROOT)"
docker build -f "$HERE/app-bun.Dockerfile" -t my-vue-app-bun:local "$ROOT"

echo "==> done:"
docker images | grep -E 'flightjs|my-vue-app|scribe|scribe-bun' | grep local || true
