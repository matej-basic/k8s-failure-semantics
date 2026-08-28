#!/bin/bash
# scripts/check-invariants.sh
# Evaluates the paper invariants against a set of snapshot JSON files.
# Usage: check-invariants.sh <results_dir>
#
# Outputs a JSON report with per-invariant verdicts across all snapshots.
#
# Invariants checked (I7 and I8 are deliberately absent — see README.md):
#   I1  — Exclusive authority (no two simultaneous owners/leaders)
#   I2  — Reachability publication (endpoints match actual backends)
#   I3  — Failure declaration consistency (declared-failed nodes not still active)
#   I4  — Recovery coherence (repetitions of one fault converge to one state)
#   I5  — Observation-action consistency (no action on provably stale state)
#   I6  — Observation monotonicity (no observer reads an older state than it has)
#   I9  — etcd quorum coherence (membership, quorum and leader view agree)
#   I10 — Reconciliation termination (controllers stop generating new work)

set -euo pipefail

RESULTS_DIR="${1:-/opt/k8s-results}"

if [ ! -d "$RESULTS_DIR" ]; then
  echo '{"error": "results_dir_not_found", "path": "'"$RESULTS_DIR"'"}' >&2
  exit 1
fi

# ── helpers ────────────────────────────────────────────────────────────────────

# Evaluation order is chronological, never lexical.
#
# This used to be `ls snapshot_*.json | sort`, which orders by filename. For a
# run labelled pre_fault / t_plus_30 / … / post_fault_t240 that yields
#     post_fault_t120, post_fault_t240, post_fault_t30, pre_fault,
#     t_plus_120, t_plus_180, t_plus_240, t_plus_30, t_plus_60
# — the post-fault tail first, and t+120 before t+30. Every check that compares
# consecutive snapshots (I5, I6) or identifies the first/last post-fault
# snapshot (I10, divergence_timing) was reading a shuffled trace. I6 reported a
# monotonicity violation in every scenario of the May 2026 sweep purely because
# etcd revisions do not increase in filename order.
#
# Order key: .snapshot_index, emitted by metrics-collect since this fix, with
# .timestamp as the fallback for runs recorded before it. Both come from the
# observer's clock, so a clock-skew fault on a cluster node cannot reorder the
# trace. CALIBRATION_MODE=1 restricts the set to the baseline snapshot alone —
# see the calibration gate in the assembly section.
# snapshots_in() is the same ordering for an ARBITRARY run directory: I4 has to
# read the sibling iterations of a repeated batch, not just its own run.
snapshots_in() {  # $1 = a run directory
  local dir="$1" f idx ts
  for f in "$dir"/snapshot_*.json; do
    [ -e "$f" ] || continue
    idx=$(jq -r '.snapshot_index // empty' "$f" 2>/dev/null || echo "")
    ts=$(jq -r '.timestamp // empty' "$f" 2>/dev/null || echo "")
    [[ "$idx" =~ ^[0-9]+$ ]] || idx=9999
    [ -n "$ts" ] || ts="9999-99-99T99:99:99Z"
    printf '%04d\t%s\t%s\n' "$idx" "$ts" "$f"
  done | LC_ALL=C sort -k1,1 -k2,2 | cut -f3
}

snapshots() {
  local list
  list=$(snapshots_in "$RESULTS_DIR")
  [ -n "$list" ] || return 0
  if [ "${CALIBRATION_MODE:-0}" = "1" ]; then
    echo "$list" | sed -n 1p
  else
    echo "$list"
  fi
}

snap_field() {
  local file="$1"
  local query="$2"
  jq -r "$query" "$file" 2>/dev/null || echo "null"
}

SELF_DIR=$(cd "$(dirname "$0")" && pwd)

# ── Fault class ────────────────────────────────────────────────────────────────
# Which fault this run injected. Primary source is the scenario's own
# scenario_meta.json (.fault_type), written by roles/fault-inject and by the
# nine gray-failure scenarios directly.
#
# S27 writes fault_type "clock_skew" plus a variant, while the efficacy
# defaults table names the negative variant "clock_skew_negative"; the two are
# reconciled here so the applicability table can be keyed on one vocabulary.
#
# FALLBACK_FAULT_CLASS covers runs recorded before scenario_meta.json existed —
# which is every run in results/. The mapping is scenario_id -> fault class and
# is taken from the fault each playbook actually injects, so an archived run is
# judged by the same table as a fresh one. The report always says which source
# was used; a run whose class cannot be resolved gets "unknown", and "unknown"
# has no rows in the applicability table, so nothing is ever marked
# NOT_APPLICABLE on a guess.
FALLBACK_FAULT_CLASS='
s1|network_partition
s2|network_asymmetric
s3|etcd_latency
s4|clock_skew
s5|network_partition
s6|network_asymmetric
s8|composed_latency_partition
s11|kubelet_api_partition
s12|network_flap
s14|api_watch_lag
s15|pod_delete
s17|etcd_compact
s18|memory_pressure
s19|etcd_quorum_split
s20|pod_network_partition
s21|vrrp_vip_split
s22|process_freeze
s23|etcd_nospace
s24|admission_webhook_timeout
s25|apf_priority_starvation
s26|node_object_deleted
s27|clock_skew_negative
s28|etcd_stale_member
'

FAULT_CLASS="unknown"
FAULT_CLASS_SOURCE="unresolved"

resolve_fault_class() {
  local meta="$RESULTS_DIR/scenario_meta.json"
  local ft variant sid

  if [ -f "$meta" ]; then
    ft=$(jq -r '.fault_type // empty' "$meta" 2>/dev/null || echo "")
    variant=$(jq -r '.variant // empty' "$meta" 2>/dev/null || echo "")
    if [ -n "$ft" ]; then
      if [ "$ft" = "clock_skew" ] && [ "$variant" = "negative" ]; then
        ft="clock_skew_negative"
      fi
      FAULT_CLASS="$ft"
      FAULT_CLASS_SOURCE="scenario_meta.json"
      return
    fi
  fi

  sid=$(snap_field "$(snapshots | sed -n 1p)" '.scenario_id // empty')
  # S6 writes sub-run ids ("s6_run3"), and any repeat harness that does the
  # same convention would too. The fault class is identical across iterations
  # of one scenario, so strip a trailing _run<N> before looking the row up.
  sid=$(printf '%s' "$sid" | sed 's/_run[0-9][0-9]*$//')
  if [ -n "$sid" ] && [ "$sid" != "null" ]; then
    ft=$(printf '%s\n' "$FALLBACK_FAULT_CLASS" | awk -F'|' -v s="$sid" '$1 == s { print $2; exit }')
    if [ -n "$ft" ]; then
      FAULT_CLASS="$ft"
      FAULT_CLASS_SOURCE="scenario_id_fallback"
      return
    fi
  fi
}

# ── NOT_APPLICABLE: invariant x fault class ────────────────────────────────────
# REVIEW.md M4. Some invariants cannot be broken by some faults — not because
# the cluster held them, but because the fault's mechanism never reaches the
# subsystem the invariant observes. Reporting those cells PRESERVED counts a
# question that was never asked as a question that was answered, and that is
# what inflates the preserved column and, through it, the violation rate's
# denominator.
#
# The admission rule, applied to every row below and to nothing else:
#
#   An invariant is NOT_APPLICABLE to a fault class when the fault cannot, even
#   in principle, produce the state the invariant forbids, because the
#   subsystem the invariant reads is outside the fault's blast radius.
#
# It is deliberately narrower than "we did not expect this one to fire". An
# invariant that could have fired and did not is a genuine PRESERVED and stays
# one. Where a fault's reach depends on a variant or a target the meta file
# does not pin down, the cell is left applicable — a missing NOT_APPLICABLE
# costs one over-counted PRESERVED, a wrong one silently discards a finding.
#
# Format: fault_class|invariant|reason
NOT_APPLICABLE_MAP='
kubelet_api_partition|I6|blocks the worker kubelet from the API servers; the observer reads etcd revisions directly from the etcd members over an untouched network, so no read of an older state is reachable
kubelet_api_partition|I9|etcd membership, peer traffic and client certificates are untouched — only a worker-to-apiserver path is dropped
memory_pressure|I6|memory is consumed on a worker node; the etcd members and the observer path to them are untouched
memory_pressure|I9|the fault never reaches an etcd member, so members cannot drop below quorum or split their leader view
pod_delete|I3|deleting one application pod cannot change any Node Ready condition or NoExecute taint, so the control plane never withdraws vouching for a node
pod_delete|I6|a single object delete advances the revision; it cannot make the observer read an older one
pod_delete|I9|etcd membership is untouched by an application-object delete
api_watch_lag|I6|a delay on the controller node watch stream does not touch the observer etcd read path
api_watch_lag|I9|etcd membership is untouched; only one client watch stream is delayed
pod_network_partition|I3|the management network is deliberately left intact so the kubelet keeps heartbeating; the node stays Ready by construction and the control plane never withdraws vouching
pod_network_partition|I6|only the pod CIDR is dropped; etcd traffic runs on the untouched management network
pod_network_partition|I9|etcd peers and clients are on the management network the fault leaves alone
vrrp_vip_split|I6|VRRP advertisements are blocked between keepalived peers; etcd peer and client traffic is untouched
vrrp_vip_split|I9|blocking the VRRP protocol cannot change etcd membership, leadership or raft term
process_freeze|I6|SIGSTOP is delivered to containerd or the kubelet on a worker; no etcd member is touched
process_freeze|I9|the frozen unit is on a worker, so etcd membership and quorum cannot be affected
admission_webhook_timeout|I6|packets to a webhook endpoint are dropped inside the API server admission path; the observer etcd read path is untouched
admission_webhook_timeout|I9|admission never reaches etcd membership; the members answer endpoint status directly
apf_priority_starvation|I6|APF shapes queues inside the API server; the etcd revision is read with etcdctl straight from the members, bypassing the API server entirely
apf_priority_starvation|I9|the flood cannot starve etcdctl endpoint status, which never traverses the API server
node_object_deleted|I6|deleting a Node object is an ordinary write that advances the revision; it cannot lower it
node_object_deleted|I9|an API delete cannot change etcd membership or leadership
clock_skew|I6|etcd revisions are a logical counter; moving a wall clock cannot make a revision decrease
clock_skew_negative|I6|etcd revisions are a logical counter; moving a wall clock backwards cannot make a revision decrease
etcd_nospace|I1|every write is rejected cluster-wide while the NOSPACE alarm is armed, so no controller can create a second copy of an existing pod identity
'

