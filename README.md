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

`run_id` stamps every artefact path, so it has to be fixed once for the whole
invocation. Export it, or pass `-e run_id=...`; a run with neither set stops
immediately rather than scattering its results across directories (REVIEW.md
D7). The sweep and repeat harnesses set it for you.

```bash
# Example: run S2 (asymmetric worker isolation)
export K8SFS_RUN_ID=$(date +%Y%m%d_%H%M%S)
ansible-playbook -i inventory/hosts.ini scenarios/s2/playbook.yml \
  -e results_base=$(pwd)/results

# Results are written to results/s2/$K8SFS_RUN_ID/
```

### Step 5 — Run all scenarios

```bash
# Run everything in sequence (23 scenarios, S1–S28 with gaps; budget 4–5 hours)
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

For a *repeatable* reset, roll the fleet back to a snapshot instead of trying
to undo the fault:

```bash
scripts/snapshot-baseline.sh          # cold snapshot of all 11 VMs
scripts/snapshot-baseline.sh --list   # show what exists
scripts/revert-baseline.sh --yes      # roll every VM back to it
```

Restoring an identical starting state is a stronger guarantee than the
fault-teardown sweep in `playbooks/_health-check.yml`, which can only remove
faults it knows about. The snapshots are **cold** on purpose — vCenter has no
cross-VM consistency group, so snapshotting 11 running VMs captures 11
different instants and a 5-member etcd cluster restored that way can come back
with members at different raft log positions. `revert-baseline.sh` discards
everything on the nodes since the snapshot, results included, so pull those off
with `scripts/aggregate-results.sh` first. Both scripts read the vCenter
password from `terraform/terraform.tfvars` and never print it.

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

**The IDs are not dense — there is no S7, S9, S10, S13 or S16.** With the
gray-failure scenarios below the suite is 23 scenarios, not 28. See
[Why the numbering has gaps](#why-the-numbering-has-gaps).

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
```

### Repeating a scenario

Repetition is **not** one of those variables. This file used to advertise
`-e repeat_count=10` for S6; it never worked. S6's iteration count is the
number of `import_playbook:` entries in `scenarios/s6/playbook.yml`, which
Ansible resolves at parse time before any variable exists, and `repeat_count`
only sized a directory-creation loop. The playbook now asserts the two agree,
so the override fails loudly instead of looking as though it did something.

Use the repetition harness (`scripts/repeat-scenario.sh`, added in 57da7bc)
instead — it works for every scenario, not just S6:

```bash
scripts/repeat-scenario.sh s6 -n 10                  # S6, ten iterations
scripts/repeat-scenario.sh s1:5 s2:5 s20:3           # per-scenario counts
scripts/repeat-scenario.sh --plan -n 5 --detached    # every registered scenario
scripts/repeat-scenario.sh s2 -n 5 -N                # print the commands, contact nothing
```

Each iteration is a separate `ansible-playbook` process writing
`results/<sN>/<run_id>/run_<K>/` — the layout S6 has always produced, so
`check-invariants.sh`, `aggregate-results.sh` and `build-report.sh` read it
unchanged, one failed iteration does not abort the batch, and output streams
live. The unit of repetition is `scenarios/<sN>/run-one.yml` where that file
exists (only S6) and the scenario's `playbook.yml` otherwise; for the latter
the harness pins `results_dir` as an extra-var, which also makes the S22 and
S27 second variants runnable in a batch via `--extra "-e s22_variant=kubelet"`.

The default is **N=1** — a single pass of the 23 scenarios already takes
hours. `--plan` takes its targets from the `tags:` entries in
`playbooks/run-all-scenarios.yml` and its counts from
`scenario_repeat_default` / `scenario_repeat_counts` in
`inventory/group_vars/all.yml` (only S6 carries a non-default count, 5).
`--help` documents the rest: `--resume`, `--start-at`, `--stop-on-error`,
`--health-check` / `--no-health-check`, `--no-invariants`, `--detached`.

---

## Invariant Verdicts

Each scenario produces an `invariant_report.json`. Eight invariants are
evaluated. Each row below is a `check_iN` function of the same name in
[`scripts/check-invariants.sh`](scripts/check-invariants.sh), which is the
authority on what is actually measured — the descriptions here are taken from
that code, not from the paper's prose.

