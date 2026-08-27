# CLAUDE.md — k8s-failure-semantics

Shared conventions, lab hardware and git rules live in `../CLAUDE.md`.

## Project

Ansible-based fault injection and measurement framework for the paper
*"Failure Semantics Without Global State: Observer-Relative Failures in
Kubernetes"*. Terraform provisions 11 vSphere VMs (3 control-plane, 3 worker,
5 etcd); Ansible installs an HA cluster on them, injects faults, and records
invariant verdicts per scenario. The observer is the machine running Ansible —
no observer VM is provisioned.

## Commands

```bash
./deploy.sh              # Terraform + Ansible, full lab (~20 min)
./deploy.sh vms          # Terraform only — provision/refresh VMs
./deploy.sh cluster      # Ansible only — (re)install on existing VMs

ansible-playbook playbooks/run-all-scenarios.yml
ansible-playbook scenarios/sN/playbook.yml       # single scenario
scripts/check-invariants.sh                      # emits invariant_report.json
scripts/aggregate-results.sh
scripts/build-report.sh                          # generates report.html
```

Admin kubeconfig is left on **cp1** at `/tmp/admin.conf`.

## Layout

- `inventory/` — `hosts.ini` (host IPs, k8s/etcd versions, API VIP) and
  `inventory/group_vars/`.
- `playbooks/` — `setup-cluster.yml`, `reset-cluster.yml`,
  `run-all-scenarios.yml`, `_health-check.yml`.
- `roles/` — `common`, `k8s-install` (incl. keepalived for the API VIP),
  `fault-inject`, `metrics-collect`.
- `scenarios/sN/` — one fault scenario each, run via `playbook.yml`.
- `terraform/` — host provisioning. State and `*.tfvars` are gitignored;
  copy `terraform.tfvars.example` to get started.

See `README.md` for the quick start and `INFRASTRUCTURE.md` for the full
scenario index and host requirements.

## Conventions

- New scenarios follow the existing `scenarios/sN/playbook.yml` pattern and end
  by calling `scripts/check-invariants.sh` to emit a consistent
  `invariant_report.json`.
- New scenario tags must be registered in `playbooks/run-all-scenarios.yml`.
- Faults are injected and torn down per run — never leave iptables/tc rules or
  Toxiproxy toxics behind.
- `/results/`, `/report.html` and `/results.zip` are generated and gitignored.

## Uncommitted state

`group_vars/all.yml` was moved to `inventory/group_vars/` but the move is not
staged, so git shows it as deleted. `inventory/hosts.ini` is also modified.
Both are intentional working state — ask before staging.
