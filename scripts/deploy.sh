#!/usr/bin/env bash
# deploy.sh — Install or upgrade the baseline stack
#
# Prerequisites:
#   - k3s running with kubectl access
#   - Helm 3 installed
#   - ingress-nginx installed on the cluster
#   - Cloudflare tunnel pre-created in dashboard (if using tunnel)
#   - values-dev.yaml configured with domain, API token, tunnel credentials
#
# Usage:
#   bash scripts/deploy.sh              # install/upgrade
#   bash scripts/deploy.sh --uninstall  # tear down
set -euo pipefail

export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
cd "$(dirname "$0")/.."

if [ "${1:-}" = "--uninstall" ]; then
  echo "Uninstalling baseline..."
  helm uninstall baseline 2>/dev/null || true
  echo "Done. CRDs are preserved (Helm doesn't delete CRDs on uninstall)."
  exit 0
fi

echo "=== Baseline Stack Deploy ==="

# Update subchart dependencies
echo "--- Updating dependencies..."
helm dependency update . 2>&1 | tail -2

# Deploy
echo "--- Deploying..."
helm upgrade --install baseline . -f values-dev.yaml

echo
echo "=== Deploy complete ==="
kubectl get pods -l app.kubernetes.io/instance=baseline --no-headers
