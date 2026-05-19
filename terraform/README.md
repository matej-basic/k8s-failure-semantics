# Terraform — VM provisioning + cluster bootstrap

Provisions the 9 VMs from [`../INFRASTRUCTURE.md`](../INFRASTRUCTURE.md) on
VMware vSphere (cloned from an Ubuntu 24.04 template) and, in the same
`terraform apply`, installs the Kubernetes cluster on top via Ansible.

The observer / Ansible-controller host is **not** created — you run Ansible
(and Terraform) from your own machine.

## What gets built

| Group         | VMs                  | vCPU | RAM  | Disk  | Mgmt IP          |
|---------------|----------------------|------|------|-------|------------------|
| control_plane | cp1, cp2, cp3        | 4    | 8 GB | 60 GB | 10.0.0.50–52     |
| workers       | worker1–3            | 4    | 8 GB | 60 GB | 10.0.0.53–55     |
| etcd          | etcd1–3              | 2    | 4 GB | 40 GB | 10.0.0.56–58     |

Each VM has two NICs: a management NIC (`10.0.0.x`) and a pod-network NIC
(`192.168.200.x`) for Calico. The API VIP defaults to `10.0.0.59`.

## Prerequisites

- Terraform ≥ 1.5 and the `ansible` CLI on the machine you run this from.
- An `ubuntu-24.04-template` in vSphere with the `ansible` user + your SSH key,
  Python 3, and passwordless sudo.
- `terraform.tfvars` — copy `terraform.tfvars.example` and fill in the vCenter
  password.

## Deploy everything (one command)

```bash
cd terraform
terraform init
terraform apply
```

`apply` provisions the VMs, writes `../inventory/hosts.ini`, waits for SSH,
and runs `playbooks/setup-cluster.yml`. The admin kubeconfig is left on **cp1**
at `/tmp/admin.conf` (no observer VM exists to copy it to).

## Redeploy from scratch (do it again)

The lab is designed for repeated clean rebuilds:

```bash
cd terraform
terraform destroy        # tear down the 9 VMs
terraform apply          # fresh VMs + fresh cluster
```

Or use the helper, which wraps destroy + apply:

```bash
scripts/redeploy-cluster.sh
```

## VMs only, Ansible by hand

```bash
terraform apply -var run_ansible=false
ansible-playbook -i ../inventory/hosts.ini ../playbooks/setup-cluster.yml \
  --limit 'k8s_cluster:etcd'
```

## ⚠️ Stale state from the original project

This directory was copied from a vSphere demo that managed 32 unrelated VMs.
The original `terraform.tfstate` was **removed** so `apply` does not try to
destroy that other project's VMs. If you restore an old state file by mistake,
delete it and re-`terraform init` before applying.
