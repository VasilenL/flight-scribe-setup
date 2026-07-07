#!/bin/sh
# Import the locally-built images into k3s's containerd (namespace k8s.io) so pods
# with imagePullPolicy: IfNotPresent find them without a registry.
#
# Run as YOUR user (NOT sudo): `docker save` must talk to your Docker Desktop
# daemon, which root can't reach. Only `k3s ctr` is sudo'd (below).
set -e

if [ "$(id -u)" = "0" ]; then
  echo "ERROR: run this as your normal user, not root/sudo." >&2
  echo "       (docker save needs your Docker Desktop daemon; ctr import is sudo'd internally)" >&2
  exit 1
fi

for img in my-vue-app:local my-vue-app-bun:local scribe:local scribe-bun:local; do
  if ! docker image inspect "$img" >/dev/null 2>&1; then
    echo "ERROR: image '$img' not found. Run 'sh deploy/build.sh' first." >&2
    exit 1
  fi
  echo "==> importing $img into k3s"
  docker save "$img" | sudo k3s ctr images import -
done

echo "==> present in k3s:"
sudo k3s ctr images ls | grep -E 'my-vue-app|scribe' || true
