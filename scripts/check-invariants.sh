#!/bin/bash
# scripts/check-invariants.sh
# Evaluates the five paper invariants against a set of snapshot JSON files.
# Usage: check-invariants.sh <results_dir>
#
# Outputs a JSON report with per-invariant verdicts across all snapshots.
#
# Invariants checked:
#   I1 — Exclusive authority (no two simultaneous owners/leaders)
#   I2 — Reachability publication (endpoints match actual backends)
#   I3 — Failure declaration consistency (declared-failed nodes not still active)
#   I4 — Recovery coherence (post-fault state is uniquely determined)
#   I5 — Observation-action consistency (no action on provably stale state)

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
snapshots() {
  local f idx ts list
  list=$(
    for f in "$RESULTS_DIR"/snapshot_*.json; do
      [ -e "$f" ] || continue
      idx=$(jq -r '.snapshot_index // empty' "$f" 2>/dev/null || echo "")
      ts=$(jq -r '.timestamp // empty' "$f" 2>/dev/null || echo "")
      [[ "$idx" =~ ^[0-9]+$ ]] || idx=9999
      [ -n "$ts" ] || ts="9999-99-99T99:99:99Z"
      printf '%04d\t%s\t%s\n' "$idx" "$ts" "$f"
    done | LC_ALL=C sort -k1,1 -k2,2 | cut -f3
  )
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
# Evaluated only if multiple post_fault snapshots exist.
# Violation: post-fault snapshots show different pod placements or lease holders
# (indicates nondeterministic recovery)

check_i4() {
  # I4 (recovery coherence) is *cross-run* by construction: the question is
  # whether independent repetitions of the same fault converge to the same
  # post-fault state. Comparing post-fault snapshots *within a single run*
  # only tells you whether the lease holder happened to rotate during
  # observation (it often does, that's normal renewal), not whether the
  # cluster recovered to a unique state. Only S6 materially evaluates I4
  # because only S6 runs multiple iterations under a stable scenario_id.
  #
  # For every other scenario we return INSUFFICIENT_DATA explicitly; the
  # cross-run comparison lives in aggregate-results.sh
  # (collect_recovery_variance).
  local scenario
  scenario=$(snap_field "$(snapshots | head -1)" '.scenario_id // "unknown"')

  if [[ "$scenario" != s6* ]]; then
    echo '{"invariant": "I4", "name": "recovery_coherence", "verdict": "INSUFFICIENT_DATA",
           "note": "I4 is a cross-run invariant — only S6 (repeat-run study) can evaluate it. See aggregate_report.json recovery_variance_s6 block."}'
    return
  fi

  # Inside an S6 sub-run (scenario_id "s6_run<N>") we still only have one
  # final state; the cross-run comparison is done by aggregate-results.sh,
  # so individual S6 runs also defer.
  if [[ "$scenario" == s6_run* ]]; then
    echo '{"invariant": "I4", "name": "recovery_coherence", "verdict": "INSUFFICIENT_DATA",
           "note": "Single S6 iteration — see aggregate_report.json recovery_variance_s6 for the verdict across all repetitions."}'
    return
  fi

  # Top-level S6 (scenario_id == "s6") with multiple per-run summaries —
  # mirror the cross-run unique-holder count as the verdict.
  local post_snaps=()
  for snap in $(snapshots); do
    label=$(snap_field "$snap" '.snapshot_label')
    if [[ "$label" == post_* ]]; then
      post_snaps+=("$snap")
    fi
  done

  if [ ${#post_snaps[@]} -lt 2 ]; then
    echo '{"invariant": "I4", "name": "recovery_coherence", "verdict": "INSUFFICIENT_DATA",
           "note": "fewer than 2 post-fault snapshots — S6 did not complete enough iterations"}'
    return
  fi

  holders=()
  for snap in "${post_snaps[@]}"; do
    h=$(snap_field "$snap" '.control_plane.controller_manager_lease.holder // "unknown"')
    holders+=("$h")
  done

  unique_holders=$(printf '%s\n' "${holders[@]}" | sort -u | grep -v null | wc -l)

  if [ "$unique_holders" -le 1 ]; then
    echo '{"invariant": "I4", "name": "recovery_coherence", "verdict": "PRESERVED",
           "post_fault_snapshots": '"${#post_snaps[@]}"', "distinct_holders": '"$unique_holders"'}'
  else
    HOLDER_LIST=$(printf '"%s",' "${holders[@]}" | sed 's/,$//')
    echo "{\"invariant\": \"I4\", \"name\": \"recovery_coherence\", \"verdict\": \"VIOLATED\",
           \"post_fault_snapshots\": ${#post_snaps[@]}, \"distinct_cm_holders\": $unique_holders,
           \"holder_sequence\": [$HOLDER_LIST]}"
  fi
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
    echo "{\"invariant\": \"I10\", \"name\": \"reconciliation_termination\", \"verdict\": \"VIOLATED\", \"post_fault_snapshots\": ${#post_snaps[@]}, \"first\": \"$first_label\", \"last\": \"$last_label\", \"new_warning_pairs\": $new_count, \"examples\": $(echo "$new_pairs" | jq '.[0:5]')}"
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
  if [ -f "$RESULTS_DIR/scenario_meta.json" ]; then
    required=$(jq -c '[.efficacy.require[]?]' "$RESULTS_DIR/scenario_meta.json" 2>/dev/null || echo '[]')
    target=$(jq -c '.efficacy.target_node // ""' "$RESULTS_DIR/scenario_meta.json" 2>/dev/null || echo '""')
  fi

  # shellcheck disable=SC2086
  jq -s --argjson required "$required" --argjson target "$target" '
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
           end)
      }
    | . as $sig
    | ([ $sig | to_entries[] | select(.value) | .key ]) as $fired
    | ([ $required[] | select((($sig[.]) // false) | not) ]) as $missing
    | {
        signals: $sig,
        fired: $fired,
        required: $required,
        missing_required: $missing,
        verdict:
          (if ($required | length) > 0
           then (if ($missing | length) == 0 then "EFFECTIVE" else "INEFFECTIVE" end)
           else (if ($fired | length) > 0 then "EFFECTIVE" else "INEFFECTIVE" end)
           end),
        note: "EFFECTIVE = the fault produced at least one observable change against the baseline snapshot. INEFFECTIVE = the run measured an undisturbed cluster, so its invariant verdicts describe nothing."
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

I1=$(apply_gate "$(check_i1)" "$CAL_I1")
I2=$(apply_gate "$(check_i2)" "$CAL_I2")
I3=$(apply_gate "$(check_i3)" "$CAL_I3")
I4=$(check_i4)
I5=$(apply_gate "$(check_i5)" "$CAL_I5")
I6=$(check_i6)
I9=$(apply_gate "$(check_i9)" "$CAL_I9")
I10=$(check_i10)

EFFICACY=$(fault_efficacy)
TIMING=$(divergence_timing "$I1" "$I2" "$I3" "$I4" "$I5" "$I6" "$I9" "$I10")

jq -n \
  --arg scenario "$SCENARIO_ID" \
  --arg run "$RUN_ID" \
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
    snapshots_evaluated: $snap_count,
    run_validity: (if $efficacy.verdict == "INEFFECTIVE"
                   then "FAULT_INEFFECTIVE" else "OK" end),
    fault_efficacy: $efficacy,
    invariants: $all,
    summary: {
      preserved:         ($all | map(select(.verdict == "PRESERVED")) | length),
      violated:          ($all | map(select(.verdict == "VIOLATED")) | length),
      insufficient_data: ($all | map(select(.verdict == "INSUFFICIENT_DATA")) | length),
      detector_invalid:  ($all | map(select(.verdict == "DETECTOR_INVALID")) | length)
    },
    divergence_timing: $timing
  }'
