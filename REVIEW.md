# Suite Review — Measurement Validity, Methodology, and Scenario Coverage

Review date: 2026-08-27
Reviewed tree: `k8s-failure-semantics/` at commit `3f14e4e` (scripts: add preflight.sh)
Evidence base: `scenarios/`, `roles/`, `scripts/check-invariants.sh`, and the
archived results in `results/` (runs of 2026-05-20 and 2026-05-21).

---

## Executive summary

The lab, the fault library and the report pipeline are in good shape. The
problem is on the measurement side: **four defects in `check-invariants.sh` and
two ineffective fault injections mean the current `aggregate_report.json` cannot
be used as evidence.**

Reading the heatmap at face value:

| Invariant | Verdict pattern | Actual status |
|-----------|-----------------|---------------|
| I2 | VIOLATED in 11/12 scenarios | Artifact — the external probe never worked, `httpCode: 0` at baseline too |
| I5 | VIOLATED in 11/12 scenarios | Artifact — threshold heuristic plus a clause that is almost always true |
| I6 | VIOLATED in 11/12 scenarios | Artifact — snapshots are compared in filename order, not time order |
| I3 | PRESERVED in 12/12 scenarios | Cannot fire — wrong condition value |
| I4 | INSUFFICIENT_DATA everywhere | S6 never produced results |
| S11, S12 | verdicts reported | Faults had no observable effect; both runs are null |

Everything below is grounded in the repository's own archived data. Section 1 is
correctness (must fix before publication), Section 2 is methodology (what would
make the results defensible), Section 3 is coverage (new scenarios).

---

## Implementation status — Aug 28 2026

**All three sections are implemented in the tree.** Everything that remains is
lab execution: the suite has never been run against the cluster since the
fixes landed, so `results/` is still the superseded May 2026 sweep.

| Item | Status | Where |
|------|--------|-------|
| D1 snapshot ordering | fixed | `scripts/check-invariants.sh` (`snapshots()`), `roles/metrics-collect/tasks/main.yml` (`snapshot_index`) |
| D2 I3 `Ready=Unknown` | fixed | `check-invariants.sh` (`check_i3`), node taints collected in `metrics-collect` |
| D3 in-cluster probe | fixed | `metrics-collect` (probe runs on `metrics_cp_host`, emits `httpCode: null` when it cannot run), `check_i2` |
| D4 I5 staleness, I9 quorum | fixed | `metrics-collect` (`.observers[]`, `.etcd.expected_members`), `check_i5`, `check_i9` |
| D5 S11 VIP, S12 flap peers | fixed | `scenarios/s11/playbook.yml`, `scenarios/s12/playbook.yml`, `roles/fault-inject/tasks/network-flap.yml` |
| D6 calibration gate, fault efficacy | fixed | `check-invariants.sh` (calibration pass, `fault_efficacy`), `roles/fault-inject/{defaults,tasks}/main.yml`, `scripts/aggregate-results.sh` |
| S20–S28 new scenarios | added | `scenarios/s20`–`s28` (`f98f637`), README index (`834dc11`) |
| M1 1 Hz continuous trace | done | `roles/metrics-collect` (`73410eb`), wired into every scenario (`62d37dc`) |
| M2 explicit observer set | done | `metrics-collect` (`8b4ae4b`), `scripts/observer-disagreement-duration.sh` |
| M3 repetition and statistics | harness done, data not collected | `scripts/repeat-scenario.sh` (`57da7bc`), cross-run stats (`493d366`), report rendering (`b328713`) |
| M4 verdict vocabulary | done | `check-invariants.sh` — `NOT_APPLICABLE`, `DETECTOR_INVALID`, `FAULT_INEFFECTIVE`, `duration_s`, `scripts/violation-duration.sh` (`c0fe01a`) |
| M5 numbering and docs | done | `README.md` "Why the numbering has gaps" (`67f2064`) |
| S2 NFS enrichment | done | `roles/nfs-server/`, `postgres-stateful.yml` now mounts the `postgres-shared-nfs` PVC |
| **Full re-run of the sweep** | **open** | `results/` still holds only the 2026-05-20/21 runs |
| **N ≥ 5 data collection (M3)** | **open** | every scenario has one archived run; I4 still has no input |
| **S5 and S6 results** | **open** | `results/s5` and `results/s6` do not exist |