na_reason() {  # $1 = invariant id -> prints the reason, or nothing
  printf '%s\n' "$NOT_APPLICABLE_MAP" \
    | awk -F'|' -v fc="$FAULT_CLASS" -v inv="$1" '$1 == fc && $2 == inv { print $3; exit }'
}

# Rewrite a verdict to NOT_APPLICABLE when the table says the invariant cannot
# be broken by this fault class. Applied AFTER the calibration gate, so a
# detector that was also disqualified at baseline keeps that record in
# measured_verdict and in the calibration block — no evidence is discarded,
# the cell is only removed from the counted population.
apply_na() {  # $1 = invariant id, $2 = invariant JSON
  local inv="$1" full="$2" reason
  reason=$(na_reason "$inv")
  if [ -z "$reason" ]; then
    printf '%s' "$full"
    return
  fi
  printf '%s' "$full" | jq -c --arg fc "$FAULT_CLASS" --arg src "$FAULT_CLASS_SOURCE" --arg why "$reason" '
    . + { verdict: "NOT_APPLICABLE",
          measured_verdict: .verdict,
          not_applicable: {
            fault_class: $fc,
            fault_class_source: $src,
            reason: $why,
            note: "The invariant was evaluated and its measured verdict is kept, but this fault cannot produce the state the invariant forbids, so the cell is excluded from the preserved/violated population instead of being counted as evidence of preservation."
          } }'
}

