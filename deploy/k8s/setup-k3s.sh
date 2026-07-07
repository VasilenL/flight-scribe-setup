#!/bin/sh
# One-shot bring-up of the Flight+Scribe stack on a local k3s cluster with
# observability.
#
# Run as YOUR normal user (NOT `sudo sh ...`). The script sudo's internally where
# root is needed (k3s install, ctr import). `docker save` must run as your user
# because Docker Desktop's daemon isn't reachable by root. Assumes ../build.sh
# already built the images (flightjs:local, my-vue-app:local, scribe:local).
set -e

if [ "$(id -u)" = "0" ]; then
  echo "ERROR: don't run this with sudo — run it as your user; it elevates where needed." >&2
  exit 1
fi

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)   # deploy/k8s

# 1) Install k3s WITHOUT Traefik (we front with Caddy). Installer sudo's itself.
#    Keeps servicelb + metrics-server. kubeconfig world-readable so we skip sudo below.
if ! command -v k3s >/dev/null 2>&1; then
  echo "==> installing k3s (no traefik)"
  curl -sfL https://get.k3s.io | \
    INSTALL_K3S_EXEC="--disable traefik --write-kubeconfig-mode 644" sh -
fi
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
kubectl() { k3s kubectl "$@"; }

# 1b) Fedora/RHEL: firewalld drops k3s pod/service traffic by default, which shows
#     up as EHOSTUNREACH between pods (e.g. scribe -> postgres). Trust the CIDRs and
#     restart k3s so flannel/kube-proxy re-apply their rules on top.
if command -v firewall-cmd >/dev/null 2>&1 && sudo firewall-cmd --state >/dev/null 2>&1; then
  if ! sudo firewall-cmd --zone=trusted --list-sources 2>/dev/null | grep -q '10.42.0.0/16'; then
    echo "==> firewalld: trusting pod (10.42.0.0/16) + service (10.43.0.0/16) CIDRs"
    sudo firewall-cmd --permanent --zone=trusted --add-source=10.42.0.0/16 >/dev/null
    sudo firewall-cmd --permanent --zone=trusted --add-source=10.43.0.0/16 >/dev/null
    sudo firewall-cmd --reload >/dev/null
    sudo systemctl restart k3s
    echo "==> waiting for the k3s API to come back"
    until kubectl get nodes >/dev/null 2>&1; do sleep 2; done
  fi
fi

# 2) Import the locally-built images into k3s containerd (docker save as user)
BUN_ONLY="${BUN_ONLY:-0}" sh "$HERE/load-images.sh"

# 3) Apply the app stack (dir is non-recursive, so monitoring/ is skipped here).
#    BUN_ONLY=1 skips the Node-tier deployments (app, scribe) whose images aren't built.
echo "==> applying stack manifests"
if [ "${BUN_ONLY:-0}" = "1" ]; then
  for f in "$HERE"/*.yaml; do
    case "$(basename "$f")" in
      20-scribe.yaml|30-app.yaml) echo "   (BUN_ONLY: skipping $(basename "$f"))"; continue ;;
    esac
    kubectl apply -f "$f"
  done
else
  kubectl apply -f "$HERE/"
fi

# 4) Observability: Helm + kube-prometheus-stack
if ! command -v helm >/dev/null 2>&1; then
  echo "==> installing helm"
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update >/dev/null
echo "==> installing kube-prometheus-stack (pods come up in the background)"
helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
  -n monitoring --create-namespace \
  -f "$HERE/monitoring/values-kube-prometheus-stack.yaml"

# 5) ServiceMonitor for Caddy — wait only for its CRD (fast), not all pods.
echo "==> waiting for the ServiceMonitor CRD to register"
kubectl wait --for=condition=established --timeout=120s \
  crd/servicemonitors.monitoring.coreos.com || \
  echo "   (CRD not ready yet; re-apply servicemonitor-caddy.yaml later)"
kubectl apply -f "$HERE/monitoring/servicemonitor-caddy.yaml" || true

echo
echo "==> done. Endpoints (servicelb assigns node IPs):"
kubectl -n flight-scribe get svc caddy -o wide
kubectl -n monitoring get svc monitoring-grafana -o wide
echo "Grafana login: admin / admin (see values file)"
echo "Watch scaling:  watch kubectl -n flight-scribe get pods,hpa"
