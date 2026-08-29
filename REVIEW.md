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

### Shake-down run — 2026-08-28

First execution of any of this against the lab, per step 1 of the work order.
`scripts/preflight.sh` passes (11 VMs over ssh, API VIP up, vCenter
authenticating, refresh-only plan clean) and the cluster was healthy going in:
6 nodes Ready, v1.36.1, Ubuntu 24.04.

D7 blocked the first attempt entirely; with it fixed, S2 ran end to end and
wrote a single complete result directory. Five defects found, four fixed:

| # | Defect | Status |
|---|--------|--------|
| — | `preflight.sh` used `\s` in `sed -E` (BSD sed leaves the line unsubstituted) and let `ssh` eat the heredoc node list | fixed, `a957d12` |
| — | `roles/nfs-server` wrote `/etc/exports.d/*.exports` without creating the directory; Ubuntu 24.04's `nfs-kernel-server` does not ship it | fixed |
| D7 | `run_id` was a lazy `lookup('pipe', 'date ...')`, re-evaluated on every reference | fixed |
| — | `observer_informer_image` was `bitnami/kubectl:1.29`; Bitnami retired their public Docker Hub catalogue in 2025, so the informer Job sat in `ImagePullBackOff` | fixed |
| D10 | the informer recorded `informer_absent` in every snapshot after the image fix, while `trace_meta.json` called it ready | fixed |
| D8 | S2 never applies the workload it measures; the divergence ledger came back empty and was reported as `SINGLE_WRITER` | fixed (assertion + verdict); needs the workload re-applied to the lab |
| D9 | `script:` shipped check-invariants.sh to a temp dir, so `violation-duration.sh` was never found and every `duration_s` was null | fixed |

**Runs completed: S2 (twice), S11, S12 — all four `run_validity: OK`,
`fault_efficacy: EFFECTIVE`, zero task failures.** Results:

| Scenario | Verdicts | What it establishes |
|---|---|---|
| S2 `20260828_104635` | I1, I2, I3 VIOLATED; I5, I6, I9, I10 PRESERVED; I4 INSUFFICIENT_DATA | `postgres-stateful-0` running on worker1 **and** worker3 across 3 snapshots, confirmed node-locally |
| S11 `20260828_102436` | I3 VIOLATED; I6, I9 NOT_APPLICABLE; 4 PRESERVED | The D5 VIP fix works: worker1 now leaves `Ready=True` |
| S12 `20260828_103525` | all PRESERVED | The D5 flap fix works: `lease_holder_changed` fired |

**S2's headline result, which is what the NFS enrichment was for:**

```json
{"verdict": "UNFENCED_CONCURRENT_WRITES", "total_records": 946,
 "distinct_pod_uids": 2, "distinct_nodes": 2, "writer_alternations": 640,
 "concurrent_window": {"start": "08:52:46.133Z", "end": "08:58:08.216Z",
                       "overlapping": true}}
```

Two pod UIDs on two nodes under one StatefulSet identity, alternating 640 times
across a 5m22s overlapping window on one shared volume. That is two live
processes writing to the same volume with no fencing — the claim §3 argued the
paper actually wants — where the pre-fix run of the same scenario reported
`total_records: 0`.

**S11 is the sharper observer-relative finding.** I3 VIOLATED with worker1 at
`Ready=Unknown` while its containers keep running: declared-uncertain rather
than declared-failed, which is the I3b split §1's D2 entry proposed. Before the
D2 and D5 fixes this scenario reported an undisturbed cluster.

Note also that S11 and S12 return `NOT_APPLICABLE` where they used to inflate
the preserved count — the M4 vocabulary doing its job on live data.

What is now confirmed against hardware rather than assumed:

- **`run_id` is stable.** One S2 run, one result directory, holding the full
  set: seven snapshots, `trace_meta.json`, `run_index.txt`, `scenario_meta.json`
  and the node-local container captures.
- **The NFS server half of the S2 enrichment.** `postgres-shared-nfs` binds RWX
  with `Retain`, exported from worker3. The *workload* half does not work — see
  D8 — so dual-ownership harm is still unmeasured.
- **The pin play.** cordon → delete → wait → uncordon placed
  `postgres-stateful-0` on worker1 as intended.
- **The informer is created and named correctly** once `run_id` holds still —
  but it still records nothing; see D10.
- **The D8 assertion fires correctly in both directions.** It stopped the run
  against the stale workload, and after `playbooks/deploy-workloads.yml` it
  reported `containers=['postgres', 'divergence-writer'], shared
  PVC=postgres-shared-nfs`.
- **`violation-duration.sh` is reached** after D9, and answers structurally
  (`source: "trace:endpoints_not_ready"`) rather than with the old
  `"produced no output"`.
