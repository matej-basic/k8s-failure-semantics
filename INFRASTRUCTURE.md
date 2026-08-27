# Infrastructure Requirements

## Host Allocation

The lab is **11 Linux VMs**, provisioned on VMware vSphere by Terraform
(`terraform/`) from an Ubuntu 24.04 template. The **observer** — the machine
you run Terraform and Ansible from — is your own workstation; it is *not* a
provisioned VM. See [`README.md`](README.md) and [`deploy.sh`](deploy.sh) for
the deploy flow.

### Host Layout

| Hostname | Role                    | vCPU | RAM  | Disk  | Mgmt IP   |
|----------|-------------------------|------|------|-------|-----------|
| cp1      | Control plane node 1    | 4    | 8 GB | 60 GB | 10.0.0.49 |
| cp2      | Control plane node 2    | 4    | 8 GB | 60 GB | 10.0.0.51 |
| cp3      | Control plane node 3    | 4    | 8 GB | 60 GB | 10.0.0.52 |
| worker1  | Worker node 1           | 4    | 8 GB | 60 GB | 10.0.0.53 |
| worker2  | Worker node 2           | 4    | 8 GB | 60 GB | 10.0.0.54 |
| worker3  | Worker node 3           | 4    | 8 GB | 60 GB | 10.0.0.55 |
| etcd1    | Dedicated etcd member 1 | 2    | 4 GB | 40 GB | 10.0.0.56 |
| etcd2    | Dedicated etcd member 2 | 2    | 4 GB | 40 GB | 10.0.0.57 |
| etcd3    | Dedicated etcd member 3 | 2    | 4 GB | 40 GB | 10.0.0.58 |
| etcd4    | Dedicated etcd member 4 | 2    | 4 GB | 40 GB | 10.0.0.60 |
| etcd5    | Dedicated etcd member 5 | 2    | 4 GB | 40 GB | 10.0.0.61 |

**Total: 11 VMs.** The API VIP is `10.0.0.59` — it sits between the etcd
ranges, which is why etcd4/etcd5 take `.60`/`.61`.

The whole topology is defined by the `vm_specs` map in `terraform/main.tf` —
the single source of truth. Inventory generation (`outputs.tf`) and the etcd
CA / peer-cert / `--initial-cluster` config all derive from it, so changing
the member count means editing only that map.

### Why a Dedicated etcd Cluster?

Scenarios S4 (clock skew), S8 (partition + storage lag), S17 (compaction gap)
and S19 (split quorum) require direct manipulation of etcd members
independently of the control plane. Co-located etcd (the kubeadm default)
makes that impossible to do cleanly — a dedicated etcd cluster gives full
surgical control.

The cluster has **5 etcd members** so S19 can perform a meaningful 3/2
majority/minority quorum split (minority etcd1+etcd2, majority
etcd3+etcd4+etcd5). Three members are sufficient for every other scenario; to
run with three, drop etcd4/etcd5 from the `vm_specs` map.

### Networking Requirements

- All VMs on the same L2 network (or routable L3) — a /24 is fine.
- Each VM has two NICs: a management NIC (`10.0.0.x`) and a pod-network NIC
  (`192.168.200.x`, same host octet) carrying the Kubernetes pod/service
  traffic for Calico.
- The observer needs SSH access to every VM as the `ansible` user — the SSH
  key and passwordless sudo are baked into the VM template.
- No firewall between hosts initially — iptables rules are injected by the
  fault scenarios and torn down after each run.

### IP Layout

Management network (first NIC). Each VM gets the same host octet on the pod
network (`192.168.200.x`):

```
cp1      10.0.0.49      worker1  10.0.0.53      etcd1  10.0.0.56
cp2      10.0.0.51      worker2  10.0.0.54      etcd2  10.0.0.57
cp3      10.0.0.52      worker3  10.0.0.55      etcd3  10.0.0.58
                                                etcd4  10.0.0.60
API VIP  10.0.0.59                              etcd5  10.0.0.61
```

Override the network prefixes in `terraform/terraform.tfvars` and the per-VM
octets in the `vm_specs` map if your network differs.

## Software Prerequisites (installed by the Ansible `common` role)

- containerd
- kubeadm, kubelet, kubectl
- etcd + etcdctl (external 5-member cluster, installed by the `k8s-install` role)
- crictl (CRI debug client — used by the metrics-collection role)
- tc (iproute2), iptables, ipset
- Toxiproxy (etcd latency injection)
- stress-ng (memory-pressure scenarios)
- chrony (clock-skew scenarios)
- jq, curl, python3

## Cluster Configuration

- Kubernetes version: 1.36.x
- CNI: Calico (NetworkPolicy support for validation)
- etcd: external, 5-node cluster
- High-availability control plane: three API servers behind a keepalived
  virtual IP (`10.0.0.59`)

## Reset Between Scenarios

Each scenario playbook:
1. Verifies the cluster is clean and all invariants hold (pre-flight)
2. Injects the fault
3. Collects observations for a configurable window
4. Tears down the fault
5. Waits for convergence
6. Records the post-fault state

Between scenarios, `run-all-scenarios.yml` runs the inter-scenario health
check (`playbooks/_health-check.yml`), which clears any residual faults and
waits for the cluster to settle. A full cluster reset (kubeadm reset + reinit)
is available via `playbooks/reset-cluster.yml` for cases where a scenario
leaves the cluster in an irrecoverable state.