| ID  | Name (function) | A violation means | Evidence it reads |
|-----|-----------------|-------------------|-------------------|
| I1  | Exclusive authority (`check_i1`) | the same pod identity (`namespace/name`) had a `CONTAINER_RUNNING` container on two nodes at the same instant | `.nodes[].containers` — node-local `crictl` output gathered by SSH to each kubelet, deliberately not the API server's pod list, which cannot see a partitioned node |
| I2  | Reachability publication (`check_i2`) | the published endpoint set did not match what serves: an endpoint object carried `notReadyAddresses`, or a probe of `nginx-stateless` failed while endpoints were still published | `.control_plane.endpoint_states[]` and `.external_probe.httpCode`. A `null` httpCode means the probe could not run and is skipped as missing evidence; a probe that ran and failed still counts |
| I3  | Failure declaration consistency (`check_i3`) | the control plane stopped vouching for a node — Ready ≠ `True`, or an unreachable / not-ready `NoExecute` taint — while that node still ran containers. The report distinguishes `declared_failed` (Ready=False or a taint) from `declared_uncertain` (Ready=Unknown) | `.control_plane.node_conditions[]` (status and `taints`) paired with `.nodes[].containers` |
| I4  | Recovery coherence (`check_i4`) | repeated runs of the same fault settled on different post-fault states (distinct controller-manager lease holders across the iterations) | `.control_plane.controller_manager_lease.holder` across the `post_*` snapshots of a multi-iteration run. Cross-run by construction: every scenario except top-level S6 returns `INSUFFICIENT_DATA`, and the real comparison is `recovery_variance_s6` in `aggregate-results.sh` |
| I5  | Observation-action consistency (`check_i5`) | two reachable API servers disagreed about the same node's Ready status at the same instant, or one served a `resourceVersion=0` (watch-cache) read more than `I5_STALE_RV_THRESHOLD` revisions (default 100) behind a linearizable read of the same collection | `.observers[]` — one entry per control-plane node, each queried on its own address so the keepalived VIP cannot redirect the question. Runs without `.observers[]` return `INSUFFICIENT_DATA` |
| I6  | Watch progress monotonicity (`check_i6`) | the observed etcd revision decreased between two consecutive snapshots | `.etcd.current_revision`, compared in chronological order (`.snapshot_index`, falling back to `.timestamp`) — never filename order |
| I9  | Quorum continuity (`check_i9`) | fewer than ⌈n/2⌉+1 etcd members answered an endpoint-status query, or the members that did answer disagreed about the leader or the raft term | `.etcd.member_status[]` (`.Status.leader`, `.Status.raftTerm`) against `.etcd.expected_members`, taken from the inventory; the largest member count observed is a fallback only, for runs recorded before that field existed |
| I10 | Reconciliation termination (`check_i10`) | new `(involvedObject.name, reason)` Warning pairs were still appearing between the first and the last post-fault snapshot — controllers never converged | `.control_plane.warning_events[]` in the first and last `post_*` snapshot, compared as a set difference (the 1 h event TTL makes raw counts misleading). Fewer than two post-fault snapshots → `INSUFFICIENT_DATA` |

> The header comment at the top of `check-invariants.sh` still says the script
> "evaluates the five paper invariants" and lists only I1–I5. That comment is
> stale — it predates commit 74c62b5, which added I6, I9 and I10 — and the code
> below it evaluates all eight. Where the prose and the code disagree, the code
> is what produced the numbers.

### Why the numbering has gaps

The invariant IDs skip 7 and 8; the scenario IDs skip S7, S9, S10, S13 and S16.
Both gaps are documented here rather than closed, and neither is a case of
something being dropped after it produced an inconvenient result — as far as
the repository records, neither ever existed.