- **The trace recorder's safety design.** Recorders orphaned by the aborted run
  ran under `timeout --kill-after=30 1140` and expired on their own; the next
  run's trace-start reaped them, as its header claims.
- **Failure containment.** The aborted run left no cordons, no injected DROP
  rules and no informer Job. The lab returned to baseline without a revert.

**The first real duration — `I2 VIOLATED for 112 s`** (run `20260828_130606`),
one closed episode ended by an observed clear, `censored: false`, over a
901-record trace with an intact footer. This is what M1 and M4 were for, and it
took fixing D11 below to get there.

I1 and I3 remain `duration_s: null`, and correctly so: both decide from
node-local crictl container lists, which the 1 Hz trace does not record, and
`violation-duration.sh` says exactly that rather than inventing a number.
Extending duration coverage to them means recording container state in the
trace, which is a real cost and a separate decision.

One known footgun, already documented in the tree and left alone: the
`pkill -f` teardown tasks in `roles/fault-inject/tasks/teardown.yml` match the
calling shell's own argv and return `rc: -15`. `scenarios/s3/playbook.yml:207`
explains this and accepts it — the target dies regardless — but it does mean
teardown reports failures on every run, which is noise a real teardown failure
would hide in.

---

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

### D7 — `run_id` is re-evaluated on every reference, so one run scatters across many directories

`inventory/group_vars/all.yml:17`

```yaml
run_id: "{{ lookup('pipe', 'date +%Y%m%d_%H%M%S') }}"
```

Ansible group_vars are lazy: this is not a value assigned once at start, it is
an expression re-evaluated at every point of use. The lookup runs a fresh
`date` each time, so `run_id` changes whenever the clock crosses a second
boundary mid-play — which, over a scenario lasting minutes, is essentially
every reference.

Everything the suite writes is addressed through it:

```yaml
results_dir:          "{{ results_base }}/{{ scenario_id }}/{{ run_id }}"
informer_object_name: "{{ observer_informer_name }}-{{ scenario_id }}-{{ run_id | replace('_','-') | lower }}"
```

**Observed in the 2026-08-28 S2 run.** Four distinct values of `run_id` inside
one invocation:

| Consumer | Value it saw |
|---|---|
| `results_dir` (first write) | `20260828_095846` |
| `results_dir` (second write) | `20260828_095847` |
| `informer_object_name` at render | `…-095844` |
| `results_dir` at the final collection task | `20260828_095916` |

The run produced two result directories, holding one file and zero files:

```
results/s2/20260828_095846/   1 file
results/s2/20260828_095847/   0 files
```

**Impact**

- **Every scenario writes its artefacts into a scatter of sibling directories,
  most of them empty.** `check-invariants.sh` is pointed at one of them, so it
  sees a fraction of the snapshots at best.
- The in-cluster informer is created under one name and looked up under
  another. `trace-start.yml` renders the manifest to
  `{{ trace_remote_dir }}/{{ informer_object_name }}.yml`, then the next task
  `kubectl apply -f`s a path with a *different* timestamp and fails with
  `the path "..." does not exist`. The informer therefore never exists, and
  every snapshot records `informer_absent` — which is exactly the state M2 was
  written to eliminate, and it silently reduces every VIOLATED verdict to
  `duration_s: null`.
- Collection tasks delegated back to the observer fail with `Destination
  directory ... does not exist`, because the directory was created under an
  earlier stamp.
- Both informer failures are `ignore_errors: yes`, deliberately and for good
  reason (an observer that cannot be created should not abort a run with a
  fault already injected). The cost is that this defect is silent: the run
  reports `EXIT=0`.

**Why it was not caught earlier.** Nothing here is reachable offline. The
archived May 2026 results predate the trace and the informer entirely, and
`--syntax-check` cannot see a lazily-evaluated lookup.

**Fix.** `run_id` must be resolved once per invocation and then be constant.
Options, cheapest first:

1. Take it from the environment, which is stable for the life of the process:
   `run_id: "{{ lookup('env', 'K8SFS_RUN_ID') | default(lookup('pipe', 'date +%Y%m%d_%H%M%S'), true) }}"`,
   with `scripts/run-sweep-detached.sh`, `scripts/repeat-scenario.sh` and the
   README's step-4 invocation exporting it once. Leaves the bare ad-hoc
   `ansible-playbook` call still broken, so pair it with (3).
2. Pass it as an extra var (`-e run_id=$(date +%Y%m%d_%H%M%S)`). Extra vars are
   literals, evaluated once. Same caveat about ad-hoc runs.
3. Pin it in a `set_fact` in the first play of each scenario and push it to
   every host with `delegate_facts`. Correct regardless of how the playbook is
   invoked, but it is 23 files.