### What the fixes do to the archived results

Re-running the corrected checker over the untouched May 2026 snapshots
(`results/` copied aside, nothing overwritten) changes the heatmap as follows:

| Invariant | Before | After | Why |
|-----------|--------|-------|-----|
| I2 | VIOLATED 11/12 | DETECTOR_INVALID 10/12 | Disqualified by the calibration gate: it fails at baseline |
| I5 | VIOLATED 11/12 | INSUFFICIENT_DATA 12/12 | The heuristics are gone; these runs carry no observer views |
| I6 | VIOLATED 11/12 | PRESERVED 12/12 | The regressions were filename ordering |
| I3 | PRESERVED 12/12 | VIOLATED in S2 | worker1 sits at `Ready=Unknown` for four snapshots with five pods running on it |
| I10 | 1 violation | 4 violations | First/last post-fault snapshots are now the actual first and last |
| Violation rate | 45 % | 13 % | Denominator no longer contains disqualified detectors |

S11 and S12 come back `FAULT_INEFFECTIVE` once their `scenario_meta.json`
declarations are in place, which is the correct reading of both runs.

**This does not make the archived results usable.** They still predate the
5-member etcd cluster, the in-cluster probe and the observer views, so I5 has
no evidence at all and I2 has none that can be trusted. The suite needs a full
re-run; `results/` and `report.html` in the tree are superseded, and
`report.html` now says so on both its Overview and Findings pages.

### Verification performed

Offline, against the archived `results/` tree (no cluster required):

- `bash -n` on `check-invariants.sh` and `aggregate-results.sh`; `node --check`
  on the report template's JavaScript; `yaml.safe_load` on every changed
  playbook, role task file and defaults file.
- The corrected checker run over all 12 archived scenario runs, and
  `aggregate-results.sh` over the result, producing the table above.
- The D6 guardrails exercised directly: with the S11 and S12 efficacy
  declarations in place both runs are labelled `FAULT_INEFFECTIVE` with the
  missing signal named (`target_node_status_changed`, `lease_holder_changed`),
  while S2 stays `OK`.
- `build-report.sh` rebuilt end to end over the corrected results.

Not verified: anything requiring the lab. Every change to the Ansible side —
the D1–D6 fixes, the M1/M2 collection changes and all nine new scenarios — is
syntax-checked but unexecuted. Specifically still unvalidated on hardware:

- the per-API-server view task, which assumes the kubeadm API server
  certificate carries the node's own address in its SANs (the kubeadm default);
- the in-cluster probe (D3);
- the S11 VIP and S12 etcd-peer injection fixes (D5) — the first live run should
  confirm `.observers[]` arrives populated and that S11 moves worker1 out of
  `Ready=True`;
- the 1 Hz trace and the observer-disagreement matrix (M1, M2), including
  whether the recorder keeps up for a full scenario duration;
- S20–S28 in their entirety, and S2 against the NFS-backed PV.

The next step is `scripts/preflight.sh`, then `scripts/run-sweep-detached.sh`,
at N ≥ 5 via `scripts/repeat-scenario.sh`. Until that data exists, no number in
`results/` or `report.html` should be cited.

---

## 1. Defects that invert the current results

### D1 — Snapshots are ordered lexically, not chronologically

`scripts/check-invariants.sh:27`

```bash
snapshots() {
  ls "$RESULTS_DIR"/snapshot_*.json 2>/dev/null | sort
}
```

`sort` on filenames gives, for S2:

```
post_fault_t120, post_fault_t240, post_fault_t30, pre_fault,
t_plus_120, t_plus_180, t_plus_240, t_plus_30, t_plus_60
```

