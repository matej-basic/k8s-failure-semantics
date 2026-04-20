# Infrastructure Requirements

## Physical Host Allocation

You need **9 physical Linux hosts** (or VMs on dedicated hardware). All hosts should
run Ubuntu 22.04 LTS or Rocky Linux 9.

### Host Layout

| Hostname         | Role                        | Min CPU | Min RAM | Min Disk |
|------------------|-----------------------------|---------|---------|----------|
| cp1              | Control plane node 1        | 4 cores | 8 GB    | 60 GB    |
| cp2              | Control plane node 2        | 4 cores | 8 GB    | 60 GB    |
| cp3              | Control plane node 3        | 4 cores | 8 GB    | 60 GB    |
| worker1          | Worker node 1               | 4 cores | 8 GB    | 60 GB    |
| worker2          | Worker node 2               | 4 cores | 8 GB    | 60 GB    |
| worker3          | Worker node 3               | 4 cores | 8 GB    | 60 GB    |
| etcd1            | Dedicated etcd member 1     | 2 cores | 4 GB    | 40 GB    |
| etcd2            | Dedicated etcd member 2     | 2 cores | 4 GB    | 40 GB    |
| etcd3            | Dedicated etcd member 3     | 2 cores | 4 GB    | 40 GB    |
| observer         | Ansible controller + metrics| 4 cores | 8 GB    | 100 GB   |

**Total: 10 hosts** (9 cluster + 1 observer/controller)

### Why a Dedicated etcd Cluster?

Scenarios S4 (clock skew), S8 (partition + storage lag), S17 (compaction gap),
and S19 (split quorum) require direct manipulation of etcd members independently
of the control plane. Co-located etcd (the kubeadm default) makes this impossible
to do cleanly. A dedicated 3-node etcd cluster gives you full surgical control.

For S19 (split quorum), you can optionally add etcd4 and etcd5 to make a 5-member
cluster, which allows a meaningful 3/2 split. This is optional — 3 nodes are
sufficient for all other scenarios.

### Networking Requirements

- All hosts on the same L2 network (or routable L3) — a /24 is fine.
- Each host needs a second network interface (can be a VLAN or a second NIC)
  for the Kubernetes pod/service network. This is used by Calico/Flannel.
- The observer host needs SSH access to all other hosts as root (or a user
  with passwordless sudo).
- No firewall between hosts initially — iptables rules are injected by the
  fault scenarios and torn down after each run.

### Suggested IP Layout (adjust to your network)

```
observer:  192.168.100.10
cp1:       192.168.100.11
cp2:       192.168.100.12
cp3:       192.168.100.13
worker1:   192.168.100.21
worker2:   192.168.100.22
worker3:   192.168.100.23
etcd1:     192.168.100.31
etcd2:     192.168.100.32
etcd3:     192.168.100.33
```

## Software Prerequisites (installed by the common role)

- containerd
- kubeadm, kubelet, kubectl
- etcdctl
- tc (iproute2)
- iptables
- Toxiproxy (for etcd latency injection)
- stress-ng (for memory pressure scenarios)
- Prometheus + node-exporter (for metrics)
- jq, curl, python3

## Cluster Configuration

- Kubernetes version: 1.29.x (stable)
- CNI: Calico (gives you NetworkPolicy support for validation)
- etcd: external, 3-node cluster (5-node optional for S19)
- High-availability control plane: stacked API servers behind a VIP
  (keepalived on cp1/cp2/cp3) or a dedicated load balancer on the observer host
- Metrics: Prometheus scraping all node-exporters + kube-state-metrics

## Reset Between Scenarios

Each scenario playbook:
1. Verifies the cluster is clean and all invariants hold (pre-flight)
2. Injects the fault
3. Collects observations for a configurable window
4. Tears down the fault
5. Waits for convergence
6. Records the post-fault state
7. Optionally resets the cluster to baseline

A full cluster reset (kubeadm reset + reinit) is available via
`playbooks/reset-cluster.yml` for cases where a scenario leaves the
cluster in an irrecoverable state.
