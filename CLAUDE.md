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

scripts/preflight.sh                             # read-only pre-deploy check
scripts/snapshot-baseline.sh                     # cold baseline snapshot, all 11 VMs
scripts/revert-baseline.sh --yes                 # roll the fleet back to it

packer/                                          # builds the VM template Terraform clones
```

Admin kubeconfig is left on **cp1** at `/tmp/admin.conf`.

### Running the cluster install by hand

`playbooks/setup-cluster.yml` **must** be run with `--limit 'k8s_cluster:etcd'`:

```bash
ansible-playbook -i inventory/hosts.ini playbooks/setup-cluster.yml \
  --limit 'k8s_cluster:etcd'
```

Its third play targets `groups['observer'][0]`, which is `localhost` — the
macOS control machine — and runs `apt install kubectl`. Without the limit the
run fails there. `deploy.sh cluster` applies the limit for this reason. The
side effect is that no kubeconfig is copied to the controller, so run
`kubectl` on cp1 with `KUBECONFIG=/etc/kubernetes/admin.conf`.

### Baseline snapshots

`scripts/snapshot-baseline.sh` powers the fleet down, snapshots all 11 VMs
cold, and brings it back up; `scripts/revert-baseline.sh` rolls every VM back
and restarts them in dependency order (etcd → control plane → workers).

Use them as the inter-scenario reset: reverting to an identical baseline is a
stronger guarantee than the fault-teardown sweep in `_health-check.yml`, which
can only undo faults it knows about. Between scenarios:

```bash
scripts/revert-baseline.sh --yes && ansible-playbook scenarios/sN/playbook.yml
```

The snapshots are deliberately **cold**. vCenter has no cross-VM consistency
group, so snapshotting 11 running VMs captures 11 different instants and a
5-member etcd cluster restored that way can come back with members at
different raft log positions — a silently inconsistent baseline every later
scenario would inherit. Powering off also avoids resuming with a stale clock,
which Kubernetes does not tolerate (cert validity, etcd leases, the
controller-manager lease).

`revert-baseline.sh` discards everything on the nodes since the snapshot —
pull results off with `scripts/aggregate-results.sh` first. It refuses to run
unless *every* VM has the named snapshot, since a partial rollback would split
the fleet across two states. Delta disks grow with each scenario, so re-take
the baseline periodically (`--replace`) rather than keeping one forever.

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
- `packer/` — builds the `ubuntu-24.04-template` vSphere template that
  `terraform/` clones. Several settings there are load-bearing for
  `terraform/modules/vm` (20 GB disk, pvscsi, BIOS firmware, vmxnet3); see
  `packer/README.md` before changing any of them.

See `README.md` for the quick start and `INFRASTRUCTURE.md` for the full
scenario index and host requirements.

## Conventions

- New scenarios follow the existing `scenarios/sN/playbook.yml` pattern and end
  by calling `scripts/check-invariants.sh` to emit a consistent
  `invariant_report.json`.
- Every scenario declares what its fault must observably do. Scenarios that
  inject through the `fault-inject` role get this for free (see
  `roles/fault-inject/defaults/main.yml`); scenarios that write their own
  iptables rules must write `{{ results_dir }}/scenario_meta.json` themselves,
  as S11 and S19 do. Without it a fault that misses its target still emits a
  full set of invariant verdicts describing an undisturbed cluster.
- Invariants are measured, never asserted. Before trusting a new check, run it
  against the baseline snapshot alone: if it does not come back PRESERVED, it
  is a broken detector. The calibration gate in `check-invariants.sh` enforces
  this, and `REVIEW.md` records the four defects that motivated it.
- New scenario tags must be registered in `playbooks/run-all-scenarios.yml`.
- Faults are injected and torn down per run — never leave iptables/tc rules or
  Toxiproxy toxics behind.
- `/results/`, `/report.html` and `/results.zip` are generated and gitignored.

## Known gotchas

- **A freshly cloned VM that refuses SSH (connection refused, but pings and
  shows a login prompt on the console) has lost the host-key race.** The
  template deletes `/etc/ssh/ssh_host_*` so clones do not share keys, and
  regeneration used to depend on cloud-init's `ssh` module, which finishes
  only ~0.5 s before sshd starts. On the first 11-VM fleet 4 nodes lost that
  race, and a reboot is a fresh coin flip each time (etcd4 needed three).
  `packer/provision/prepare-template.sh` now generates the keys from a
  `sysinit.target` unit plus `ExecStartPre` drop-ins on `ssh.service` and
  `ssh.socket`. **Any VM cloned from a template built before that fix is still
  affected** — rebuild the template rather than rebooting in a loop.
- `10.0.0.50` belongs to an unrelated VM on the management network, which is
  why `cp1` is `.49` and the range has holes at `.50` and `.59` (the API VIP).
- The control machine is macOS with **bash 3.2** — no `mapfile`/`readarray`,
  and BSD `sed` does not understand `\s`. Scripts in `scripts/` must work
  under it; use `awk` for field extraction.

## Uncommitted state

The tree is clean as of the `packer:`/`infra:` commits. `scripts/snapshot-baseline.sh`
and `scripts/revert-baseline.sh` are new and may still be untracked — ask
before staging. `REVIEW.md` at the repo root is untracked and belongs to a
separate review pass; do not edit or commit it.
