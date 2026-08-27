# Kubernetes Failure Semantics — Experiment Suite

Ansible-based fault injection and measurement framework for the paper
*"Failure Semantics Without Global State: Observer-Relative Failures in Kubernetes"*.

---

## Quick Start

Terraform provisions the VMs; Ansible installs the cluster on them. The two
tools are kept separate — `deploy.sh` runs them in sequence.

### Step 1 — Prerequisites

- **Terraform ≥ 1.5** and **Ansible** on your own machine. That machine is the
  observer / controller — no observer VM is provisioned.
- A VMware vSphere environment with an `ubuntu-24.04-template` VM template
  carrying the `ansible` user, your SSH public key, Python 3, and passwordless
  sudo.
- `terraform/terraform.tfvars` — copy `terraform/terraform.tfvars.example` and
  fill in the vCenter connection details.

### Step 2 — Deploy the lab

```bash
cd k8s-failure-semantics
./deploy.sh
```

`deploy.sh` provisions 11 VMs (3 control-plane, 3 worker, 5 etcd), writes
`inventory/hosts.ini`, waits for SSH, then installs containerd, kubeadm, the
external 5-member etcd cluster, Toxiproxy, stress-ng, and the HA Kubernetes
control plane (~20 minutes total). The admin kubeconfig is left on **cp1** at
`/tmp/admin.conf`.

Either step can also be run on its own:

```bash
./deploy.sh vms        # Terraform only — provision/refresh the VMs
./deploy.sh cluster    # Ansible only  — (re)install the cluster on existing VMs
```

### Step 3 — Verify the cluster

```bash
# Should show 6 Ready nodes (3 control-plane + 3 worker)
ansible -i inventory/hosts.ini cp1 -m shell -a \
  "KUBECONFIG=/etc/kubernetes/admin.conf kubectl get nodes"

# Should show 5 healthy etcd members
ansible -i inventory/hosts.ini etcd[0] -m shell -a \
  "ETCDCTL_API=3 etcdctl --endpoints=... endpoint health"
```

### Step 4 — Run a single scenario

```bash
# Example: run S2 (asymmetric worker isolation)
ansible-playbook -i inventory/hosts.ini scenarios/s2/playbook.yml \
  -e results_base=$(pwd)/results

# Results are written to results/s2/<timestamp>/
```

### Step 5 — Run all scenarios

```bash
# Run everything in sequence (S1–S28; budget 4–5 hours)
ansible-playbook -i inventory/hosts.ini playbooks/run-all-scenarios.yml \
  -e results_base=$(pwd)/results

# Run a subset by tag
ansible-playbook -i inventory/hosts.ini playbooks/run-all-scenarios.yml \
  --tags "s1,s2,s11" -e results_base=$(pwd)/results

# Long unattended runs — detach so they survive a closed terminal
scripts/run-sweep-detached.sh
```

### Step 6 — Inspect results

Each scenario writes a timestamped directory of snapshot JSON plus an
`invariant_report.json`:

```
results/
  s1/20260520_143012/
    snapshot_pre_fault.json
    snapshot_t_plus_30.json
    ...
    invariant_report.json
  s2/ ...
  aggregate_report.json          ← cross-scenario heatmap + timing
```

Build a single self-contained HTML viewer over them:

```bash
scripts/aggregate-results.sh results > results/aggregate_report.json
scripts/build-report.sh results report.html
open report.html
```

`report.html` has an overview heatmap, a per-invariant **Findings** page, a
scenario/invariant **Reference**, and per-snapshot drill-down — no server, no
CDN, shareable on its own.

### Step 7 — Reset or rebuild

```bash
# Reset the cluster in place if a scenario left it broken
ansible-playbook -i inventory/hosts.ini playbooks/reset-cluster.yml

# Or tear the VMs down and rebuild from scratch
terraform -chdir=terraform destroy
./deploy.sh
```

---

## Scenario Index