**I7 and I8: could not be determined.** Searches run: `git log --all -S 'I7'`,
`-S 'I8'`, `-S 'check_i7'`, `-S 'check_i8'`; a `grep` for `\bI7\b` / `\bI8\b`
over the whole worktree; a `grep` over every archived `invariant_report.json`
in `results/` (all twelve list `I1,I2,I3,I4,I5,I6,I9,I10` and nothing else);
and a scan of every dangling object `git fsck --lost-found` reports. The only
two occurrences of the strings anywhere in the repository are this section and
the line in `REVIEW.md` that raises the gap. I1–I5 are the paper's original set
and are present in the initial commit; I6, I9 and I10 arrive together in
74c62b5 ("Three new invariants that catch failure modes the paper's I1–I5 do
not"), whose message explains each of the three in detail and says nothing
about 7 and 8. So no check named I7 or I8 was ever committed, and **why those
two numbers were passed over is not recorded anywhere in the tree.** An earlier
version of this section claimed the numbering "follows the paper's drafts";
nothing in the repository supports that, so it has been removed rather than
kept as a plausible-sounding explanation.

**S7, S9, S10, S13 and S16: could not be determined either.** Searches run:
`git log --all -S` for each ID in both letter cases (`s7` and `S7`, and so
on); `git log --all --diff-filter=A --name-only -- 'scenarios/*'`; and a
`grep` over the worktree and over `results/`.
Every scenario the suite has ever contained appears in one of two commits —
the initial commit (S1–S6, S8, S11, S12, S14, S15, S17–S19) and f98f637
(S20–S28) — and the scenario index in that *initial* commit's README already
has exactly these five holes. No playbook, tag, `results/` directory or
document under version control has ever referred to the missing IDs. Whether
they were planned scenarios that were never written, or numbers skipped for
some other reason, is not recorded.

Renumbering into a dense sequence was considered and rejected: the identifiers
are referenced from `check-invariants.sh`, `aggregate-results.sh`,
`report-template.html`, all 23 scenario playbooks,
`playbooks/run-all-scenarios.yml`, every archived `invariant_report.json` under
`results/`, and `REVIEW.md` itself. Renumbering would silently invalidate the
archived corpus and any notes kept outside the repository, and buy nothing but
a denser sequence.

### Verdicts

Per-invariant verdict — the vocabulary is emitted with each report as
`summary.verdict_vocabulary`:

- `PRESERVED` — evaluated in every snapshot and held
- `VIOLATED` — broken in at least one snapshot. Carries
  `first_violation_snapshot` / `first_violation_ts` (the first entry of
  `.violations`, which every check appends in chronological order) and
  `duration_s` — see below. A check with no single snapshot locus says so in
  `first_violation_ts_note` instead of inventing one.
- `INSUFFICIENT_DATA` — the run does not contain the evidence this invariant
  needs (I4 outside S6; I5 for runs recorded before per-API-server views; I10
  with fewer than two post-fault snapshots)
- `NOT_APPLICABLE` — this fault class cannot, even in principle, produce the
  state the invariant forbids, because the subsystem the invariant reads is
  outside the blast radius. The rule is a declared
  `fault_class|invariant|reason` table at the top of `check-invariants.sh`
  rather than scattered conditionals, and it is deliberately narrow: an
  invariant that *could* have fired and didn't stays a genuine `PRESERVED`.
  The measured verdict is kept as `measured_verdict`, so a cell the table calls
  inapplicable but that was measured `VIOLATED` still carries the evidence that
  would prove the table row wrong.
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
  scenario with `efficacy_require` / `efficacy_target_node`). A required
  signal whose evidence file is missing reports `evidence_absent`, and an
  unrecognised signal name surfaces in `unknown_required_signals` rather than
  silently forcing `FAULT_INEFFECTIVE` forever.

`FAULT_INEFFECTIVE` is a *run*-level verdict, never a per-invariant one: if the
fault did nothing, every invariant verdict in that run describes an undisturbed
cluster, so the run is excluded whole.

Rates are computed over one stated population — `PRESERVED + VIOLATED` and
nothing else (`summary.evaluable` per run, `summary.denominator` in the
aggregate, where every excluded cell is counted and listed with its reason).

