# Terraform — VM provisioning

Provisions the 11 lab VMs on VMware vSphere, cloned from an Ubuntu 24.04
template. Terraform builds **infrastructure only** — it does not install
Kubernetes. The cluster is installed separately by Ansible; see
[`../deploy.sh`](../deploy.sh), which runs both steps in sequence.

The observer / Ansible-controller host is **not** created — you run Terraform
and Ansible from your own machine.

## What gets built

| Group         | VMs        | vCPU | RAM  | Disk  | Mgmt IP             |
|---------------|------------|------|------|-------|---------------------|
| control_plane | cp1–cp3    | 4    | 8 GB | 60 GB | 10.0.0.49, .51–52   |
| workers       | worker1–3  | 4    | 8 GB | 60 GB | 10.0.0.53–55        |
| etcd          | etcd1–5    | 2    | 4 GB | 40 GB | 10.0.0.56–58, 60–61 |

11 VMs total. Each has two NICs: a management NIC (`10.0.0.x`) and a
pod-network NIC (`192.168.200.x`) for Calico. The API VIP defaults to
`10.0.0.59` — which is why the two extra etcd members take `.60` and `.61`.

The etcd cluster has **5 members** (not 3) so S19 (split quorum) can do a
meaningful 3/2 majority/minority split. The whole topology is defined by the
`vm_specs` map in `main.tf` — that map is the single source of truth; the
inventory generation and the etcd cert/peer config all derive from it.

## Prerequisites

- Terraform ≥ 1.5.
- An `ubuntu-24.04-template` in vSphere with the `ansible` user + your SSH key,
  Python 3, and passwordless sudo.
- `terraform.tfvars` — copy `terraform.tfvars.example` and fill in the vCenter
  password.

## Usage

Terraform provisions the VMs and writes `../inventory/hosts.ini` — the
inventory describing them, which is the single hand-off artifact Ansible
consumes. It does **not** install the cluster.

```bash
# From the repo root — provision VMs, then install the cluster:
./deploy.sh

# Terraform step only (equivalent forms):
./deploy.sh vms
terraform -chdir=terraform apply
```

## Redeploy from scratch

The lab is designed for repeated clean rebuilds:

```bash
terraform -chdir=terraform destroy   # tear down the 11 VMs
./deploy.sh                          # fresh VMs + fresh cluster
```

## ⚠️ Stale state from the original project

This directory was copied from a vSphere demo that managed unrelated VMs. The
original `terraform.tfstate` was **removed** so `apply` does not try to destroy
that other project's VMs. If you restore an old state file by mistake, delete
it and re-`terraform init` before applying.