| ID  | Name                                      | Fault type           | Key invariants |
|-----|-------------------------------------------|----------------------|----------------|
| S1  | Symmetric control-plane partition         | network_partition    | I1, I3         |
| S2  | Asymmetric worker isolation               | network_asymmetric   | I1, I2, I3     |
| S3  | etcd write-latency degradation            | etcd_latency         | I5             |
| S4  | Clock skew on control-plane node          | clock_skew           | I1, I3         |
| S5  | API disruption under multiple controllers | network_partition    | I1, I5         |
| S6  | Repeat-run recovery study                 | network_asymmetric   | I4             |
| S8  | Partition + storage lag (composed)        | composed             | I1, I2, I5     |
| S11 | Kubelet partition / pod lifecycle         | network_partition    | I1, I2, I3     |
| S12 | Leader election storm                     | network_flap         | I1             |
| S14 | Stale informer cache                      | etcd_latency         | I5             |
| S15 | Graceful termination race                 | pod lifecycle        | I2             |
| S17 | etcd compaction + watch history gap       | etcd_compact         | I5             |
| S18 | Node pressure eviction race               | memory_pressure      | I1             |
| S19 | Split etcd quorum                         | network_partition    | I1, I5         |

### Gray-failure scenarios (S20–S28)

S1–S19 cover clean crash-stop and timing failures. Production clusters mostly
fail *gray* — the node stays Ready while nothing works — and these sample that
region. Added from `REVIEW.md` section 3.

| ID  | Name                                      | Fault type                | Key invariants |
|-----|-------------------------------------------|---------------------------|----------------|
| S20 | Pod-network partition, mgmt net intact    | pod_network_partition     | I2 †           |
| S21 | Keepalived VIP split-brain                | vrrp_vip_split            | I1 †           |
| S22 | containerd / kubelet freeze (SIGSTOP)     | process_freeze            | † (omission)   |
| S23 | etcd NOSPACE                              | etcd_nospace              | I5, I6, I10 †  |
| S24 | Admission webhook timeout (Fail vs Ignore)| admission_webhook_timeout | † (see note)   |
| S25 | API priority-and-fairness starvation      | apf_priority_starvation   | † (see note)   |
| S26 | Node object deleted, kubelet alive        | node_object_deleted       | I1 †           |
| S27 | Negative / substrate clock skew           | clock_skew_negative       | I1, I3 †       |
| S28 | Stale etcd member rejoining after compact | etcd_stale_member         | I5 †           |

**† The invariant mapping for these is provisional.** Each of these faults
deliberately leaves the substrate looking healthy — every node Ready, etcd
quorum intact, all API servers answering — which is precisely what makes them
interesting and also what the current invariant set cannot see. Several cannot
yet certify their own efficacy through `check-invariants.sh`, because every
efficacy signal is derived from `snapshot_*.json` and these faults leave that
schema unchanged. They carry scenario-local evidence files instead, and each
scenario header names the signal that would close the gap. Treat the column
above as intent, not as a claim about what the checker currently reports.

Two of them have a second variant that `run-all-scenarios.yml` does **not**
run, because the variant is a play var the scenario defines itself and cannot
be overridden from an `import_playbook`:

```bash
ansible-playbook -i inventory/hosts.ini scenarios/s22/playbook.yml -e s22_variant=kubelet
ansible-playbook -i inventory/hosts.ini scenarios/s27/playbook.yml -e s27_variant=substrate
```

**S28 runs last and mutates etcd membership** — it removes a member, wipes its
data directory and re-adds it as a learner. Take a baseline snapshot before it
and revert afterwards:

```bash
scripts/snapshot-baseline.sh          # cold snapshot of all 11 VMs
scripts/revert-baseline.sh --yes      # roll the fleet back
```

None of S20–S28 has been executed yet. They are syntax-checked and reasoned
about, not exercised.

---

## Key Variables

Override any of these on the command line with `-e`:

```bash
# Change fault duration
ansible-playbook ... scenarios/s2/playbook.yml -e fault_duration=120

# Change observation window
ansible-playbook ... scenarios/s2/playbook.yml -e observation_window=300

# Change results directory
ansible-playbook ... -e results_base=/data/my-results

# Change S6 repeat count
ansible-playbook ... scenarios/s6/playbook.yml -e repeat_count=10
```

---

## Invariant Verdicts

Each scenario produces an `invariant_report.json`. Eight invariants are
evaluated (I7 and I8 do not exist; the numbering follows the paper's drafts):

| ID  | Name                            | What a violation means |
|-----|---------------------------------|------------------------|
| I1  | Exclusive authority             | One pod identity ran on two nodes at once |
| I2  | Reachability publication        | Endpoints published backends that were not serving |
| I3  | Failure declaration consistency | A node the control plane stopped vouching for still ran containers |
| I4  | Recovery coherence              | Repeated runs of the same fault converged to different states |
| I5  | Observation-action consistency  | Two API servers disagreed, or one served a provably stale read |
| I6  | Watch progress monotonicity     | An observed revision went backwards |
| I9  | Quorum continuity               | etcd lost majority, or members disagreed on leader / raft term |
| I10 | Reconciliation termination      | New warnings kept appearing after the fault was removed |

Per-invariant verdicts:

- `PRESERVED` — invariant held in every snapshot
- `VIOLATED` — invariant was broken in at least one snapshot
- `INSUFFICIENT_DATA` — the run does not contain the evidence this invariant
  needs (I4 outside S6; I5 for runs recorded before per-API-server views)
- `DETECTOR_INVALID` — the invariant was **already violated in the baseline
  snapshot, before any fault was injected**. The detector is at fault, not the
  cluster, and the verdict is disqualified for the whole run. The measured
  verdict is kept alongside it as `measured_verdict`.

Each report also carries a run-level `run_validity`:

- `OK` — the fault produced an observable change against the baseline
- `FAULT_INEFFECTIVE` — it did not. The run measured an undisturbed cluster,
  so its invariant verdicts describe nothing and `aggregate-results.sh`
  excludes them from the rates. What each fault must observably do is declared
  in `scenario_meta.json`, written by the `fault-inject` role (defaults per
  fault type in `roles/fault-inject/defaults/main.yml`, overridden per
  scenario with `efficacy_require` / `efficacy_target_node`).

The `aggregate_report.json` collects all verdicts into the heatmap
described as Figure 7 in the paper.

> **The results committed before Aug 27 2026 predate these checks.** See
> [`REVIEW.md`](REVIEW.md) — the May 2026 sweep's I2, I5 and I6 columns are
> artifacts of defects in the checker, not measurements. Re-run the suite
> before citing any figure from it.

---

## Adding New Scenarios

1. Create `scenarios/sN/playbook.yml` following the pattern of existing scenarios.
2. Add the scenario tag to `playbooks/run-all-scenarios.yml`.
3. Run `scripts/check-invariants.sh` at the end of your playbook to produce
   a consistent invariant report.

---

## Troubleshooting

**Cluster won't come up after reset:**
```bash
# Check etcd health first
ansible -i inventory/hosts.ini etcd -m shell \
  -a "systemctl status etcd"

# Check kubeadm init logs on cp1
ansible -i inventory/hosts.ini cp1 -m shell \
  -a "journalctl -u kubelet --since '10 minutes ago' | tail -50"
```

**Toxiproxy not working:**
```bash
# Check Toxiproxy is running on etcd nodes
ansible -i inventory/hosts.ini etcd -m shell \
  -a "systemctl status toxiproxy"

# List active toxics
ansible -i inventory/hosts.ini etcd[0] -m shell \
  -a "toxiproxy-cli inspect etcd-proxy"
```

**iptables rules not cleaning up:**
```bash
# Emergency teardown on all hosts
ansible-playbook -i inventory/hosts.ini playbooks/run-all-scenarios.yml \
  --tags never -e fault_type=teardown
# Or manually:
ansible -i inventory/hosts.ini k8s_cluster:etcd -m shell \
  -a "iptables -F && iptables -X"
```