**`duration_s` is `null` in every run today.** A snapshot series 15–60 s apart
cannot measure a duration, so `scripts/violation-duration.sh` takes it from the
1 Hz trace instead, and where no trace exists it returns `null` **with a stated
reason — never `0`**, because a `0` would assert the violation had no extent.
No scenario records a trace yet (see the next section), so this is the current
state of every archived *and* every fresh run. Even once a trace is recorded,
I1, I3, I4 and I10 have no trace predicate at all — dual ownership and the
Ready/containers pairing are read from node-local `crictl`, I4 is cross-run,
and I10 is a set difference over Warning events, none of which the trace
records — so those four name the missing field rather than substitute a
snapshot bracket that would read like a measurement. I2, I6 and I9 read the
trace directly; I5 reuses `scripts/observer-disagreement-duration.sh` verbatim.

The `aggregate_report.json` collects all verdicts into the heatmap
described as Figure 7 in the paper.

> **The results committed before Aug 27 2026 predate these checks.** See
> [`REVIEW.md`](REVIEW.md) — the May 2026 sweep's I2, I5 and I6 columns are
> artifacts of defects in the checker, not measurements. Re-run the suite
> before citing any figure from it.

---

## Continuous Trace and Observer Disagreement — built, not yet wired

`roles/metrics-collect` can record more than the 30–60 s snapshots the
scenarios take. The extra machinery is complete and syntax-checked, and **no
scenario calls it yet**, so nothing below should be read as a claim about data
that exists.

The role dispatches on `metrics_mode`. `snapshot` is the default and is what
every scenario uses; it behaves exactly as it always did. `trace-start` /
`trace-stop` add a detached recorder writing JSONL:

- `trace.jsonl` — 1 Hz from cp2: per-node Ready, the controller-manager,
  scheduler and node leases with a computed `renew_age_ms`, the
  `nginx-stateless` endpoint set, `postgres-stateful-0`'s identity and node,
  and the apiserver `resourceVersion`.
- `trace_etcd.jsonl` — 0.2 Hz from etcd1: per-member revision, raft term and
  index, leader, alarms.

`renew_age_ms` is the point of it: an expired lease being observed becomes
directly visible, which is what turns a boolean verdict into a duration.
Records carry `t_rel_ms` measured off `/proc/uptime` rather than the wall
clock, so the trace stays usable in S4, S23 and S27 where the clock is
deliberately wrong, and `errors` names the sub-queries that failed for a
sample, so a `null` field means the read failed rather than the object being
absent. The recorder is reaped on start, carries a monotonic deadline and a
`timeout(1)` wrapper, and is capped at 5000 lines / 32 MiB. Settings are the
`trace_*` variables in `inventory/group_vars/all.yml`.

Snapshots themselves *do* now measure observer disagreement rather than
asserting it. Twelve observers are asked the same three questions at every
snapshot — the three API servers addressed at their own IPs (told apart by a
SHA-256 serving-cert fingerprint, since every cert carries all four SANs), a
linearizable etcd read, each kubelet at `:10250`, each node's CRI, an
in-cluster informer, and the in-cluster probe. The questions: is `worker1`
Ready, where is `postgres-stateful-0` running, and what is the endpoint set of
`nginx-stateless`. The pairwise result is spliced into each snapshot as
`.disagreement`. "Could not read" is a third state throughout: an answer is
`answered` / `unreadable` / `not_applicable`, a pair is comparable only when
both answered, and agreement is `null` rather than `true` when fewer than two
observers answered — otherwise a partition that silences an observer would read
as consensus.

What that means for what can be cited today:

- No scenario calls `trace-start` / `trace-stop`, so no `trace.jsonl` is ever
  written and every `duration_s` is `null`.
- The in-cluster informer is created by `trace-start`, so it is never created.
  Snapshots record it as `unreadable` with reason `informer_absent` — honest
  missing data rather than a wrong answer.
- `scripts/observer-disagreement-duration.sh` reads a trace, so
  `disagreement_duration.json` is not produced automatically. Run it over a
  results directory that has one:
  `scripts/observer-disagreement-duration.sh results/s2/<run_id>`.
- The per-snapshot `.disagreement` matrix *is* recorded, for runs taken after
  commit 8b4ae4b. The archived May 2026 runs have none of this.
- Wiring the scenarios to record a trace is a separate change that has not
  landed.

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