Whichever is chosen, add an assertion that the value is stable — a first-play
`set_fact` of `run_id` compared against `run_id` re-read in the last play — so
a regression here fails loudly instead of producing empty directories.

---

### D8 — S2 never applies the workload it measures, so its headline evidence is empty

Found on the 2026-08-28 shake-down, once D7 was fixed and S2 ran end to end for
the first time.

`scenarios/s2/playbook.yml` applies `roles/nfs-server`, which installs the
server, creates the `postgres-shared-nfs` PV and PVC, and binds them. It does
**not** apply `roles/k8s-install/files/postgres-stateful.yml`. The StatefulSet
is only ever applied by `playbooks/setup-cluster.yml`, at cluster build time.

So on a cluster built before the NFS enrichment landed — which is every cluster
that currently exists — S2 runs against the *old* workload:

```
running:  containers=[postgres]                     volumes=[{"emptyDir":{},"name":"data"}]
manifest: containers=[postgres, divergence-writer]  volumes=[shared → PVC postgres-shared-nfs]
```

The PVC binds and then nothing mounts it (`kubectl get pods -o json` → no pod
references any PVC). The `divergence-writer` sidecar, which is the only thing
that writes to the shared volume, does not exist in the running pod, so the
ledger is never written.

**Impact.** `divergent_writes.json` from that run:

```json
{"total_records": 0, "distinct_pod_uids": 0, "writers": [],
 "concurrent_window": {"overlapping": false}, "verdict": "SINGLE_WRITER"}
```

Zero records is *missing data*. It is reported as `SINGLE_WRITER`, whose own
embedded note glosses it as "only one copy ever wrote, so the run carries no
dual-ownership harm" — a substantive negative finding, drawn from a ledger no
process was ever able to write to. This is the exact failure mode D6 and M4
were written to prevent, reproduced in a new artefact that predates neither.

**Fix**, both halves needed:

1. S2 must guarantee the workload it measures. Either apply
   `postgres-stateful.yml` itself before pinning the pod, or assert that the
   running StatefulSet carries the `divergence-writer` container and a
   `persistentVolumeClaim` volume, and fail the run as `FAULT_INEFFECTIVE` if
   not. An assertion is preferable: it keeps scenario and deployment concerns
   separate and names the problem instead of silently mutating the cluster
   mid-suite.
2. `divergent_writes.json` needs the same verdict discipline as the invariants:
   `total_records == 0` is `INSUFFICIENT_DATA`, never `SINGLE_WRITER`.
   `SINGLE_WRITER` should require at least one parsed record from exactly one
   writer.

**Also worth checking during the fix.** The suite has no general assertion that
the cluster's running workloads match the manifests in the tree. Any scenario
whose finding depends on a workload detail is exposed the same way; S2 is
simply the one where the gap was visible, because its evidence file came back
empty rather than merely wrong.

---

### D9 — `script:` breaks check-invariants.sh's sibling lookup, so no VIOLATED verdict ever gets a duration

Found on the 2026-08-28 shake-down, in the first run that had a 1 Hz trace to
measure against.

Every scenario invoked the checker the same way:

```yaml
- script: ../../scripts/check-invariants.sh {{ results_dir }}
```

Ansible's `script:` module copies **that one file** to a temp directory on the
target and executes it there. `check-invariants.sh:77` then resolves

```bash
SELF_DIR=$(cd "$(dirname "$0")" && pwd)     # → ~/.ansible/tmp/ansible-tmp-…
```

and line 249 looks for a sibling that was never copied:

```bash
duration=$(bash "$SELF_DIR/violation-duration.sh" "$RESULTS_DIR" "$inv" 2>/dev/null)
[ -n "$duration" ] || duration='{… "reason": "violation-duration.sh produced no output"}'
```

**Impact — M4's duration half is dead suite-wide.** Every VIOLATED verdict in
every scenario carries `duration_s: null` with reason `violation-duration.sh
produced no output`. From the 2026-08-28 S2 run:

```json
{"invariant":"I2","verdict":"VIOLATED","duration_s":null,
 "duration":{"source":"none","reason":"violation-duration.sh produced no output"}}
```

The script itself is fine. Run by hand against the same results directory it
returns two episodes for I2 off a 953-record trace. It was never reached.

Note what this defeats: the review's own argument for durations — "I1 violated
for 143 s" being a materially stronger result than "I1 VIOLATED" — was
implemented, and then silently produced nulls, with the null carrying a reason
string that reads like a data limitation rather than a wiring bug.

`roles/metrics-collect/tasks/trace-stop.yml:238` already got this right for
`observer-disagreement-duration.sh`, invoking it through `{{ role_path }}/../..`;
`disagreement_duration.json` is written correctly in the same run where every
`duration_s` is null.

