#!/usr/bin/env bash
# deploy.sh — provision the lab and install the cluster.
#
# Terraform and Ansible are separate tools with separate jobs:
#   1. Terraform provisions the VMs and writes inventory/hosts.ini
#   2. Ansible waits for SSH, then installs the Kubernetes cluster
#
# This script just runs the two in sequence. Run it from anywhere; it
# resolves its own location.
#
# Usage:
#   ./deploy.sh            provision VMs + install the cluster
#   ./deploy.sh vms        provision VMs only (Terraform), skip Ansible
#   ./deploy.sh cluster    install the cluster only (Ansible), skip Terraform
#                          — assumes the VMs already exist
#
# Requirements: terraform and ansible/ansible-playbook on PATH, and
# terraform/terraform.tfvars with the vCenter credentials.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_DIR"

STEP="${1:-all}"

run_terraform() {
  echo "==> Terraform: provisioning VMs"
  terraform -chdir=terraform init -input=false
  terraform -chdir=terraform apply -auto-approve
  echo "==> Terraform done — inventory written to inventory/hosts.ini"
}

run_ansible() {
  echo "==> Waiting for SSH on every cluster + etcd node (up to 10 min)"
  ansible -i inventory/hosts.ini k8s_cluster:etcd \
    -m wait_for_connection -a 'timeout=600'

  echo "==> Ansible: installing the Kubernetes cluster"
  # --limit skips the observer play; no observer VM is provisioned.
  ansible-playbook -i inventory/hosts.ini playbooks/setup-cluster.yml \
    --limit 'k8s_cluster:etcd'
  echo "==> Cluster install complete"
}

case "$STEP" in
  all)     run_terraform; run_ansible ;;
  vms)     run_terraform ;;
  cluster) run_ansible ;;
  *)
    echo "usage: $0 [all|vms|cluster]" >&2
    exit 2
    ;;
esac

echo "==> deploy.sh: $STEP finished."
