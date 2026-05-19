#!/usr/bin/env bash
#
# redeploy-cluster.sh — tear down and rebuild the whole lab from scratch.
#
# Performs a full destroy + recreate cycle:
#   1. terraform destroy   — remove the 9 VMs
#   2. terraform apply     — provision fresh VMs, write the inventory, and
#                            run playbooks/setup-cluster.yml on top
#
# Usage:
#   scripts/redeploy-cluster.sh                 # destroy, then rebuild
#   scripts/redeploy-cluster.sh --skip-destroy  # just (re)build
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="$REPO_ROOT/terraform"

cd "$TF_DIR"
terraform init -input=false

if [[ "${1:-}" != "--skip-destroy" ]]; then
  echo "==> Destroying existing VMs..."
  terraform destroy -auto-approve
fi

echo "==> Provisioning VMs and installing Kubernetes..."
terraform apply -auto-approve

echo "==> Done. Cluster rebuilt from scratch."