**Fix (applied).** Run the checker in place rather than shipping it to a temp
dir. All 22 scenarios now use:

```yaml
- command: "{{ repo_dir }}/scripts/check-invariants.sh {{ results_dir }}"
```

with `repo_dir: "{{ inventory_dir | dirname }}"` in `group_vars/all.yml`.
Derived from the inventory, not from `playbook_dir`: an imported playbook
reports the *top-level* playbook's directory, so `playbook_dir` would be wrong
for `playbooks/run-all-scenarios.yml`, which is the sweep that matters most.
The observer is `localhost ansible_connection=local`, so the repo path is
always reachable. The scripts are now executable in git as well.

**Worth checking during any follow-up:** whether any other script invoked
through `script:` reaches for a sibling. This was found only because a trace
existed to compare against — with no trace, the null is indistinguishable from
the honest "this run predates M1" null the script is designed to emit.

---

### D10 — The in-cluster informer records `informer_absent` in every snapshot, while trace_meta reports it healthy

**Fixed 2026-08-28.** Found on the shake-down; the image change described
below was necessary but not sufficient, and was itself wrong.

The informer's original failure was its image: `observer_informer_image` was
`bitnami/kubectl:1.29`, and Bitnami retired their public Docker Hub catalogue
in 2025, so the Job sat in `ImagePullBackOff`. That is fixed — the image is now
`registry.k8s.io/kubectl:v1.36.1`, verified pullable with `crictl pull` from a
node, and the Job is created under the right name.

It still produces nothing. From the S2 run of 2026-08-28 (`20260828_104635`),
every snapshot, pre-fault included:

```json
{"ok": false, "reason": "informer_absent", "source": null,
 "job": "k8s-obs-informer-s2-20260828-104635"}
```

`informer_tail.jsonl` is 1 byte. Meanwhile `trace_meta.json` reports the
informer as `{"created": true, "ready": true}`, so nothing in the run's own
output says the observer is missing except the snapshots themselves.

**Impact.** The in-cluster informer is one of the six observers M2 specifies,
and the only one representing a cached client view — the observer most likely
to lag, which is precisely what the paper's disagreement matrix is about. Every
run to date has been missing it. The per-API-server views, the etcd view and
the node-local crictl views all work (see the shake-down section), so this is
one observer of six, not the whole of M2.

**Root cause — two independent defects.**

*The image could not run the script.* `registry.k8s.io/kubectl` is Kubernetes'
distroless go-runner image: it ships the `kubectl` binary and nothing else, no
`/bin/sh`. `informer.yml.j2` runs `command: ["/bin/sh", "-c"]` with the
observation loop as `args`. The container therefore never started:

```
State:      Terminated
  Reason:   StartError
  Message:  ... exec: "/bin/sh": stat /bin/sh: no such file or directory
  Exit Code: 128
```

Reproduced independently with a bare `kubectl run` against that image, so it is
the image and not anything specific to the Job template. The earlier swap away
from the retired `bitnami/kubectl:1.29` fixed the pull and broke the exec.

*The readiness check could not fail.* `trace-start.yml` computed

```yaml
"ready": {{ ('READY' in (informer_ready.stdout | default(''))) | ternary('true','false') }}
```

against a wait that echoes `READY` or **`NOT_READY`** — and `'READY' in
'NOT_READY'` is `True`. The field was therefore `true` unconditionally, which is
why `trace_meta.json` reported a healthy informer for a pod that never ran. A
detector that cannot fail, the same class as D2 and D3.

**Two further defects surfaced while fixing those**, both pre-existing and both
verified against the pristine `registry.k8s.io/kubectl` binary as well:

- `--request-timeout` breaks kubectl's in-cluster config auto-detection in this
  client version — the call falls back to `http://localhost:8080` and fails. The
  flag is gone from the read wrapper; `timeout(1)` is now the sole per-read
  bound. Note the trade-off recorded in the template: with no `timeout` on
  PATH there is now no bound at all, acceptable only because the image is
  pinned to one that ships GNU coreutils.
- This client emits `Warning: v1 Endpoints is deprecated…` on stderr for every
  endpoints read, and the wrapper merges stderr into stdout to classify
  NotFound. The warning text was landing inside the emitted JSON and corrupting
  it. A `nowarn()` filter strips it.