The true order, from `results/s2/20260521_145240/run_index.txt`, is
`pre_fault → t_plus_30 → t_plus_60 → t_plus_120 → t_plus_180 → t_plus_240 →
post_fault_t30 → post_fault_t120 → post_fault_t240`.

Observed etcd revisions in filename order for that run:

```
357889, 358217, 357643, 356282, 356887, 357125, 357424, 356393, 356623
```

Monotone in real time, wildly non-monotone as evaluated.

**Impact**

- **I6 (watch progress monotonicity) is VIOLATED in every scenario purely
  because of this.** The invariant as implemented measures filename collation.
- I5's revision-delta comparisons are computed between non-adjacent snapshots.
- I10 compares the wrong "first" and "last" post-fault snapshots
  (`post_fault_t120` is treated as first, `post_fault_t30` as last).
- `divergence_timing` is nonsense: `results/aggregate_report.json` reports
  `"first_fault_snapshot": "post_fault_t210"` for S1 and `"post_fault_t120"`
  for S2, S3 and S4 — i.e. the fault apparently began after it ended.

**Fix**

Either sort by the `timestamp` field inside each snapshot, or (simpler and also
fixes human reading of the directory) emit an ordinal prefix at write time in
`roles/metrics-collect/tasks/main.yml`:
`snapshot_00_pre_fault.json`, `snapshot_01_t_plus_30.json`, …

```bash
snapshots() {
  for f in "$RESULTS_DIR"/snapshot_*.json; do
    [ -e "$f" ] || continue
    printf '%s\t%s\n' "$(jq -r '.timestamp // "9999"' "$f")" "$f"
  done | sort | cut -f2
}
```

Note that the snapshot ordinal must also be stable across scenarios whose labels
are not `t_plus_*` (S11 uses `post_reconnect_*`, S12 `flap_*`/`post_flap_*`,
S19 `split_*`/`post_restore_*`), which is another argument for the ordinal
prefix over any label-parsing scheme.

---

### D2 — I3 can never fire

`scripts/check-invariants.sh:168`

```bash
[.[] | select(.conditions[].status == "False") | .name] | @json
```

Kubernetes does not set `Ready=False` on a node it has lost contact with. The
node controller sets `Ready=Unknown` with `reason: NodeStatusUnknown` after the
node-monitor grace period. `Ready=False` means the kubelet is reporting *and*
saying it is not ready — the opposite of the partition case the invariant
targets.

From `results/s2/20260521_145240/`:

```
snapshot_t_plus_30    worker1  Ready=True     KubeletReady
snapshot_t_plus_60    worker1  Ready=Unknown  NodeStatusUnknown
snapshot_t_plus_120   worker1  Ready=Unknown  NodeStatusUnknown
snapshot_t_plus_180   worker1  Ready=Unknown  NodeStatusUnknown
snapshot_t_plus_240   worker1  Ready=Unknown  NodeStatusUnknown
```

with containers running on worker1 throughout
(`worker1_actual_containers_during_fault.json`). That is a textbook I3
violation, reported as PRESERVED.