# Attach the two fields M4 asks for to every VIOLATED verdict.
#
#   first_violation_ts / first_violation_snapshot come from the FIRST element of
#   .violations, which every check appends in chronological snapshot order (the
#   ordering fix at the top of this file is what makes "first" mean first).
#   Checks whose violation has no single snapshot locus say so rather than
#   inventing one.
#
#   duration_s comes from scripts/violation-duration.sh, which reads the M1 1 Hz
#   trace and reuses M2's censoring rules. It is null with a reason whenever the
#   trace is absent — never 0. See that file for the per-invariant sources.
annotate_violated() {  # $1 = invariant id, $2 = invariant JSON
  local inv="$1" full="$2" verdict duration
  verdict=$(printf '%s' "$full" | jq -r '.verdict // ""' 2>/dev/null || echo "")
  [ "$verdict" = "VIOLATED" ] || { printf '%s' "$full"; return; }

  duration=$(bash "$SELF_DIR/violation-duration.sh" "$RESULTS_DIR" "$inv" 2>/dev/null)
  [ -n "$duration" ] || duration='{"duration_s": null, "source": "none", "reason": "violation-duration.sh produced no output"}'

  printf '%s' "$full" | jq -c --argjson dur "$duration" '
    ( [ (.violations // [])[] | select((.ts // null) != null) ] | first ) as $first
    | . + { first_violation_snapshot: ($first.snapshot // null),
            first_violation_ts: ($first.ts // null),
            first_violation_ts_note:
              (if $first == null
               then "no snapshot locus: this check does not attribute its violation to a single snapshot"
               else null end),
            duration_s: ($dur.duration_s // null),
            duration: $dur }'
}

# Order matters: annotate first, then re-label. A cell the table calls
# NOT_APPLICABLE whose measured verdict is VIOLATED keeps its first_violation_ts
# and its duration inside measured_verdict/violations, which is exactly the
# evidence that would prove the table row wrong.
finalize() {  # $1 = invariant id, $2 = invariant JSON
  apply_na "$1" "$(annotate_violated "$1" "$2")"
}

# ── I1: Exclusive authority ────────────────────────────────────────────────────
# Violation: the same pod identity (namespace/podName) has a CONTAINER_RUNNING
# container on more than one node at the same instant.
#
# Why node-local crictl, not the API view:
#   The previous implementation read .control_plane.pod_states — the API
#   server's `kubectl get pods`. That has a structural blind spot exactly
#   where the paper predicts the most interesting result:
#     * a container still running on a partitioned node the API has written
#       off is, by construction, absent from the API list;
#     * `group_by(.name)` can never collide for Deployment pods (unique
#       random suffix) and the API never lists a StatefulSet pod name twice.
#   So the API-side check returned PRESERVED by construction, not by
#   measurement.
#   This implementation instead groups every CONTAINER_RUNNING container in
#   .nodes[].containers (node-local crictl output, gathered by direct SSH to
#   each kubelet) by pod identity and counts the distinct nodes it runs on.
#   It does not depend on the API being able to see the partitioned node.
#
# Scope: this definitively catches StatefulSet dual ownership — a stable
# identity (postgres-stateful-0) recreated on n' while the original survives
# on n. Deployment over-replication (the ReplicaSet creating a 4th pod while
# an orphan still runs) is not caught here because each Deployment pod has a
# distinct name; that needs a desired-vs-actual replica count comparison and
# is left as a follow-up.

check_i1() {
  local violations=()
  local detail=()

  for snap in $(snapshots); do
    label=$(snap_field "$snap" '.snapshot_label')
    ts=$(snap_field "$snap" '.timestamp')

    # Primary: cross-node dual ownership from node-local crictl truth.
    # .nodes[].containers is a JSON *string* (crictl stdout); tolerate the
    # legacy "" / already-parsed-array forms, and dedupe hosts so the old
    # node_snapshots accumulation bug cannot inflate the node count.
    dup=$(jq -c '
      [ .nodes[]?
        | .host as $h
        | ( .containers
            | if type == "string" then (fromjson? // []) else (. // []) end )[]?
        | select(.state == "CONTAINER_RUNNING" and .podName != null)
        | { host: $h, identity: ((.podNamespace // "default") + "/" + .podName) }
      ]
      | group_by(.identity)
      | map({ identity: .[0].identity, nodes: (map(.host) | unique) })
      | map(select(.nodes | length > 1))
    ' "$snap" 2>/dev/null || echo '[]')
    dup_count=$(echo "$dup" | jq 'length' 2>/dev/null || echo 0)
    [ -z "$dup_count" ] && dup_count=0

    # Secondary: the API server itself ever listing a duplicate pod name.
    api_dupes=$(snap_field "$snap" '
      .control_plane.pod_states // [] |
      group_by(.name) | map(select(length > 1)) | length')
    { [ "$api_dupes" = "null" ] || [ -z "$api_dupes" ]; } && api_dupes=0

    if [ "$dup_count" != "0" ] || [ "$api_dupes" != "0" ]; then
      violations+=("$label")
      detail+=("{\"snapshot\": \"$label\", \"ts\": \"$ts\", \"cross_node_duplicate_identities\": $dup, \"api_duplicate_names\": $api_dupes}")
    fi
  done

  if [ ${#violations[@]} -eq 0 ]; then
    echo '{"invariant": "I1", "name": "exclusive_authority", "verdict": "PRESERVED", "violations": []}'
  else
    DETAILS=$(IFS=','; echo "[${detail[*]}]")
    echo "{\"invariant\": \"I1\", \"name\": \"exclusive_authority\", \"verdict\": \"VIOLATED\", \"violation_count\": ${#violations[@]}, \"violations\": $DETAILS}"
  fi
}

# ── I2: Reachability publication ───────────────────────────────────────────────
# Violation: the published endpoint set does not match what actually serves —
# the API lists notReadyAddresses for the service, or a probe of the service
# fails while endpoints are still published.
#
# The probe used to run on the observer, which for this lab is the workstation
# running Ansible. ClusterIP CIDRs are not routable from there, so every
# snapshot of every scenario recorded "httpCode": 0 — including pre_fault —
# and I2 came back VIOLATED in 11 of 12 scenarios before any fault was
# injected. metrics-collect now runs the probe from inside the cluster and
# emits `httpCode: null` when the probe could not run at all. A null probe is
# missing evidence and is skipped here; a probe that ran and failed (0, 5xx)
# still counts. The calibration gate disqualifies I2 outright if it fails at
# baseline, so a regression of this kind can no longer be read as a result.

check_i2() {
  local violations=()
  local detail=()
  local probe_samples=0
  local probe_unavailable=0

  for snap in $(snapshots); do
    label=$(snap_field "$snap" '.snapshot_label')
    ts=$(snap_field "$snap" '.timestamp')

    not_ready_eps=$(snap_field "$snap" '
      .control_plane.endpoint_states // [] |
      [.[] | .notReadyAddresses // [] | length] | add // 0
    ')

    probe_code=$(snap_field "$snap" '.external_probe.httpCode // null')
    probe_source=$(snap_field "$snap" '.external_probe.probe_source // "unknown"')
    has_endpoints=$(snap_field "$snap" '
      .control_plane.endpoint_states // [] |
      [.[] | select(.service == "nginx-stateless") | .subsets // [] | length] |
      add // 0
    ')

    if [ -n "$not_ready_eps" ] && [ "$not_ready_eps" != "0" ] && [ "$not_ready_eps" != "null" ]; then
      violations+=("$label")
      detail+=("{\"snapshot\": \"$label\", \"ts\": \"$ts\", \"not_ready_endpoint_count\": $not_ready_eps}")
    fi

    if [ -z "$probe_code" ] || [ "$probe_code" = "null" ]; then
      probe_unavailable=$((probe_unavailable + 1))
    else
      probe_samples=$((probe_samples + 1))
      if [ "$probe_code" != "200" ] && [ "$has_endpoints" != "0" ] && [ "$has_endpoints" != "null" ]; then
        violations+=("${label}_probe")
        detail+=("{\"snapshot\": \"$label\", \"ts\": \"$ts\", \"probe_code\": $probe_code, \"probe_source\": \"$probe_source\", \"endpoints_listed\": $has_endpoints}")
      fi
    fi
  done

  if [ ${#violations[@]} -eq 0 ]; then
    echo "{\"invariant\": \"I2\", \"name\": \"reachability_publication\", \"verdict\": \"PRESERVED\", \"probe_samples\": $probe_samples, \"probe_unavailable_snapshots\": $probe_unavailable, \"violations\": []}"
  else
    DETAILS=$(IFS=','; echo "[${detail[*]}]")
    echo "{\"invariant\": \"I2\", \"name\": \"reachability_publication\", \"verdict\": \"VIOLATED\", \"violation_count\": ${#violations[@]}, \"probe_samples\": $probe_samples, \"probe_unavailable_snapshots\": $probe_unavailable, \"violations\": $DETAILS}"
  fi
}

# ── I3: Failure declaration consistency ────────────────────────────────────────
# Violation: the control plane has stopped vouching for a node — Ready is not
# "True", or the node carries the unreachable / not-ready NoExecute taint —
# while node-local crictl still reports CONTAINER_RUNNING containers on it.
#
# The previous implementation selected nodes whose Ready condition was
# "False". Kubernetes never sets False for a node it has lost contact with:
# the node controller sets Ready="Unknown" (reason NodeStatusUnknown) once the
# monitor grace period expires, and False means the kubelet is reporting *and*
# declaring itself unhealthy. So the check could not fire in the partition
# scenarios it exists for. In the May 2026 S2 run worker1 sits at Unknown for
# four consecutive snapshots with postgres and nginx containers running on it,
# and I3 was reported PRESERVED — the same "PRESERVED by construction" defect
# already fixed for I1, missed for I3 at the time.
#
# The verdict now records *how* the control plane withdrew its vouching,
# because the two cases are semantically different and the paper's argument
# turns on the difference:
#   declared_failed    — Ready=False, or an unreachable/not-ready NoExecute
#                        taint. The cluster has committed to the node being
#                        gone and will evict its pods.
#   declared_uncertain — Ready=Unknown. The cluster does not know. This is
#                        observer-relative uncertainty, not a failure
#                        declaration, and Kubernetes acts on it anyway.
#
# Node taints come from .control_plane.node_conditions[].taints, collected by
# metrics-collect since this fix; runs recorded before it simply have no taint
# evidence and are judged on the Ready condition alone.

check_i3() {
  local violations=()
  local detail=()

  for snap in $(snapshots); do
    label=$(snap_field "$snap" '.snapshot_label')
    ts=$(snap_field "$snap" '.timestamp')

    # Nodes the control plane no longer vouches for, each paired with the pod
    # identities crictl still reports as running there. .containers is a JSON
    # *string* (crictl stdout); tolerate the legacy "" / already-parsed forms.
    offenders=$(jq -c '
      def containers_of($h):
        [ .nodes[]?
          | select(.host == $h)
          | ( .containers
              | if type == "string" then (fromjson? // []) else (. // []) end )[]?
          | select(.state == "CONTAINER_RUNNING" and .podName != null) ];

      . as $snap
      | [ (.control_plane.node_conditions // [])[]
          | . as $n
          | ( [ $n.conditions[]? | select(.type == "Ready") | .status ][0] // "Missing" ) as $ready
          | ( [ ($n.taints // [])[]
                | select(.effect == "NoExecute")
                | select(.key == "node.kubernetes.io/unreachable"
                         or .key == "node.kubernetes.io/not-ready")
                | .key ] ) as $taints
          | select($ready != "True" or ($taints | length) > 0)
          | { node: $n.name,
              ready: $ready,
              taints: $taints,
              declaration: (if ($ready == "False") or (($taints | length) > 0)
                            then "declared_failed"
                            else "declared_uncertain" end),
              running_containers:
                ( $snap
                  | containers_of($n.name)
                  | map(((.podNamespace // "default") + "/" + .podName))
                  | unique ) }
          | select((.running_containers | length) > 0) ]
    ' "$snap" 2>/dev/null || echo "[]")

    count=$(echo "$offenders" | jq 'length' 2>/dev/null || echo 0)
    [[ "$count" =~ ^[0-9]+$ ]] || count=0

    if [ "$count" != "0" ]; then
      violations+=("$label")
      detail+=("{\"snapshot\": \"$label\", \"ts\": \"$ts\", \"nodes\": $offenders}")
    fi
  done

  if [ ${#violations[@]} -eq 0 ]; then
    echo '{"invariant": "I3", "name": "failure_declaration_consistency", "verdict": "PRESERVED", "violations": []}'
  else
    DETAILS=$(IFS=','; echo "[${detail[*]}]")
    BREAKDOWN=$(echo "$DETAILS" | jq -c '
      [ .[].nodes[].declaration ] | group_by(.) | map({(.[0]): length}) | add // {}
    ' 2>/dev/null || echo '{}')
    echo "{\"invariant\": \"I3\", \"name\": \"failure_declaration_consistency\", \"verdict\": \"VIOLATED\", \"violation_count\": ${#violations[@]}, \"declaration_breakdown\": $BREAKDOWN, \"violations\": $DETAILS}"
  fi
}

# ── I4: Recovery coherence ─────────────────────────────────────────────────────
# I4 asks whether independent repetitions of the SAME fault converge to the same
# post-fault state. That question cannot be answered inside one run: comparing
# two post-fault snapshots of a single run only says whether the lease holder
# rotated during observation (ordinary renewal does that all the time), not
# whether recovery is deterministic.
#
# What decides whether I4 is evaluable is therefore the LAYOUT ON DISK, never
# the scenario id. scripts/repeat-scenario.sh writes a repeated batch as
#
#     results/<sN>/<run_id>/repeat_manifest.json
#     results/<sN>/<run_id>/run_1/ … run_<K>/     ← one ordinary run each
#
# so when RESULTS_DIR's basename is run_<K> the batch root is its parent and the
# sibling run_<K> directories are the repetitions. Any scenario put through the
# harness gets a real cross-run I4; a single run gets INSUFFICIENT_DATA, which
# is what a single run deserves whether or not it is called s6. The old test
# (`[[ "$scenario" != s6* ]]`) hardcoded one scenario's private structure and so
# left I4 unevaluated suite-wide — REVIEW.md M3.
#
# Iteration directories are NOT zero padded, so they are sorted NUMERICALLY:
# run_10 comes after run_2, and `sort | tail -1` would put it before.
#
# ── The verdict here is PROVISIONAL inside a batch ─────────────────────────────
# Each iteration writes its own invariant_report.json at the end of its own run,
# so run_3 can only ever see runs 1–3, and only the last iteration sees the
# whole batch. The verdict OF RECORD for a batch is the one
# aggregate-results.sh recomputes at the batch root, where the batch is
# complete: aggregate_report.json → invariant_heatmap[].I4, with
# `I4_source: "batch_recompute"`, derived from the recovery_variance entry for
# the scenario (recovery_variance_s6 is the alias for s6's). Every per-iteration
# I4 computed inside a batch therefore carries `provisional: true` and says so
# in its note.

# Final post-fault state of ONE run directory, as a single comparable string.
# Generic across scenarios, in preference order:
#   1. run_summary.json .final_lease_holder  — S6 writes it; any scenario may
#   2. run_summary.json .final_pod_placement — canonicalised name@node list,
#      used only when there is no lease holder to compare
#   3. the chronologically last snapshot whose .snapshot_label starts with
#      "post_", else the chronologically last snapshot, read at
#      .control_plane.controller_manager_lease.holder
# Prints the empty string when nothing readable is there; the caller maps that
# (and a literal "unknown") to unreadable and keeps it OUT of the distinct-state
# count — counting "unknown" as a state of its own is what made an incomplete
# batch read as non-deterministic recovery.
i4_final_state() {
  local dir="$1" v snap last post label
  if [ -f "$dir/run_summary.json" ]; then
    v=$(jq -r '
      (.final_lease_holder // null) as $h
      | if ($h != null) and (($h | tostring) != "") and (($h | tostring) != "null")
        then ($h | if type == "string" then . else tojson end)
        else ( (.final_pod_placement // null)
               | if type == "array"
                 then ([ .[]? | ((.name // "?") + "@" + (.node // "?")) ] | sort | join(","))
                 else "" end )
        end' "$dir/run_summary.json" 2>/dev/null || echo "")
    case "$v" in
      ""|null|unknown) ;;
      *) printf '%s\n' "$v"; return 0 ;;
    esac
  fi

  last=""; post=""
  for snap in $(snapshots_in "$dir"); do
    last="$snap"
    label=$(snap_field "$snap" '.snapshot_label // ""')
    case "$label" in
      post_*) post="$snap" ;;
    esac
  done
  snap="${post:-$last}"
  [ -n "$snap" ] || { printf '\n'; return 0; }
  snap_field "$snap" '.control_plane.controller_manager_lease.holder // ""'
}

# Sibling iteration directories of a batch root: run_<K> holding at least one
# snapshot, whose iteration_meta.json does not say the iteration failed (a
# failed iteration may have written partial snapshots, which would poison the
# statistics), emitted in NUMERIC order.
i4_iteration_dirs() {  # $1 = batch root
  local root="$1" d name num status
  for d in "$root"/run_*/; do
    [ -d "$d" ] || continue
    d="${d%/}"
    name=$(basename "$d")
    num="${name#run_}"
    case "$num" in ''|*[!0-9]*) continue ;; esac
    ls "$d"/snapshot_*.json >/dev/null 2>&1 || continue
    status="ok"
    if [ -f "$d/iteration_meta.json" ]; then
      status=$(jq -r '.status // "ok"' "$d/iteration_meta.json" 2>/dev/null || echo "ok")
    fi
    [ "$status" = "ok" ] || continue
    printf '%d\t%s\n' "$((10#$num))" "$d"
  done | LC_ALL=C sort -n -k1,1 | cut -f2
}

check_i4() {
  local scenario base batch_root in_batch=0 layout="single"
  local d name runs planned unreadable readable distinct verdict note provisional
  local dirs nums states
  dirs=(); nums=(); states=()

  scenario=$(snap_field "$(snapshots | sed -n 1p)" '.scenario_id // "unknown"')

  base=$(basename "$RESULTS_DIR")
  if [[ "$base" =~ ^run_[0-9]+$ ]]; then
    in_batch=1
    layout="repeated"
    batch_root=$(cd "$RESULTS_DIR/.." && pwd)
  else
    batch_root=""
  fi

  if [ "$in_batch" -eq 1 ]; then
    for d in $(i4_iteration_dirs "$batch_root"); do
      dirs+=("$d")
      name=$(basename "$d")
      nums+=("${name#run_}")
    done
  elif ls "$RESULTS_DIR"/snapshot_*.json >/dev/null 2>&1; then
    # A single run is run one of one. It is emitted through the same code path
    # so both layouts read identically downstream.
    dirs+=("$RESULTS_DIR")
    nums+=(1)
  fi

  runs=${#dirs[@]}

  planned="$runs"
  if [ "$in_batch" -eq 1 ] && [ -f "$batch_root/repeat_manifest.json" ]; then
    planned=$(jq -r '.iterations_planned // empty' "$batch_root/repeat_manifest.json" 2>/dev/null || echo "")
    [[ "$planned" =~ ^[0-9]+$ ]] || planned="$runs"
  fi

  unreadable=0
  local i=0 st
  while [ "$i" -lt "$runs" ]; do
    st=$(i4_final_state "${dirs[$i]}")
    case "$st" in
      ""|null|unknown|Unknown|UNKNOWN) st="unknown"; unreadable=$((unreadable + 1)) ;;
    esac
    states+=("$st")
    i=$((i + 1))
  done
  readable=$((runs - unreadable))

  local states_json nums_json
  if [ "${#states[@]}" -eq 0 ]; then states_json='[]'
  else states_json=$(printf '%s\n' "${states[@]}" | jq -R . | jq -cs .); fi
  if [ "${#nums[@]}" -eq 0 ]; then nums_json='[]'
  else nums_json=$(printf '%s\n' "${nums[@]}" | jq -R . | jq -cs 'map(tonumber? // .)'); fi

  distinct=$(printf '%s' "$states_json" | jq '[ .[] | select(. != "unknown" and . != null and . != "") ] | unique | length')
  [[ "$distinct" =~ ^[0-9]+$ ]] || distinct=0

  provisional=false
  if [ "$in_batch" -eq 1 ]; then provisional=true; fi

  if [ "$runs" -lt 2 ]; then
    verdict="INSUFFICIENT_DATA"
    if [ "$in_batch" -eq 1 ]; then
      note="only $runs readable iteration(s) in this batch so far — I4 needs at least 2 independent repetitions; the verdict of record is recomputed at the batch root by aggregate-results.sh (recovery_variance)."
    elif [[ "$scenario" == s6_run* ]]; then
      # Legacy path: S6's own plays label their snapshots s6_run<N> and older
      # sweeps wrote a parallel results/s6_run<N>/ tree with no sibling
      # iterations to compare against. Pre-existing quirk, left alone.
      note="single S6 iteration in the legacy results/s6_run<N> layout — see aggregate_report.json recovery_variance_s6 for the verdict across all repetitions."
    else
      note="single run: I4 is a cross-run invariant and needs N > 1. Re-run this scenario through scripts/repeat-scenario.sh to make it evaluable; the cross-run comparison itself lives in aggregate-results.sh (recovery_variance)."
    fi
  elif [ "$readable" -eq 0 ]; then
    verdict="INSUFFICIENT_DATA"
    note="$runs iterations, none of which produced a readable final state (no run_summary.json and no lease holder in any post-fault snapshot) — no evidence either way."
  elif [ "$distinct" -le 1 ]; then
    verdict="PRESERVED"
    note="$readable of $runs repetitions produced a readable final state and they all agree — recovery converged to a single state."
  else
    verdict="VIOLATED"
    note="$distinct distinct final states across $runs repetitions of the same fault — recovery is not uniquely determined."
  fi

  if [ "$in_batch" -eq 1 ]; then
    note="$note PROVISIONAL: this iteration can only see the repetitions that finished before it; aggregate_report.json's invariant_heatmap[].I4 (I4_source=batch_recompute) is the verdict of record."
  fi

  jq -nc \
    --arg verdict "$verdict" \
    --arg note "$note" \
    --arg layout "$layout" \
    --argjson runs "$runs" \
    --argjson runs_expected "$planned" \
    --argjson runs_unreadable "$unreadable" \
    --argjson distinct "$distinct" \
    --argjson provisional "$provisional" \
    --argjson run_numbers "$nums_json" \
    --argjson holders "$states_json" \
    '{invariant: "I4",
      name: "recovery_coherence",
      verdict: $verdict,
      layout: $layout,
      runs: $runs,
      run_numbers: $run_numbers,
      runs_expected: $runs_expected,
      runs_unreadable: $runs_unreadable,
      distinct_final_states: $distinct,
      # kept under its historical name so anything reading the old S6 output
      # keeps working
      distinct_cm_holders: $distinct,
      holder_sequence: $holders,
      provisional: $provisional,
      note: $note}'
}

# ── I5: Observation-action consistency ─────────────────────────────────────────
# Violation: at one instant, two API servers gave different answers to the same
# question, or an API server served a watch-cache read provably behind the
# linearizable state it could have read itself.
#
# The previous implementation was two heuristics that could hardly fail to
# fire, which is why I5 came back VIOLATED in 11 of 12 scenarios:
#   (1) "etcd revision advanced by more than 500 between consecutive
#       snapshots" measures the cluster's write rate, not staleness — an idle
#       six-node cluster produces 300–1400 revisions per observation interval —
#       and before the ordering fix above it compared non-adjacent snapshots;
#   (2) "a NodeNotReady/FailedScheduling warning exists AND at least one node
#       is Ready" is true in essentially every snapshot once any scenario has
#       run, given the one-hour event TTL.
# Both are removed rather than retuned. A threshold on write throughput cannot
# be made into a staleness measurement by choosing a better number.
#
# The replacement reads the per-API-server views metrics-collect now records
# in .observers[], one per control-plane node, each queried on its own address
# so the keepalived VIP cannot redirect the question:
#   content divergence — two reachable API servers disagree about the Ready
#                        status of the same node at the same instant.
#                        Threshold-free, and the most direct evidence the
#                        paper's thesis can have.
#   revision lag       — an API server's resourceVersion=0 read (served from
#                        its watch cache) is behind its own linearizable read
#                        of the same collection, or behind the highest
#                        linearizable revision any API server reported, by more
#                        than I5_STALE_RV_THRESHOLD revisions (default 100;
#                        override in the environment).
# Runs recorded before .observers existed return INSUFFICIENT_DATA. That is
# honest: those runs contain no evidence about staleness, and inheriting the
# old heuristics' verdict would be worse than admitting it.

I5_STALE_RV_THRESHOLD="${I5_STALE_RV_THRESHOLD:-100}"

check_i5() {
  local violations=()
  local detail=()
  local evaluated=0

  for snap in $(snapshots); do
    label=$(snap_field "$snap" '.snapshot_label')
    ts=$(snap_field "$snap" '.timestamp')

    obs_count=$(snap_field "$snap" '[.observers[]? | select(.ok == true)] | length')
    [[ "$obs_count" =~ ^[0-9]+$ ]] || obs_count=0
    [ "$obs_count" -eq 0 ] && continue
    evaluated=$((evaluated + 1))

    finding=$(jq -c --argjson thr "$I5_STALE_RV_THRESHOLD" '
      [ .observers[]? | select(.ok == true) ] as $o
      | ( [ $o[] | (.probe_rv_quorum // empty) | tonumber? ] ) as $rvs
      | ( $rvs | max ) as $maxrv
      | {
          node_disagreement:
            ( [ $o[] | (.node_ready // {}) | to_entries[] ]
              | group_by(.key)
              | map({ node: .[0].key, answers: (map(.value) | unique) })
              | map(select((.answers | length) > 1)) ),
          stale_observers:
            ( [ $o[]
                | . as $x
                | ( ($x.probe_rv_quorum // null) | tonumber? ) as $q
                | ( ($x.probe_rv_cache  // null) | tonumber? ) as $c
                | select($q != null)
                | { host: $x.host,
                    rv_quorum: $q,
                    rv_cache: $c,
                    cache_lag: (if $c == null then null else ($q - $c) end),
                    peer_lag:  (if $maxrv == null then null else ($maxrv - $q) end) }
                | select(((.cache_lag // 0) > $thr) or ((.peer_lag // 0) > $thr)) ] )
        }
      | select(((.node_disagreement | length) > 0) or ((.stale_observers | length) > 0))
    ' "$snap" 2>/dev/null || echo "")

    if [ -n "$finding" ]; then
      violations+=("$label")
      detail+=("{\"snapshot\": \"$label\", \"ts\": \"$ts\", \"finding\": $finding}")
    fi
  done

  if [ "$evaluated" -eq 0 ]; then
    echo '{"invariant": "I5", "name": "observation_action_consistency", "verdict": "INSUFFICIENT_DATA",
           "note": "no snapshot carries per-API-server observer views (.observers[]); this run predates the D4 fix. The previous revision-delta heuristic was removed, not retuned — it measured write throughput, not staleness."}'
    return
  fi

  if [ ${#violations[@]} -eq 0 ]; then
    echo "{\"invariant\": \"I5\", \"name\": \"observation_action_consistency\", \"verdict\": \"PRESERVED\", \"snapshots_evaluated\": $evaluated, \"stale_rv_threshold\": $I5_STALE_RV_THRESHOLD, \"violations\": []}"
  else
    DETAILS=$(IFS=','; echo "[${detail[*]}]")
    echo "{\"invariant\": \"I5\", \"name\": \"observation_action_consistency\", \"verdict\": \"VIOLATED\", \"snapshots_evaluated\": $evaluated, \"stale_rv_threshold\": $I5_STALE_RV_THRESHOLD, \"violation_count\": ${#violations[@]}, \"violations\": $DETAILS}"
  fi
}

# ── I6: Watch progress monotonicity ────────────────────────────────────────────
# Violation: between two consecutive snapshots, the observed etcd revision
# decreases. A backwards revision means a watch reset / re-list / split-quorum
# stale read — the observer is seeing an older state than it had seen before.

check_i6() {
  local violations=()
  local detail=()
  local prev_revision=""
  local prev_label=""

  for snap in $(snapshots); do
    label=$(snap_field "$snap" '.snapshot_label')
    ts=$(snap_field "$snap" '.timestamp')
    revision=$(snap_field "$snap" '.etcd.current_revision // 0')

    if [[ "$prev_revision" =~ ^[0-9]+$ ]] && [[ "$revision" =~ ^[0-9]+$ ]] \
       && [ "$revision" -lt "$prev_revision" ]; then
      violations+=("$label")
      detail+=("{\"snapshot\": \"$label\", \"ts\": \"$ts\",
                 \"revision\": $revision, \"previous_revision\": $prev_revision,
                 \"from\": \"$prev_label\"}")
    fi

    prev_revision="$revision"
    prev_label="$label"
  done

  if [ ${#violations[@]} -eq 0 ]; then
    echo '{"invariant": "I6", "name": "watch_progress_monotonicity", "verdict": "PRESERVED", "violations": []}'
  else
    DETAILS=$(IFS=','; echo "[${detail[*]}]")
    echo "{\"invariant\": \"I6\", \"name\": \"watch_progress_monotonicity\", \"verdict\": \"VIOLATED\", \"violation_count\": ${#violations[@]}, \"violations\": $DETAILS}"
  fi
}

# ── I9: Quorum continuity ──────────────────────────────────────────────────────
# Violation: at any snapshot, fewer than ⌈n/2⌉+1 etcd members respond to
# endpoint status, or the responding members disagree about who the leader is
# or which raft term they are in. The substrate-side counterpart to I1: it
# separates "the cluster lost quorum" from "the cluster kept quorum but exposed
# inconsistencies to its observers."
#
# Cluster size n now comes from .etcd.expected_members, written by
# metrics-collect from `groups['etcd'] | length`. It used to be inferred as the
# maximum member count ever observed, which fails in exactly the scenario the
# invariant exists for: with a 5-member cluster split 2/3, only the minority
# side's two members answer, the checker infers n=2 or n=3, computes quorum=2,
# and returns PRESERVED for a cluster that has lost quorum. Inference from the
# data is kept only as a fallback for runs recorded before the field existed,
# and the report says which source was used.
#
# The leader / raft-term check needs no new collection — `etcdctl endpoint
# status` already returns .Status.leader and .Status.raftTerm per member. Two
# distinct leader IDs in one snapshot is far stronger evidence of a split than
# any member count.

check_i9() {
  local violations=()
  local detail=()
  local total_members=0
  local expected=""
  local expected_source="observed_max"

  # First pass: expected size from the inventory if present, else the largest
  # member count observed.
  for snap in $(snapshots); do
    if [ -z "$expected" ]; then
      e=$(snap_field "$snap" '.etcd.expected_members // empty')
      if [[ "$e" =~ ^[0-9]+$ ]]; then
        expected="$e"
        expected_source="inventory"
      fi
    fi
    count=$(snap_field "$snap" '.etcd.member_status | length // 0')
    if [[ "$count" =~ ^[0-9]+$ ]] && [ "$count" -gt "$total_members" ]; then
      total_members=$count
    fi
  done

  [ -n "$expected" ] || expected="$total_members"

  if [ "$expected" -lt 3 ]; then
    echo "{\"invariant\": \"I9\", \"name\": \"quorum_continuity\", \"verdict\": \"INSUFFICIENT_DATA\", \"note\": \"expected etcd cluster size $expected (<3); cannot infer a quorum threshold\", \"expected_source\": \"$expected_source\"}"
    return
  fi

  local quorum=$(( expected / 2 + 1 ))

  for snap in $(snapshots); do
    label=$(snap_field "$snap" '.snapshot_label')
    ts=$(snap_field "$snap" '.timestamp')
    healthy=$(snap_field "$snap" '.etcd.member_status | length // 0')

    if [[ "$healthy" =~ ^[0-9]+$ ]] && [ "$healthy" -lt "$quorum" ]; then
      violations+=("$label")
      detail+=("{\"snapshot\": \"$label\", \"ts\": \"$ts\", \"reason\": \"below_quorum\",
                 \"healthy_members\": $healthy, \"quorum_required\": $quorum,
                 \"cluster_size\": $expected}")
    fi

    # Divergent leader or raft term among the members that did answer.
    split=$(jq -c '
      [ .etcd.member_status[]? | { leader: (.Status.leader // null), term: (.Status.raftTerm // null) } ] as $m
      | { leaders: ([ $m[].leader | select(. != null) ] | unique),
          terms:   ([ $m[].term   | select(. != null) ] | unique) }
      | select(((.leaders | length) > 1) or ((.terms | length) > 1))
    ' "$snap" 2>/dev/null || echo "")

    if [ -n "$split" ]; then
      violations+=("${label}_split")
      detail+=("{\"snapshot\": \"$label\", \"ts\": \"$ts\", \"reason\": \"leader_or_term_divergence\", \"detail\": $split}")
    fi
  done

  if [ ${#violations[@]} -eq 0 ]; then
    echo "{\"invariant\": \"I9\", \"name\": \"quorum_continuity\", \"verdict\": \"PRESERVED\", \"cluster_size\": $expected, \"cluster_size_source\": \"$expected_source\", \"max_members_observed\": $total_members, \"quorum_threshold\": $quorum, \"violations\": []}"
  else
    DETAILS=$(IFS=','; echo "[${detail[*]}]")
    echo "{\"invariant\": \"I9\", \"name\": \"quorum_continuity\", \"verdict\": \"VIOLATED\", \"cluster_size\": $expected, \"cluster_size_source\": \"$expected_source\", \"max_members_observed\": $total_members, \"quorum_threshold\": $quorum, \"violation_count\": ${#violations[@]}, \"violations\": $DETAILS}"
  fi
}

# ── I10: Reconciliation termination ────────────────────────────────────────────
# Violation: after fault removal, the cluster keeps emitting new Warning events
# (NodeNotReady, FailedScheduling, BackOff, Unhealthy, …) — i.e. controllers
# never converge on a stable view. We compare (involvedObject.name, reason)
# pairs in the *last* post-fault snapshot against those in the *first*
# post-fault snapshot; any new pair = a fresh problem the cluster has not yet
# resolved. The standard 1h event TTL means old events stay in the list, so
# count alone is misleading — set difference is the right primitive.

check_i10() {
  local post_snaps=()
  for snap in $(snapshots); do
    label=$(snap_field "$snap" '.snapshot_label')
    if [[ "$label" == post_* ]]; then
      post_snaps+=("$snap")
    fi
  done

  if [ ${#post_snaps[@]} -lt 2 ]; then
    echo '{"invariant": "I10", "name": "reconciliation_termination", "verdict": "INSUFFICIENT_DATA", "note": "fewer than 2 post-fault snapshots; cannot evaluate whether new warnings stopped appearing"}'
    return
  fi

  local first="${post_snaps[0]}"
  local last="${post_snaps[${#post_snaps[@]}-1]}"
  local first_label last_label last_ts
  first_label=$(snap_field "$first" '.snapshot_label')
  last_label=$(snap_field "$last" '.snapshot_label')
  last_ts=$(snap_field "$last" '.timestamp')

  # Set-difference of (involvedObject.name, reason) tuples — last minus first.
  # Two reads of jq because the snapshots may be in separate files.
  local new_pairs
  new_pairs=$(jq -s '
    (.[0].control_plane.warning_events // []) as $first |
    (.[1].control_plane.warning_events // []) as $last |
    ($first | map((.involvedObject.name // "?") + ":" + (.reason // "?"))) as $f |
    ($last  | map((.involvedObject.name // "?") + ":" + (.reason // "?"))) as $l |
    [$l[] | select(. as $x | ($f | index($x)) | not)]
  ' "$first" "$last" 2>/dev/null || echo "null")

  local new_count
  new_count=$(echo "$new_pairs" | jq 'length' 2>/dev/null || echo "null")

  if [ "$new_count" = "null" ]; then
    echo "{\"invariant\": \"I10\", \"name\": \"reconciliation_termination\", \"verdict\": \"INSUFFICIENT_DATA\", \"note\": \"could not parse warning_events in one of the post-fault snapshots\", \"first\": \"$first_label\", \"last\": \"$last_label\"}"
  elif [ "$new_count" = "0" ]; then
    echo "{\"invariant\": \"I10\", \"name\": \"reconciliation_termination\", \"verdict\": \"PRESERVED\", \"post_fault_snapshots\": ${#post_snaps[@]}, \"first\": \"$first_label\", \"last\": \"$last_label\", \"new_warning_pairs\": 0}"
  else
    # The violations array carries the one snapshot this check can attribute
    # its finding to — the last post-fault snapshot, where the new warning
    # pairs were observed. It exists so the M4 first_violation_ts annotation
    # and divergence_timing have a locus to read; before this, an I10 violation
    # was invisible to both.
    echo "{\"invariant\": \"I10\", \"name\": \"reconciliation_termination\", \"verdict\": \"VIOLATED\", \"post_fault_snapshots\": ${#post_snaps[@]}, \"first\": \"$first_label\", \"last\": \"$last_label\", \"new_warning_pairs\": $new_count, \"examples\": $(echo "$new_pairs" | jq '.[0:5]'), \"violations\": [{\"snapshot\": \"$last_label\", \"ts\": \"$last_ts\", \"new_warning_pairs\": $new_count, \"observed_between\": \"$first_label\"}]}"
  fi
}

# ── Divergence timing analysis ─────────────────────────────────────────────────
# Every timing here is an index into the chronological snapshot order, so it is
# only meaningful with the ordering fix at the top of this file — the May 2026
# aggregate reports first_fault_snapshot "post_fault_t210" for S1, i.e. the
# fault apparently beginning after it ended.
#
# The old version also treated a null probe as a service failure. Combined with
# the observer-side probe that could never connect, that made
# first_service_failure_snapshot always the first snapshot in filename order.
#
# Takes the evaluated invariant reports as arguments so it can also report the
# earliest snapshot at which any invariant was violated.

divergence_timing() {
  local ordered=()
  local snap label probe

  for snap in $(snapshots); do
    ordered+=("$(snap_field "$snap" '.snapshot_label')")
  done

  if [ ${#ordered[@]} -eq 0 ]; then
    echo '{"first_fault_snapshot": "none", "first_service_failure_snapshot": "none", "first_violation_snapshot": "none", "snapshot_order": []}'
    return
  fi

  local labels_json
  labels_json=$(printf '%s\n' "${ordered[@]}" | jq -R . | jq -cs .)

  # The first snapshot is the baseline; the fault is active from the second on.
  local first_fault="none"
  [ ${#ordered[@]} -ge 2 ] && first_fault="${ordered[1]}"

  local first_service_failure="none"
  for snap in $(snapshots); do
    label=$(snap_field "$snap" '.snapshot_label')
    probe=$(snap_field "$snap" '.external_probe.httpCode // null')
    if [ -n "$probe" ] && [ "$probe" != "null" ] && [ "$probe" != "200" ]; then
      first_service_failure="$label"
      break
    fi
  done

  local violated_labels first_violation
  violated_labels=$(printf '%s\n' "$@" | jq -cs '
    [ .[] | select(.verdict == "VIOLATED") | (.violations // [])[] | .snapshot? // empty ]' \
    2>/dev/null || echo '[]')
  first_violation=$(jq -rn --argjson labels "$labels_json" --argjson v "$violated_labels" '
    [ $v[] as $s
      | ($labels | to_entries[] | . as $e
         | select($s == $e.value or ($s | startswith($e.value + "_")))
         | $e.key) ] as $idxs
    | if ($idxs | length) == 0 then "none" else $labels[($idxs | min)] end' \
    2>/dev/null || echo "none")

  jq -n --arg ff "$first_fault" \
        --arg fs "$first_service_failure" \
        --arg fv "$first_violation" \
        --argjson order "$labels_json" \
    '{first_fault_snapshot: $ff,
      first_service_failure_snapshot: $fs,
      first_violation_snapshot: $fv,
      snapshot_order: $order}'
}

# ── Fault efficacy ─────────────────────────────────────────────────────────────
# Did the fault actually do anything? A scenario whose injection missed its
# target still produces a full set of invariant verdicts, and those verdicts
# describe an undisturbed cluster. Two runs in the May 2026 sweep are of this
# kind: S11 blocked port 6443 to the three control-plane IPs but not the API
# VIP the kubelet actually uses, so worker1 stayed Ready in all seven
# snapshots; S12 flapped cp1 against cp2/cp3 while leaving cp1→etcd open, so
# the controller-manager renewed its lease throughout and the recorded
# "leader election storm" contains zero leader changes.
#
# The run is EFFECTIVE if the cluster's observable state changed at all
# relative to the baseline snapshot. A scenario can demand something stricter
# by dropping a scenario_meta.json into its results directory:
#
#   {"efficacy": {"require": ["node_status_changed"]}}
#
# with any of the signal names below. INEFFECTIVE does not suppress the
# invariant verdicts — it labels the run so the aggregate can exclude it
# instead of quietly counting it.

# ── Scenario-supplied efficacy evidence ───────────────────────────────────────
# Five of the nine gray-failure scenarios cannot certify their own efficacy from
# snapshot_*.json, and that is not an oversight: leaving the snapshot schema
# unchanged is what makes a fault gray. Their proof lives in a file the scenario
# writes into its own results directory, so the signals below are computed from
# those files instead of from the snapshots.
#
# Every row names a real file and a real field. Nothing here is inferred from a
# field that does not exist: naming an unknown signal in `require` forces
# FAULT_INEFFECTIVE on every run (the jq does `($sig[.]) // false`), which is
# the D2 defect this suite already paid for once, and a signal that reads a
# field nobody writes would be the same defect with more steps.
#
# Format: signal::evidence glob[,baseline file]::jq predicate::what it means
#
# The field separator is `::`, not `|`, because jq predicates are full of
# pipes and a `|`-delimited table silently truncates every predicate at its
# first one — which reads exactly like a signal that never fires.
#
# The predicate is evaluated per matched file with `jq -e`; several matches are
# ORed, so a glob means "any of these files shows it". A row with a baseline
# file gets it as $base (null when absent), which is how the contrast signals
# refuse to fire on a cluster that already looked like that before the fault.
EVIDENCE_SIGNALS='
target_process_frozen::s22_process_identity.json::((.frozen_check // "") | test("proc_state=[Tt]"))::the SIGSTOPped unit main PID was observed in kernel state T/t on the target
cluster_writes_rejected::rw_contrast_nospace_*.json,rw_contrast_pre_fault.json::(((. | map(select(.write.ok == false)) | length) > 0) and (($base | type) == "array") and ((($base | map(select(.write.ok == false))) | length) == 0))::at least one API server rejected a write while the alarm was armed, and none did at baseline
admission_rejected::admission_comparison.json::((.contrast.configmap_created.fail == false) or (.contrast.pod_created.fail == false))::the intercepted CREATE was rejected under failurePolicy=Fail
apf_starvation_observed::apf_evidence.json::((([ .per_worker_tallies[]?[]?.http_429 ] | add) // 0) > 0)::the flooded low-priority client accrued 429s, so APF actively shed load
vip_holders_multiple::vip_split_summary.json::((.split_observed == true) or ((.max_simultaneous_vip_holders // 0) > 1))::two control-plane nodes held the API VIP at the same instant
target_node_dataplane_lost::dataplane_during_fault.json,dataplane_pre_fault.json::((([ .per_pod_reachability[]? | select(.httpCode != 200) ] | length) > 0) and (($base | type) == "object") and (([ $base.per_pod_reachability[]? ] | length) > 0) and (([ $base.per_pod_reachability[]? | select(.httpCode != 200) ] | length) == 0))::pods on the target node answered at baseline and stopped answering during the fault
clock_offset_applied::clock_skew_efficacy.json::(([ .targets[]? | select(.held == true) ] | length) > 0)::the requested offset was still measured on a target mid-window
node_identity_recreated::node_identity_transition.json::(.uid_changed == true)::the Node object came back under the same name with a different uid
'

# Evaluate every row against this run's results directory. A signal whose
# evidence file is not there is FALSE with reason "evidence_absent" — never
# silently false: the reason travels with the value into the report, and into
# missing_required_detail when a scenario required it.
evidence_signals() {
  local out='{}'
  local line signal spec pred meaning glob basefile basearg matched value reason files f rc

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    signal=$(printf '%s' "$line"  | awk -F'::' '{ print $1 }')
    spec=$(printf '%s' "$line"    | awk -F'::' '{ print $2 }')
    pred=$(printf '%s' "$line"    | awk -F'::' '{ print $3 }')
    meaning=$(printf '%s' "$line" | awk -F'::' '{ print $4 }')
    [ -n "$signal" ] || continue

    glob=$(printf '%s' "$spec"     | awk -F, '{ print $1 }')
    basefile=$(printf '%s' "$spec" | awk -F, '{ print $2 }')

    basearg='null'
    if [ -n "$basefile" ] && [ -f "$RESULTS_DIR/$basefile" ]; then
      basearg=$(jq -c . "$RESULTS_DIR/$basefile" 2>/dev/null || echo 'null')
    fi

    files=""
    for f in "$RESULTS_DIR"/$glob; do
      [ -f "$f" ] || continue
      files="$files $f"
    done

    if [ -z "$files" ]; then
      value=false
      reason="evidence_absent: no file matching $glob in this results dir"
      matched='[]'
    else
      value=false
      reason="predicate false in every matched evidence file"
      matched=$(for f in $files; do basename "$f"; done | jq -R . | jq -cs .)
      for f in $files; do
        rc=0
        jq -e --argjson base "$basearg" "$pred" "$f" >/dev/null 2>&1 || rc=$?
        if [ "$rc" -eq 0 ]; then
          value=true
          reason="predicate true in $(basename "$f")"
          break
        fi
      done
    fi

    # `|| true` plus the emptiness guard: under `set -e` a jq that chokes on one
    # row would abort the whole checker, and losing every verdict because one
    # evidence table row is malformed is not an acceptable failure mode.
    out=$(printf '%s' "$out" | jq -c \
      --arg sig "$signal" --arg glob "$glob" --arg base "$basefile" \
      --arg pred "$pred" --arg meaning "$meaning" --arg reason "$reason" \
      --argjson matched "$matched" --argjson value "$value" \
      '. + { ($sig): { value: $value, evidence_glob: $glob,
                       baseline_file: (if $base == "" then null else $base end),
                       matched_files: $matched, predicate: $pred,
                       means: $meaning, reason: $reason } }' 2>/dev/null || true)
    [ -n "$out" ] || out='{}'
  done <<EOF
$(printf '%s\n' "$EVIDENCE_SIGNALS")
EOF

  printf '%s' "$out"
}

fault_efficacy() {
  local files
  files=$(snapshots)
  if [ -z "$files" ]; then
    echo '{"verdict": "INSUFFICIENT_DATA", "note": "no snapshots"}'
    return
  fi
  if [ "$(echo "$files" | wc -l | tr -d ' ')" -lt 2 ]; then
    echo '{"verdict": "INSUFFICIENT_DATA", "note": "fewer than two snapshots; nothing to compare the baseline against"}'
    return
  fi

  local required='[]'
  local target='""'
  local proposed='[]'
  if [ -f "$RESULTS_DIR/scenario_meta.json" ]; then
    required=$(jq -c '[.efficacy.require[]?]' "$RESULTS_DIR/scenario_meta.json" 2>/dev/null || echo '[]')
    target=$(jq -c '.efficacy.target_node // ""' "$RESULTS_DIR/scenario_meta.json" 2>/dev/null || echo '""')
    # Both spellings seen in the tree: S23 nests it under .efficacy, S25 names
    # the same idea .new_signal.name at the top level.
    proposed=$(jq -c '[ (.efficacy.require_proposed[]?), (.new_signal.name? | select(. != null)) ] | unique' \
                 "$RESULTS_DIR/scenario_meta.json" 2>/dev/null || echo '[]')
  fi

  local evidence
  evidence=$(evidence_signals)
  [ -n "$evidence" ] || evidence='{}'

  # shellcheck disable=SC2086
  jq -s --argjson required "$required" --argjson target "$target" \
        --argjson evidence "$evidence" --argjson proposed "$proposed" '
    def ready_map:
      [ (.control_plane.node_conditions // [])[]
        | { key: .name,
            value: ([ .conditions[]? | select(.type == "Ready") | .status ][0] // "Missing") } ]
      | from_entries;
    def placement:
      [ .nodes[]?
        | .host as $h
        | ( .containers | if type == "string" then (fromjson? // []) else (. // []) end )[]?
        | select(.state == "CONTAINER_RUNNING" and .podName != null)
        | ((.podNamespace // "default") + "/" + .podName + "@" + $h) ]
      | unique;
    def members: (.etcd.member_status | length) // 0;
    # Same shape check_i9 uses for leader_or_term_divergence, factored out so
    # the invariant and the efficacy signal cannot drift apart.
    def split_view:
      [ .etcd.member_status[]? | { leader: (.Status.leader // null),
                                   term:   (.Status.raftTerm // null),
                                   leaderless: (((.Status.errors // [])
                                                 | map(select(test("no leader"; "i")))
                                                 | length) > 0) } ] as $m
      | { leaders: ([ $m[].leader | select(. != null) ] | unique),
          terms:   ([ $m[].term   | select(. != null) ] | unique),
          # The STABLE signature of a peer-port split: some members report
          # "etcdserver: no leader" while others do not. Divergent raft terms
          # are the sharper evidence but they are transient — they show only
          # in a snapshot that lands during the term bump, which is why one S19
          # run recorded terms [2,3] and the next recorded [3] across all five
          # members with the partition demonstrably still in place and two
          # members leaderless.
          leaderless:      ([ $m[] | select(.leaderless) ] | length),
          has_leader_view: ([ $m[] | select(.leaderless | not) ] | length) };
    def probe:   (.external_probe.httpCode // null);
    def holders: [ (.control_plane.controller_manager_lease.holder // empty),
                   (.control_plane.scheduler_lease.holder // empty) ];

    . as $snaps
    | ($snaps[0])  as $base
    | ($snaps[1:]) as $rest
    | {
        node_status_changed:
          (([ $rest[] | select((. | ready_map) != ($base | ready_map)) ] | length) > 0),
        lease_holder_changed:
          (([ $snaps[] | holders[] ] | unique | length) > (($base | holders) | unique | length)),
        etcd_members_dropped:
          (([ $rest[] | select((. | members) < ($base | members)) ] | length) > 0),
        probe_degraded:
          ((($base | probe) != null)
           and (([ $rest[] | select(((. | probe) != null) and ((. | probe) != ($base | probe))) ] | length) > 0)),
        placement_changed:
          (([ $rest[] | select((. | placement) != ($base | placement)) ] | length) > 0),

        # Raft split, observed the way check_i9 observes it: two distinct
        # leader IDs, or two distinct raft terms, among the members that
        # answered in ONE snapshot — and not already true at baseline.
        #
        # etcd_members_dropped cannot express this. A peer-port partition
        # (S19 blocks 2380, not 2379) leaves every member answering client
        # requests, so the member COUNT never falls: S19 split raft cleanly,
        # I9 recorded leader_or_term_divergence with terms [2,3], and the run
        # was still reported FAULT_INEFFECTIVE because the one signal it was
        # required to produce was a count that cannot move (REVIEW.md D22).
        etcd_quorum_split_observed:
          ((($base | split_view) as $b
            | ($b.leaders | length) <= 1
              and ($b.terms | length) <= 1
              and $b.leaderless == 0)
           and (([ $rest[]
                   | (. | split_view) as $v
                   | select(($v.leaders | length) > 1
                            or ($v.terms | length) > 1
                            or ($v.leaderless > 0 and $v.has_leader_view > 0)) ]
                 | length) > 0)),

        # The API server stopped answering at all for at least one snapshot
        # while it had answered at baseline. Recorded separately so that a
        # scenario whose only visible effect is "we lost the view" cannot be
        # mistaken for one that changed cluster state.
        api_view_lost:
          ((($base.control_plane.node_conditions // null) != null)
           and (([ $rest[] | select((.control_plane.node_conditions // null) == null) ] | length) > 0)),

        # Scoped to the node the fault was aimed at. A run where some unrelated
        # node flapped is not evidence that the injection reached its target:
        # in the May 2026 S11 run cp2 and cp3 went Unknown while worker1 — the
        # actual target — stayed Ready for the entire fault window.
        target_node_status_changed:
          (if ($target | type) != "string" or ($target | length) == 0 then false
           else (([ $rest[]
                    | select((. | ready_map)[$target] != ($base | ready_map)[$target]) ]
                  | length) > 0)
           end),

        # ── Signals added for the gray-failure scenarios ──────────────────
        #
        # etcd_alarm_armed needs no new collection at all: `etcdctl endpoint
        # status` already returns .Status.errors per member, and an armed
        # NOSPACE alarm appears there as the string "alarm:NOSPACE". Required
        # to be absent at baseline, so a cluster that arrived already alarmed
        # cannot certify a run that did not arm anything.
        etcd_alarm_armed:
          ((([ $base | .etcd.member_status[]?.Status.errors[]?
               | select(type == "string") | select(test("alarm:NOSPACE"; "i")) ] | length) == 0)
           and (([ $rest[] | .etcd.member_status[]?.Status.errors[]?
                   | select(type == "string") | select(test("alarm:NOSPACE"; "i")) ] | length) > 0)),

        # Same node name, different object. The snapshot path below is the one
        # that would work if node_conditions[] ever carried .uid; it does NOT
        # today (metrics-collect projects name/conditions/taints/unschedulable,
        # and M2 added observers, not node uids), so on current data it is
        # always false and the signal is decided by S26 own
        # node_identity_transition.json, merged in below. Written this way so
        # the signal starts using the snapshot the moment the field appears,
        # without a second edit here.
        node_identity_recreated:
          (([ $base.control_plane.node_conditions[]? | select(.uid != null) ]) as $b
           | if ($b | length) == 0 then false
             else (([ $rest[] | .control_plane.node_conditions[]? | select(.uid != null)
                      | . as $n | $b[] | select(.name == $n.name and .uid != $n.uid) ]
                    | length) > 0)
             end)
      }

    # Merge the scenario-supplied evidence signals on top. OR, not overwrite:
    # a signal computable from both sources fires if either source saw it, and
    # the per-signal provenance stays visible in .evidence.
    | . as $snapsig
    | (reduce ($evidence | to_entries[]) as $e ($snapsig;
         .[$e.key] = ((.[$e.key] // false) or ($e.value.value // false)))) as $sig

    | ([ $sig | to_entries[] | select(.value) | .key ]) as $fired
    | ([ $required[] | select((($sig[.]) // false) | not) ]) as $missing
    # `$sig | has(.)` would test $sig against ITSELF — inside `A | has(.)` the
    # argument is evaluated with A as input, not with the outer `.`. Bind the
    # name first.
    | ([ $required[] | . as $s | select(($sig | has($s)) | not) ]) as $unknown
    | {
        signals: $sig,
        fired: $fired,
        required: $required,
        missing_required: $missing,
        # Why each missing signal is missing. A required signal that is not a
        # defined signal name at all is a different fault from one that was
        # computed and came back false, and folding the two together is how a
        # typo becomes a permanent FAULT_INEFFECTIVE nobody notices.
        missing_required_detail:
          [ $missing[] | . as $s
            | { signal: $s,
                defined: ($sig | has($s)),
                source: (if ($evidence | has($s)) then "scenario evidence file"
                         elif ($sig | has($s)) then "snapshot series"
                         else "UNDEFINED — no such signal in check-invariants.sh" end),
                reason: (($evidence[$s].reason) //
                         (if ($sig | has($s)) then "computed from the snapshot series and came back false"
                          else "signal name is not defined by this checker" end)) } ],
        unknown_required_signals: $unknown,
        evidence: $evidence,
        # Advisory only. S21, S23 and S27 name the signals that would let them
        # self-certify in `require_proposed` rather than `require`, because at
        # the time they were written those signals did not exist and putting an
        # undefined name in `require` forces INEFFECTIVE. They exist now, so
        # this block reports whether they would have been satisfied — it does
        # NOT change the verdict, because `require` is the scenario own
        # declaration and rewriting it from here would make the checker decide
        # what the scenario asserted.
        require_proposed: $proposed,
        require_proposed_satisfied:
          (if ($proposed | length) == 0 then null
           else (([ $proposed[] | select((($sig[.]) // false) | not) ] | length) == 0)
           end),
        require_proposed_missing: [ $proposed[] | select((($sig[.]) // false) | not) ],
        verdict:
          (if ($required | length) > 0
           then (if ($missing | length) == 0 then "EFFECTIVE" else "INEFFECTIVE" end)
           else (if ($fired | length) > 0 then "EFFECTIVE" else "INEFFECTIVE" end)
           end),
        note: "EFFECTIVE = the fault produced at least one observable change against the baseline snapshot, or the signals the scenario required were all observed. INEFFECTIVE = the run measured an undisturbed cluster, so its invariant verdicts describe nothing."
      }
  ' $files
}

# ── Assemble and print final report ───────────────────────────────────────────

FIRST_SNAP=$(snapshots | sed -n 1p)
SCENARIO_ID=$(snap_field "$FIRST_SNAP" '.scenario_id // "unknown"')
RUN_ID=$(snap_field "$FIRST_SNAP" '.run_id // "unknown"')
SNAP_COUNT=$(snapshots | wc -l | tr -d ' ')

# ── Calibration gate ──────────────────────────────────────────────────────────
# Every invariant that can be evaluated against a single snapshot is first
# evaluated against the baseline alone. An invariant already VIOLATED before
# the fault was injected is a broken detector, not a finding, and its verdict
# for the whole run becomes DETECTOR_INVALID with the measured verdict kept
# alongside it.
#
# This is the rule that would have caught the observer-side service probe
# without anyone reading the checker: I2 was VIOLATED at pre_fault in every
# scenario of the May 2026 sweep. I4, I6 and I10 need at least two snapshots
# by construction, so they have no baseline verdict and are not gated; the
# ordering fix is what corrects I6.
CALIBRATION_MODE=1
CAL_I1=$(check_i1)
CAL_I2=$(check_i2)
CAL_I3=$(check_i3)
CAL_I5=$(check_i5)
CAL_I9=$(check_i9)
CALIBRATION_MODE=0

apply_gate() {
  local full="$1"
  local cal="$2"
  local cal_verdict
  cal_verdict=$(echo "$cal" | jq -r '.verdict // "UNKNOWN"' 2>/dev/null || echo "UNKNOWN")

  if [ "$cal_verdict" = "VIOLATED" ]; then
    echo "$full" | jq -c --argjson cal "$cal" '
      . + { verdict: "DETECTOR_INVALID",
            measured_verdict: .verdict,
            calibration: {
              verdict: "VIOLATED",
              note: "this invariant was already violated in the baseline snapshot, before any fault was injected; the detector is at fault, not the cluster",
              detail: ($cal.violations // [])
            } }'
  else
    echo "$full"
  fi
}

# Resolved before the verdicts are finalised: the applicability table is keyed
# on it. It reads the baseline snapshot, so it must run after snapshots() is
# usable and before finalize().
resolve_fault_class

I1=$(finalize I1 "$(apply_gate "$(check_i1)" "$CAL_I1")")
I2=$(finalize I2 "$(apply_gate "$(check_i2)" "$CAL_I2")")
I3=$(finalize I3 "$(apply_gate "$(check_i3)" "$CAL_I3")")
I4=$(finalize I4 "$(check_i4)")
I5=$(finalize I5 "$(apply_gate "$(check_i5)" "$CAL_I5")")
I6=$(finalize I6 "$(check_i6)")
I9=$(finalize I9 "$(apply_gate "$(check_i9)" "$CAL_I9")")
I10=$(finalize I10 "$(check_i10)")

EFFICACY=$(fault_efficacy)
TIMING=$(divergence_timing "$I1" "$I2" "$I3" "$I4" "$I5" "$I6" "$I9" "$I10")

jq -n \
  --arg scenario "$SCENARIO_ID" \
  --arg run "$RUN_ID" \
  --arg fault_class "$FAULT_CLASS" \
  --arg fault_class_source "$FAULT_CLASS_SOURCE" \
  --argjson snap_count "$SNAP_COUNT" \
  --argjson i1 "$I1" \
  --argjson i2 "$I2" \
  --argjson i3 "$I3" \
  --argjson i4 "$I4" \
  --argjson i5 "$I5" \
  --argjson i6 "$I6" \
  --argjson i9 "$I9" \
  --argjson i10 "$I10" \
  --argjson efficacy "$EFFICACY" \
  --argjson timing "$TIMING" \
  '[$i1,$i2,$i3,$i4,$i5,$i6,$i9,$i10] as $all |
   {
    scenario_id: $scenario,
    run_id: $run,
    fault_class: $fault_class,
    fault_class_source: $fault_class_source,
    snapshots_evaluated: $snap_count,
    run_validity: (if $efficacy.verdict == "INEFFECTIVE"
                   then "FAULT_INEFFECTIVE" else "OK" end),
    fault_efficacy: $efficacy,
    invariants: $all,
    summary: {
      preserved:         ($all | map(select(.verdict == "PRESERVED")) | length),
      violated:          ($all | map(select(.verdict == "VIOLATED")) | length),
      insufficient_data: ($all | map(select(.verdict == "INSUFFICIENT_DATA")) | length),
      detector_invalid:  ($all | map(select(.verdict == "DETECTOR_INVALID")) | length),
      not_applicable:    ($all | map(select(.verdict == "NOT_APPLICABLE")) | length),
      # The population a rate may be computed over. PRESERVED + VIOLATED and
      # nothing else: INSUFFICIENT_DATA measured nothing, DETECTOR_INVALID
      # measured the detector, NOT_APPLICABLE asked a question this fault
      # cannot answer, and a FAULT_INEFFECTIVE run measured an undisturbed
      # cluster. aggregate-results.sh uses the same denominator.
      evaluable: ($all | map(select(.verdict == "PRESERVED" or .verdict == "VIOLATED")) | length),
      verdict_vocabulary: ["PRESERVED", "VIOLATED", "INSUFFICIENT_DATA",
                           "NOT_APPLICABLE", "DETECTOR_INVALID", "FAULT_INEFFECTIVE"],
      counting_note: "FAULT_INEFFECTIVE is a run-level verdict (run_validity), not a per-invariant one: when a fault did nothing, every invariant verdict in the run describes an undisturbed cluster, so the run is excluded whole."
    },
    divergence_timing: $timing
  }'