**Fix.** Image is `quay.io/openshift/origin-cli:4.22`, which carries both
`kubectl` and a real shell with GNU `date %3N`; CPU limit raised 200m → 500m
after measuring the newer client at 0.9–2.0 s per call under the old limit
against an ~0.84 s budget. Readiness now polls until `kubectl logs --tail=1`
returns a line satisfying the same `has("answers")` predicate `snapshot.yml`
uses, and on timeout writes `informer_diagnostic.json` into the results
directory with the pod phase and each container's terminated reason and exit
code — so a future silent informer leaves an artefact naming its cause instead
of a bare `informer_absent`.

**Verified against the live cluster**, by rendering the real template through
Ansible and applying it:

```json
{"ts":"2026-08-28T09:48:09.933Z","ts_epoch_ms":1787910489937,
 "source":"https://kubernetes.default.svc",
 "read_mode":"in_cluster_serviceaccount_linearizable",
 "resource_versions":{"node":"132879","pod":"125163","endpoints":"118539"},
 "answers":{"node_ready":{"state":"answered","answer":"True","reason":null}, …}}
```

Run through `snapshot.yml`'s own collection logic, that line yields
`{"ok":true,"reason":null,"source":"https://kubernetes.default.svc","cache_age_ms":5424}`
— the observer M2 has been missing in every run to date.

---

### D11 — The I2 trace predicate watched one service; the check it bounds sums over two

Fixed 2026-08-28.

`scripts/violation-duration.sh` documents each trace predicate as "a strict
subset of the corresponding `check_i*()` predicate". For I2 that was true of the
*field* and false of the *scope*.

- `check_i2` sums `notReadyAddresses` over every service in the snapshot's
  `endpoint_states`, which `tasks/snapshot.yml` populates from **two** services:
  `nginx-stateless` and `postgres-stateful`.
- The 1 Hz recorder ran `kubectl get endpoints {{ stateless_app_name }}` — the
  stateless service alone.

So a not-ready endpoint on the stateful service was invisible to the trace. In
S2 the partitioned pod *is* the stateful one, so that was every violation. From
run `20260828_124524`:

```
snapshot_t_plus_30:  nginx-stateless   ready=1 notReady=0
                     postgres-stateful ready=1 notReady=1   ← the violation
trace.jsonl:         894 records, not_ready_count = 0 in every one
```

The invariant came back `VIOLATED` from the snapshots and
`no_episode_in_trace: the snapshot series recorded a violation the trace never
saw (the two sample different instants)` from the duration engine — a reason
that reads as a sampling-resolution limit and is actually a scope bug.

**Why it looked non-deterministic.** An earlier run of the same scenario *did*
find two I2 episodes. That run predated `playbooks/deploy-workloads.yml`, when
all three nginx pods still happened to sit on worker1, so partitioning worker1
did put nginx endpoints not-ready. The apparent flakiness was pod placement.

**Fix.** The recorder now queries both services, matching the snapshot exactly.
`.endpoints.not_ready_count` and `.ready_count` stay top-level and become sums,
so the predicate reading them is unchanged; per-service detail moves under
`.services[]`, and the `List` that `kubectl get` returns for a multi-name query
is unwrapped. The `covers` string now states the scope. `tasks/snapshot.yml` had
the two service names hardcoded beside the variables that already define them —
de-hardcoded, since two places naming one set with one of them hardcoded is how
this drifts apart again.

**Verified live.** Mid-fault the trace recorded 112 consecutive records with
`not_ready_count: 1` on `postgres-stateful`, and the report closed them into a
single 112 s episode with `end_reason: clear_observed`.

---

### Step 3 — S20–S28 validated singly, 2026-08-28

All nine gray-failure scenarios executed for the first time, one
`ansible-playbook` process each, with `playbooks/_health-check.yml` between them
and a gate that stops the sequence rather than run later scenarios against a
degraded lab. The gate fired once, after S26.

| Scenario | Ran | Efficacy | Violations | Note |
|---|---|---|---|---|
| S20 pod-network partition | yes | EFFECTIVE | **I2, `duration_s` 19.011** | Exactly the signature §3 predicted: data plane dead, every node Ready |
| S21 VIP split-brain | yes | EFFECTIVE | none | `split_observed: true`, `max_simultaneous_vip_holders: 2` |
| S22 runtime/kubelet freeze | yes | EFFECTIVE | none | `target_process_frozen` fired |
| S23 etcd NOSPACE | **fault aborted** | EFFECTIVE (wrongly) | I5 | D12 |
| S24 admission webhook | yes | EFFECTIVE | none | Fail/Ignore contrast reproduced |
| S25 APF starvation | **no** | — | — | D13, aborted before injection |
| S26 node object deleted | **left lab degraded** | EFFECTIVE | I2 | D14 |
| S27 clock skew | yes | EFFECTIVE | I3 | `clock_offset_applied`, offset still held mid-window |
| S28 stale etcd member | yes | EFFECTIVE | none | `etcd_members_dropped` fired |

