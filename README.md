# Kubernetes Failure Semantics — Experiment Suite

Ansible-based fault injection and measurement framework for the paper
*"Failure Semantics Without Global State: Observer-Relative Failures in Kubernetes"*.

---

## Quick Start

### Step 1 — Provision hosts

Stand up 10 Linux hosts (Ubuntu 22.04 LTS recommended) as described in
`INFRASTRUCTURE.md`. Configure passwordless SSH from the observer host to all
others.

### Step 2 — Configure inventory

Edit `inventory/hosts.ini` and replace the IP addresses with your actual host IPs.

```ini
cp1 ansible_host=YOUR_CP1_IP
cp2 ansible_host=YOUR_CP2_IP
...
```

### Step 3 — Bootstrap the cluster

From the **observer host**, run:

```bash
cd k8s-failure-semantics

# Install prerequisites and build the cluster (~15 minutes)
ansible-playbook -i inventory/hosts.ini playbooks/setup-cluster.yml
```

This installs containerd, kubeadm, etcd, Toxiproxy, stress-ng, node_exporter,
and Prometheus on all hosts, then bootstraps the HA Kubernetes cluster.

### Step 4 — Verify the cluster

```bash
# Should show 6 Ready nodes
kubectl get nodes

# Should show 3 healthy etcd members
ansible -i inventory/hosts.ini etcd[0] -m shell -a \
  "ETCDCTL_API=3 etcdctl --endpoints=... endpoint health"
```

### Step 5 — Run a single scenario

```bash
# Example: run S2 (asymmetric worker isolation)
ansible-playbook -i inventory/hosts.ini scenarios/s2/playbook.yml

# Results are written to /opt/k8s-results/s2/<timestamp>/
```

### Step 6 — Run all scenarios

```bash
# Run everything in sequence (takes 2–3 hours)
ansible-playbook -i inventory/hosts.ini playbooks/run-all-scenarios.yml

# Run a subset by tag
ansible-playbook -i inventory/hosts.ini playbooks/run-all-scenarios.yml \
  --tags "s1,s2,s11"
```

### Step 7 — Inspect results

Results are written to `/opt/k8s-results/` on the observer host:

```
/opt/k8s-results/
  s1/
    20240420_143012/
      snapshot_pre_fault.json
      snapshot_t_plus_30.json
      snapshot_t_plus_60.json
      ...
      invariant_report.json
  s2/
    ...
  aggregate_report.json          ← cross-scenario heatmap + timing
```

### Step 8 — Reset the cluster

If a scenario leaves the cluster in a broken state:

```bash
ansible-playbook -i inventory/hosts.ini playbooks/reset-cluster.yml
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

Each scenario produces an `invariant_report.json` with verdicts:

- `PRESERVED` — invariant held throughout all snapshots
- `VIOLATED` — invariant was broken in at least one snapshot
- `INSUFFICIENT_DATA` — not enough snapshots to evaluate (mainly I4)

The `aggregate_report.json` collects all verdicts into the heatmap
described as Figure 7 in the paper.

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