**Impact** — I3 is PRESERVED by construction in exactly the scenario class it
exists to detect. This is the same defect class already documented and fixed for
I1 in the comment at `check-invariants.sh:56` ("returned PRESERVED by
construction, not by measurement"); I3 was not audited at the same time.

**Fix** — Treat anything other than `"True"` as not-declared-healthy, and
corroborate with the taint the node controller applies:

```bash
[.[] | select((.conditions[] | select(.type=="Ready") | .status) != "True") | .name]
```

Additionally collect `.spec.taints` in `metrics-collect` and look for
`node.kubernetes.io/unreachable:NoExecute`, which is what actually triggers
eviction and is therefore the operative "declaration of failure".

**Opportunity, not just a bug.** `Ready` is three-valued, and `Unknown` is
precisely *observer-relative uncertainty* rather than declared failure. The
suite currently collapses `Unknown` into `True`. Splitting the verdict —
declared-failed vs declared-uncertain vs declared-healthy, each cross-checked
against node-local crictl truth — is a contribution the paper can make rather
than a detail to normalise away. Suggested split:

- **I3a** declared-failed (`Ready=False` or `unreachable` taint) yet running
  containers;
- **I3b** declared-uncertain (`Ready=Unknown`) yet running containers, with the
  duration of the uncertainty window;
- **I3c** declared-healthy (`Ready=True`) yet no containers running / kubelet
  not actually functional — the gray-failure direction, currently unmeasured.

---

### D3 — The external probe never worked, so every I2 verdict is baseline noise

`roles/metrics-collect/tasks/main.yml` probes the nginx ClusterIP from
`groups['observer'][0]`, which per `inventory/hosts.ini` is
`localhost ansible_connection=local` — the macOS workstation. ClusterIP CIDRs
are not routable from there. Every snapshot in every scenario records:

```json
{"service":"nginx-stateless","clusterIP":"10.102.79.126","httpCode":0}
```

including `snapshot_pre_fault.json`. `check_i2` (`check-invariants.sh:127`)
then flags `probe_code != 200` alongside listed endpoints as a violation, so I2
is VIOLATED before any fault is injected.

`scenarios/s15/playbook.yml` already documents this constraint in its header
comment and works around it by running its generators on cp1 — the workaround
was never propagated to `metrics-collect`.

**Impact** — All 11 I2 "VIOLATED" verdicts. Also corrupts `divergence_timing`,
whose `first_service_failure_snapshot` is driven by the same field
(`check-invariants.sh:491`) and therefore always fires on the first snapshot in
(lexical) order.

**Fix** — Run the probe from inside the cluster, as S15 does: `delegate_to`
cp2 with `KUBECONFIG=/etc/kubernetes/admin.conf`, or expose nginx as a NodePort
and probe `<node-ip>:<nodeport>` from the observer. Distinguish "probe failed"
from "probe not possible": a probe that cannot run must emit
`"httpCode": null` and the invariant must return `INSUFFICIENT_DATA`, never
`VIOLATED`.

---

### D4 — I5 and I9 do not measure what they claim

**I5** (`check-invariants.sh:273`) has two clauses, both unsound:

1. `delta > 500` etcd revisions between consecutive snapshots. That measures the
   cluster's write throughput, not staleness — an idle 6-node cluster with
   lease renewals produces 300–1400 revisions per 60–90 s window in your own
   data. Combined with D1 the deltas are between non-adjacent snapshots anyway.
2. "any `NodeNotReady`/`FailedScheduling` warning event exists AND at least one
   node is Ready". In a 6-node cluster with a 1 h event TTL, the second
   conjunct is true in essentially every snapshot after any scenario has ever
   run.

**Fix** — Measure staleness directly rather than by proxy. At each snapshot, for
a fixed probe object, from *each* API server: one linearizable read and one
`--resource-version=0` (watch-cache) read, plus etcd's current revision at the
same instant. I5 is then "a controller acted on state whose resourceVersion was
older than a value already visible elsewhere", with the gap in revisions and in
milliseconds as the measurement. S19's cp1-vs-cp2 comparison is a special case
of exactly this — generalise it into `metrics-collect`.

**I9** (`check-invariants.sh:378`) infers cluster size as the maximum member
count observed across snapshots:

```bash
if [[ "$count" =~ ^[0-9]+$ ]] && [ "$count" -gt "$total_members" ]; then
  total_members=$count
```

Every archived snapshot shows `.etcd.member_status | length == 3`, against an
inventory that now defines five members (`inventory/hosts.ini`, commit
`b09104e`). If a genuine split leaves only 2 of 5 members reachable, the check
infers `n=3`, computes `quorum=2`, and returns **PRESERVED for a cluster that
has lost quorum** — a silent false negative in S19, the one scenario built to
test it.

**Fix** — Take `n` from the inventory (`groups['etcd'] | length`), pass it in as
an argument, and treat "observed < expected" as data rather than as the new
truth. Also record `raftTerm`, `leader` and `isLearner` per member from
`endpoint status`: two distinct leader IDs, or diverging raft terms across
members in the same snapshot, is the direct evidence of a split, far stronger
than a member count. The archived results should be re-generated regardless,
since they predate the 5-member cluster.

---

### D5 — S11 and S12 injected faults that had no observable effect

**S11 (kubelet partition).** `scenarios/s11/playbook.yml:63` blocks outbound
TCP/6443 to the three control-plane IPs only. The kubelet reaches the API server
through the keepalived VIP `10.0.0.59`, which is not in the loop — the exact
issue already fixed in S2 via `extra_peer_ips` (`scenarios/s2/playbook.yml`
and the `network-asymmetric.yml` header comment). Result, across all seven S11
snapshots:

```
worker1 Ready=True   worker2 Ready=True   worker3 Ready=True
```

The node never left Ready. The scenario measured an undisturbed cluster and
still emitted eight invariant verdicts.

**S12 (leader election storm).** `scenarios/s12/playbook.yml:89` flaps cp1
against cp2 and cp3 only. cp1's own API server keeps its connection to the etcd
members (10.0.0.56–61, unblocked), so the controller-manager on cp1 renews its
lease normally throughout. `results/aggregate_report.json`:

```json
{"scenario":"s12","total_samples":120,
 "distinct_cm_holders":["cp1_2aec992f-…"],"cm_holder_changes":0,
 "distinct_sched_holders":["cp1_f440e7ee-…"],"sched_holder_changes":0}
```

Zero leader changes: the storm never happened. Secondarily, `flap_interval: 10`
with `flap_count: 6` gives 10 s blocked windows against a 15 s
`leaseDurationSeconds` — even with the right peers blocked, the lease cannot
expire.

**Fix**

- S11: add the API VIP (and, if the intent is a full kubelet partition, the etcd
  IPs) to the blocked set.
- S12: block cp1 against `groups['etcd']` and the VIP; use asymmetric flap
  windows that straddle the lease duration (e.g. 20 s blocked / 10 s open) and
  read `leaseDurationSeconds` from the live lease rather than hard-coding an
  assumption.

---

### D6 — Two guardrails that would have caught D3, D5 and most of D1

**Pre-fault calibration gate.** An invariant that is violated in `pre_fault` is
a broken detector, not a finding. Add a verdict `DETECTOR_INVALID`: evaluate
every invariant against the pre-fault snapshot alone first; if it does not come
back PRESERVED, the invariant is disqualified for that run and the aggregate
must show it as invalid rather than violated. This rule alone invalidates the
I2 and I6 columns automatically.

**Fault-efficacy assertion.** Every scenario should declare, in its own vars,
the observable signature its fault must produce — S2: `worker1` leaves `Ready=True`
within 90 s; S12: at least one lease holder change; S19: minority-side writes
fail — and assert it before the observation window closes. A run that fails its
own efficacy assertion is `FAULT_INEFFECTIVE` and is excluded from the aggregate
rather than contributing verdicts. S11 and S12 would both have been caught.

Related: `results/s5` and `results/s6` do not exist, yet the aggregate reports
`"NO_DATA"` for those scenarios in the same table as real verdicts, and
`recovery_variance_s6: {"variance":"NO_DATA"}` is the reason **I4 is
unevaluated in the entire suite**. A scenario that failed to run must be
distinguishable from one that ran and found nothing.

---

## 2. Methodology

### M1 — Sampling resolution is coarser than the phenomena

Snapshots are taken every 30–60 s. The mechanisms under study are faster:

| Mechanism | Timescale |
|-----------|-----------|
| Lease duration / renewal | 15 s / 10 s |
| Node monitor grace period | ~40 s |
| Endpoint propagation | sub-second |
| kube-proxy rule update | sub-second |

A 30 s sampler cannot resolve a 15 s lease transition, and the paper's central
claim is about *when* and *for how long* observers disagree.

**Recommendation.** Keep the heavyweight snapshots as cross-sections, and add a
continuous 1 Hz recorder running for the full scenario duration: `kubectl get
--watch` on nodes, leases, endpoints and pods, plus periodic etcd revision, each
line a timestamped JSONL record. Verdicts then become durations, not booleans —
"I1 violated for 143 s (t+62 → t+205)" is a materially stronger result than
"I1 VIOLATED", and divergence-onset timing stops being quantised to the snapshot
grid.

### M2 — Make the observer set explicit

For a paper titled *Observer-Relative Failures*, nearly every observation comes
from a single API server (`metrics_cp_host`, defaulting to cp2), plus node-local
crictl. The observer-relativity is asserted rather than measured.

**Recommendation.** At each snapshot, ask the same small set of questions of
every observer:

| Observer | How |
|----------|-----|
| API server cp1 / cp2 / cp3 | direct `https://<ip>:6443`, bypassing the VIP |
| etcd (quorum read) | `etcdctl get` on the relevant key |
| kubelet | `:10250/pods` on each node |
| CRI | `crictl ps` on each node |
| In-cluster informer | small watcher pod recording its cached view |
| External client | in-cluster HTTP probe (see D3) |

Questions: is `worker1` Ready; where is `postgres-stateful-0` running; what is
the endpoint set of `nginx-stateless`. Emit a **pairwise disagreement matrix**
per snapshot and, from the 1 Hz trace, a **maximum disagreement duration** per
question per scenario. That is the paper's headline table, and it is currently
only produced ad hoc for cp1-vs-cp2 inside S19.

### M3 — Repetition and statistics

Every scenario has exactly one run in `results/`, except S6 which has none. No
variance, no confidence intervals, no way to distinguish a real effect from a
scheduling coincidence.

**Recommendation.** N ≥ 5 per scenario, report median and IQR for every timing
measurement, and report violation *frequency* across runs rather than a single
boolean. S6 already implements the repeat harness (five explicit
`import_playbook` iterations) — generalise that mechanism to all scenarios
rather than keeping it as one scenario's private structure, and make I4 a
cross-run computation over any scenario with N > 1, not just S6.

### M4 — Verdict vocabulary

`PRESERVED` / `VIOLATED` / `INSUFFICIENT_DATA` is too narrow. Add:

- `NOT_APPLICABLE` — the invariant is not meaningful for this fault class
  (currently misreported as PRESERVED, which inflates the preserved count);
- `DETECTOR_INVALID` — failed the pre-fault calibration gate (D6);
- `FAULT_INEFFECTIVE` — the run's efficacy assertion failed (D6).

And attach `duration_s` plus `first_violation_ts` to every VIOLATED verdict.
The current `summary.violation_rate_pct: 45` mixes real findings, artifacts and
inapplicable checks into one number.

### M5 — Documentation and numbering consistency

- `README.md` documents I1–I5; `check-invariants.sh` emits I1–I6, I9, I10.
  I7 and I8 do not exist anywhere in the tree.
- Scenario IDs skip S7, S9, S10, S13, S16.

Either renumber into a dense sequence or document the gaps explicitly (e.g. as
designed-but-dropped, with the reason). A reviewer will ask about both, and
"eight invariants numbered up to ten" invites the suspicion that the missing two
were dropped because they did not produce the desired result.

---

## 3. Scenario coverage

The existing fault library covers clean crash-stop and timing failures: full
`DROP`, one-way `DROP`, fixed `netem` delay, Toxiproxy latency, clock advance,
memory pressure, compaction. Production clusters mostly fail *gray* — the node
stays Ready while nothing works — and that region is currently unsampled.
Ordered by value per unit of effort.

### S20 — Pod-network partition with the management network intact
Every VM already has two NICs (`10.0.0.x` management, `192.168.200.x` pod
network, `INFRASTRUCTURE.md`). Block only `192.168.200.0/24` between one worker
and the rest. Kubelet heartbeats continue over the management NIC, every node
reports Ready, the API server sees a perfectly healthy cluster, and the data
plane is dead. **This is the sharpest observer-relative split the lab can
produce, and it costs one iptables rule.** Expect I2 and the new I3c to fire
while I1, I3 and I9 stay clean — a signature no current scenario produces.

### S21 — Keepalived VIP split-brain
Block VRRP (224.0.0.18 / protocol 112) between the control-plane nodes so two of
them simultaneously claim `10.0.0.59`. Literal dual authority at the network
layer rather than the pod layer — I1 at a different level of the stack, using
infrastructure already installed by `roles/k8s-install/tasks/keepalived.yml`.
Measure which API server each client reaches and whether two clients disagree
about the same object at the same instant.

### S22 — Container runtime and kubelet freeze (omission failure)
`SIGSTOP` containerd, hold, `SIGCONT`. Separately, `SIGSTOP` the kubelet. The
node stays Ready (or goes Unknown without ever being restarted), nothing starts
or stops, and — unlike a kill — the process resumes with stale in-memory state
and a backlog of missed watch events. This is an *omission* failure rather than
crash-stop, which lets the paper organise its results by classical failure
semantics (crash / omission / timing / arbitrary), a structure its title already
invites and the current suite cannot populate.

### S23 — etcd NOSPACE
Fill an etcd member's data disk until the `NOSPACE` alarm fires. The cluster
goes read-only while every API server continues serving reads and every health
check stays green. Directly targets I5, I6 and I10, is trivially reproducible,
and is one of the most common real etcd outages.

### S24 — Admission webhook timeout
Register a validating webhook with `failurePolicy: Fail` pointing at an endpoint
that black-holes. A completely healthy cluster that cannot act. Then repeat with
`failurePolicy: Ignore` and compare: same fault, opposite failure semantics,
selected by one field. That contrast is a strong result on its own.

*Implementation note:* the original claim here was "needs no network
manipulation at all". That turned out to be wrong. An unassigned address on a
directly-connected /24 does not black-hole — ARP fails and `connect()` returns
EHOSTUNREACH in ~3 s (measured: curl exit 7 after 3071 ms from cp2), so the
call never reaches the admission timeout path it is supposed to exercise. A
`blackhole` route does not help either: the kernel maps `RTN_BLACKHOLE` to
`-EINVAL` for locally-originated packets, which fails even faster. The
scenario therefore installs one `iptables OUTPUT ... -j DROP` rule, because
the OUTPUT hook runs before neighbour resolution, so the SYN is discarded
silently and TCP retransmits until `timeoutSeconds` fires. It is still the
cheapest scenario in the suite, but it is no longer zero-network-manipulation.

### S25 — API priority-and-fairness starvation
Flood the API server with a low-priority client until controllers receive 429s.
Every node Ready, etcd healthy, control loops starved. Tests whether the suite's
invariants can distinguish "cannot observe" from "observed and chose not to act".

### S26 — Node object deleted while the kubelet lives
`kubectl delete node worker1` without touching the machine. The kubelet
re-registers under the same name; the pods it was running are orphaned in the
interval. Identity re-creation with a live substrate — a different mechanism for
I1 than S2's force-delete, and one that requires no operator footgun to reach.

### S27 — Negative and substrate clock skew
S4 advances one control-plane node by +120 s. Add: skew *backwards*, which makes
`renewTime` appear to be in the future and breaks lease-expiry arithmetic in a
different direction; and skew the etcd members relative to the API servers,
which affects lease TTLs at the storage layer rather than the controller layer.

### S28 — Stale etcd member rejoining after compaction
Extends S17 into the recovery phase: isolate a member long enough that the
leader has compacted past its log position, then restore connectivity. The
member cannot catch up and must be re-seeded; what the API servers do during
that window is exactly the watch-gap question S17 opens and does not close.

### Enrichment to S2 — make dual ownership consequential
`roles/k8s-install/files/postgres-stateful.yml` uses `emptyDir`, and the inline
comment explains why (a node-affine local provisioner would drag the replacement
back to the partitioned node). The reasoning is sound for *identity*, but a
reviewer will observe that dual ownership without dual storage access does not
demonstrate harm — two pods with the same name and separate scratch disks is a
naming collision, not a correctness violation.

An NFS-backed PV carries no node affinity, so the replacement still schedules on
a healthy node, both copies mount the same volume, and divergent writes become
measurable. The sibling `performance-benchmark-framework` repo already contains
an `nfs-server` role that can be lifted directly. That single change turns S2's
result from "the same pod name existed twice" into "two live processes wrote to
the same volume with no fencing", which is the claim the paper actually wants to
make.

---

## 4. Suggested order of work

The code order below is done; what is left is the data. Steps 1–3, 5 and 7 of
the original plan (D1–D6, M1–M5, S20–S28) are in the tree — see *Implementation
status* above for where each one landed. The remaining work is all lab time:

1. **Shake-down run.** `scripts/preflight.sh`, then a single pass over S2, S11
   and S12 only. These three carry the changes most likely to be wrong on
   contact: the in-cluster probe, the per-API-server views, the S11 VIP block
   and the S12 etcd-peer flap. Confirm `.observers[]` arrives populated, that
   S11 moves worker1 out of `Ready=True`, and that S2's two postgres copies
   both mount the NFS PV. Nothing downstream is worth running until this passes.
2. **Validate the new scenarios once each.** S20–S28 have never executed. Run
   them singly and check each against its own efficacy assertion before
   committing them to a full sweep — a scenario that comes back
   `FAULT_INEFFECTIVE` needs its injection fixed, not more repetitions.
3. **Full sweep at N = 1.** `scripts/run-sweep-detached.sh` across all 23
   scenarios, including S5 and S6, which have no archived results at all.
   Rebuild the report and read the heatmap for detectors that fail the
   calibration gate — `DETECTOR_INVALID` at this stage is a bug in the check,
   not a finding.
4. **Final collection at N ≥ 5.** `scripts/repeat-scenario.sh` per scenario,
   which is what makes I4 evaluable and turns the M4 durations into medians and
   IQRs rather than single observations. Budget the lab time: 23 scenarios at
   five runs is the largest single cost remaining in the project.
5. **Retire the archived data.** Once the new sweep exists, delete or clearly
   date-fence the 2026-05-20/21 `results/` tree and regenerate `report.html`
   from the new runs. Until then, no number in either is citable.

---

## Appendix — reproducing the evidence

```bash
cd k8s-failure-semantics/results

# D1: evaluation order vs real order
ls s2/*/snapshot_*.json | sort
cat s2/*/run_index.txt
for f in s2/*/snapshot_*.json; do
  printf '%-50s %s\n' "$(basename "$f")" "$(jq -r '.etcd.current_revision' "$f")"
done

# D2: worker1 is Unknown, never False
for f in s2/*/snapshot_*.json; do
  printf '%-30s %s\n' "$(basename "$f" .json)" \
    "$(jq -c '[.control_plane.node_conditions[]?
               | select(.name=="worker1")
               | {s:.conditions[0].status, r:.conditions[0].reason}]' "$f")"
done

# D3: probe is 0 everywhere, including pre_fault
jq -c '.external_probe' s2/*/snapshot_pre_fault.json

# D4: member count observed vs inventory
jq '.etcd.member_status | length' s2/*/snapshot_pre_fault.json
grep -A6 '^\[etcd\]' ../inventory/hosts.ini

# D5: S11 never left Ready; S12 never changed leader
for f in s11/*/snapshot_*.json; do
  printf '%-30s %s\n' "$(basename "$f" .json)" \
    "$(jq -c '[.control_plane.node_conditions[]?
               | select(.name=="worker1") | .conditions[0].status]' "$f")"
done
jq '.amplification_metrics' aggregate_report.json

# D6: scenarios that never ran
jq '.invariant_heatmap[] | select(.I1=="NO_DATA") | .scenario' aggregate_report.json
ls s5 s6
```