Six of nine execute their fault correctly on first run. Three do not, and are
recorded as D12–D14 below.

**Two scenarios prove their fault and violate nothing.** S21 demonstrably put
two nodes on the API VIP at once and S22 demonstrably froze the runtime, yet
every invariant came back PRESERVED or NOT_APPLICABLE. That is not a failed run:
it is the invariant set having no detector for either condition. Whether to add
one is a question for the paper — but "EFFECTIVE, no violations" should not be
read as "nothing happened".

**`require_proposed` is advisory, and S23 shows the cost.** The suite already
emits the signals a scenario *would* assert if the vocabulary supported them —
S23 emitted `require_proposed: ["cluster_writes_rejected", "etcd_alarm_armed"]`
with `require_proposed_satisfied: false`, correctly identifying that its own
fault never happened — but nothing consumes that field, so the run still
reported `EFFECTIVE`. Promoting `require_proposed` to binding once its signals
are implemented is the smallest change that would have caught D12 automatically.
Note this is NOT a claim that the efficacy gate is generally vacuous: `required`
comes from `fault_efficacy_defaults` keyed by fault class, and
`roles/fault-inject/defaults/main.yml` explains why most gray-failure classes
deliberately declare none — asserting "the cluster visibly reacted" would mark a
correctly-executed gray-failure run FAULT_INEFFECTIVE.

---

### D12 — S23's fault never executes: `etcdctl` refuses `ETCDCTL_ENDPOINTS` alongside `--endpoints`

Open. S23 aborts mid-fault, immediately after lowering the backend quota and
restarting the target member:

```
etcdctl --endpoints=https://10.0.0.56:2379 endpoint status
{"level":"fatal","msg":"conflicting environment variable is shadowed by
 corresponding command-line flag (either unset environment variable or disable
 flag))","environment-variable":"ETCDCTL_ENDPOINTS"}
```

etcd 3.5.30's `etcdctl` treats an environment variable shadowed by its
command-line equivalent as fatal. The play sets `ETCDCTL_ENDPOINTS` in the task
environment *and* passes `--endpoints`.

The run then jumps to teardown and completes: quota drop-in removed, ballast
removed, alarms disarmed, safety net confirming the cluster writable. The lab is
left clean — but the NOSPACE phase never ran. Evidence: no mid-fault snapshot at
all (`pre_fault` → `post_clear_t30`), no `rw_contrast_nospace_*.json`, and
`etcd_alarm_armed: null`.

It nonetheless reported `EFFECTIVE` off an incidental `lease_holder_changed`,
and produced a full invariant set including I5 VIOLATED — verdicts describing a
cluster whose intended fault never occurred.

**Fix.** Either drop `--endpoints` and let the environment variable stand, or
clear it for the invocation (`env -u ETCDCTL_ENDPOINTS etcdctl --endpoints=…`).
Audit every `etcdctl` call in the suite for the same shadowing, not just this
one. Then make `require_proposed` binding so a repeat cannot pass as EFFECTIVE.

---

### D13 — S25's FlowSchema is rejected by the API server, so it never injects

Open. S25 fails at its first apply and never reaches injection:

```
The FlowSchema "s25-flood" is invalid:
spec.rules[0].resourceRules[0].namespaces: Required value:
resource rules that are not cluster scoped must supply at least one namespace
```

`scenarios/s25/playbook.yml:260` declares `verbs/apiGroups/resources: ["*"]` with
neither `namespaces` nor `clusterScope`. A `resourceRule` must supply one or the
other.

Teardown ran and verified no flood process survived on any worker, and the
health check passed, so nothing is left behind — but the scenario has never
injected anything. It produced no results directory and no invariant report.

**Fix.** Add `namespaces: ["*"]` and `clusterScope: true` to the resource rule.
Both are needed for a client whose requests span namespaced and cluster-scoped
resources.

---

### D14 — S26 leaves the lab a node short: the kubelet does not re-register on its own

Open, and the most consequential of the three.

S26 deletes the Node object while the kubelet keeps running, then waits up to
300 s for it to re-register. It does not. The kubelet stays `active` and retries
a status *update* for an object that no longer exists:

```
kubelet_node_status.go:479 "Error updating node status, will retry"
  err="error getting node \"worker1\": nodes \"worker1\" not found"
```

`systemctl restart kubelet` re-registers it immediately, under a **new** Node
object (`AGE 1s`, new uid).

**This is arguably S26's result rather than only its bug.** §3 proposed S26 to
probe "identity re-creation with a live substrate"; what it found is that the
substrate does *not* re-create the identity on its own — a kubelet whose Node
object is deleted wedges rather than re-registering. That is a sharper finding
than the scenario was written to expect, and it is the reason
`node_identity_recreated` never fires.

**The failure handling is exemplary and should be copied**, not changed: S26
detected its own non-recovery and aborted loudly —

```
S26 DID NOT RECOVER — THE LAB IS LEFT DEGRADED
The cluster is now short one node and EVERY LATER SCENARIO WILL MEASURE …
```

— and the inter-scenario health gate independently stopped the sequence. Without
both, S27 and S28 would have run against a five-node cluster and produced
plausible, wrong results.

**Fix.** S26's recovery step must restart the kubelet rather than wait for a
re-registration that does not come, and the scenario should record the fact that
a restart was required as evidence, since that *is* the finding. Until then S26
must not be run unattended.

---

### Full-suite validation — 2026-08-28/29: all 23 scenarios execute their fault

Every scenario now runs end to end with `run_validity: OK` and
`fault_efficacy: EFFECTIVE`, verified on the live lab:

```
s1  s2  s3  s4  s5  s6  s8  s11 s12 s14 s15 s17
s18 s19 s20 s21 s22 s23 s24 s25 s26 s27 s28      — 23/23 OK / EFFECTIVE
```

Getting there took **16 further defects (D12–D27)** beyond the six already
recorded above. Three patterns are worth carrying forward.

**Most "scenario failures" were not scenario failures.** S3 and S5 were each
recorded as broken when they had inherited a dead API server from the scenario
before them (D20, D21). S5's own defect (D25) only surfaced once the harness
was fixed and it could run far enough to reach it. Sequential sweeps
mis-attribute damage to whatever runs next, so an inter-scenario gate has to be
strong enough to stop that — which is why D21 repairs *and* asserts, and why it
demands stable health rather than one 200.

**Silent teardown loss was the most dangerous class.** D20: Ansible's
unreachable marker is sticky across plays, so one dropped ssh connection during
a fault window silently removed a host from its own teardown play. S1 finished
`failed=0` having left seven DROP rules on cp1, killing its API server and the
VIP with it. 22 of 23 scenarios were exposed; only S23 had the guard, and
`_health-check.yml` had documented the hazard all along.

**A scenario that runs is not a scenario that measures.** S25 needed five fixes
before it injected anything (D13, D15, D17, D18) and a sixth (D19) before APF
actually shed load — it had been reporting a clean run with 750 requests, every
one a 200. S6 was worse: it ran cleanly, produced five iterations, and fed the
suite's **first ever evaluable I4** — off a partition that never touched the
node, because it omitted the API VIP (D27). `i4_verdict: PRESERVED, all
readable repetitions converged` was five repetitions of an undisturbed cluster.
With the VIP blocked, worker1 now goes `Unknown` mid-fault in every iteration,
all five report EFFECTIVE, and I4 PRESERVED means something.

**I4 is now evaluable for the first time in the suite's history**, from S6's
five repetitions: `run_count: 5, runs_unreadable: 0, unique_final_states: 1,
deterministic_recovery: true`.

Two things deliberately left alone, both recorded rather than fixed:

- `scenarios/s6/run-one.yml` initialises `run_comparison.json` to `[]` and
  nothing ever writes it. Nothing reads it either — `aggregate-results.sh`
  computes recovery variance from `run_summary.json` — so it is inert, but it
  should not be read as "compared, found nothing".
- The `pkill -f` self-match in `roles/fault-inject/tasks/teardown.yml`, already
  documented at `scenarios/s3/playbook.yml:207`. Harmless there because the
  target dies anyway and the rc is ignored; D18 was the same bug in a place
  where it *was* load-bearing, and that one is fixed.

---

### Rebuild-path defects — 2026-08-29 (D28–D30, all open)

Found while rebuilding the lab. None affect scenario results; all three break
the documented path to a working cluster, which matters because that path is
the one used after any lab loss.

**D28 — `terraform apply` never runs Ansible.** `scripts/redeploy-cluster.sh`
documents its second step as "provision fresh VMs, write the inventory, and run
playbooks/setup-cluster.yml on top". `terraform/ansible.tf` contains a single
`local_file` resource that writes `inventory/hosts.ini` — no provisioner, no
`local-exec`, no `ansible-playbook`. The script therefore leaves 11 bare Ubuntu
VMs and reports "Cluster rebuilt from scratch." Either wire the playbook in or
correct the header and have the script invoke it directly.

**D29 — a fresh install always fails `deploy-workloads`, and the failure
cascades.** `roles/k8s-install/tasks/control-plane-init.yml:83` includes
`deploy-workloads.yml`, which applies a 3-replica nginx Deployment and then
waits for its rollout — while the only node in the cluster is the
still-tainted first control-plane node. The wait times out (3 attempts, 2 min
each), cp1 is marked failed, and Ansible drops it from every later play. The
NFS play then skips creating the PV and PVC, because that task is gated on
`inventory_hostname == ansible_play_hosts_all[0]` and that host is cp1. The run
ends with `postgres-stateful-0` Pending on a PVC that was never created, and
nothing says so. Re-running the playbook fixes it, since the workers have
joined by then — which is how this was recovered, but it should not need two
passes. Either move workload deployment after the worker-join play, or drop the
rollout wait to a `wait_for` that tolerates zero schedulable workers.

**D30 — `Install kubectl on observer` assumes a Linux package manager.** It
fails on the macOS control machine with
`{"cmd": "update", "msg": "[Errno 2] No such file or directory: b'update'"}`.
Harmless in practice — kubectl is already present there — but it puts a
`failed=1` on every setup run and trains the operator to ignore failures in the
recap, which is exactly how D29 stayed invisible.

**Also confirmed here:** the sshd watchdog added in `cec17cd` works. Eleven
fresh clones from the rebuilt template all came up with sshd listening within
15 s, against 3 of 11 on the previous image, with four of those unrecoverable.

---

### D31 — the inter-iteration health gate passes on a cluster with two API servers down

Open. Observed three times during the 2026-08-29 N=5 campaign, always after S3
(etcd latency).

S3's teardown restores connectivity but does not wait for the API servers to
finish reconnecting to etcd. They crashloop for a while afterwards; sometimes
they recover on their own, and sometimes they do not. On the third occurrence
cp2 and cp3 were both serving nothing (`/healthz` → 000) while cp1 answered
200 — and `playbooks/_health-check.yml` reported **passed**.

That is the D21 repair failing to fire. Its play probes each control-plane
node's own `/healthz` and restarts the kubelet wherever the API server is not
serving, and the action is right: restarting kubelet by hand on cp2 and cp3
brought all three back in 30 s, exactly as the play would have. The likely
cause is the `ignore_unreachable: yes` on that play — a node that is
momentarily unreachable mid-fault has its tasks skipped, and the play still
reports success, so the gate passes over precisely the hosts it exists to
repair.

**Why it matters more than it looks.** The batch is deliberately configured to
record a failure and carry on, so the gate is not what stops a bad run — but a
gate that reports "passed" on a two-thirds-dead control plane means every
scenario after it measures the previous scenario's wreckage, and the run-level
record says nothing was wrong. `cluster_health.json` (added in `c0b50c8`,
corrected in `3d2da48`) catches it independently, which is why the campaign can
continue safely: `started_degraded` marks the affected runs for analysis. But
the gate itself should not be trusted until this is fixed.

**Fix.** Drop `ignore_unreachable` from the repair play, or keep it and assert
afterwards that every control-plane node reported 200 — failing the play when
any did not, rather than when the play merely finished. Then give S3 an
explicit post-teardown wait for its API servers, so the repair is a backstop
rather than the normal path.

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

1. **Fix D7 first — nothing below can run until it is done.** The 2026-08-28
   shake-down got as far as S2 and stopped there; see *Shake-down run* above.
2. **Shake-down run.** `scripts/preflight.sh`, then a single pass over S2, S11
   and S12 only. These three carry the changes most likely to be wrong on
   contact: the in-cluster probe, the per-API-server views, the S11 VIP block
   and the S12 etcd-peer flap. Confirm `.observers[]` arrives populated, that
   S11 moves worker1 out of `Ready=True`, and that S2's two postgres copies
   both mount the NFS PV. Nothing downstream is worth running until this passes.
3. ~~**Validate the new scenarios once each.**~~ Done 2026-08-28; see *Step 3*
   above. Six of nine execute correctly. Fix D12 (S23), D13 (S25) and D14 (S26)
   and re-validate those three before the sweep — S26 in particular must not be
   run unattended, as it leaves the cluster a node short.
4. **Full sweep at N = 1.** Every scenario has now been run singly and comes
   back OK / EFFECTIVE (see *Full-suite validation* above), so the sweep is no
   longer a hunt for broken scenarios — it is the first coherent N = 1 dataset.
   Run `scripts/run-sweep-detached.sh`, rebuild the report, and read the
   heatmap for detectors that fail the calibration gate; `DETECTOR_INVALID` at
   this stage is a bug in the check, not a finding.
5. **Final collection at N ≥ 5.** `scripts/repeat-scenario.sh` per scenario,
   which is what makes I4 evaluable and turns the M4 durations into medians and
   IQRs rather than single observations. Budget the lab time: 23 scenarios at
   five runs is the largest single cost remaining in the project.
6. **Retire the archived data.** Once the new sweep exists, delete or clearly
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
