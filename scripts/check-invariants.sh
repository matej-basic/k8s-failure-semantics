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

snapshots() {
  ls "$RESULTS_DIR"/snapshot_*.json 2>/dev/null | sort
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
# Violation: endpoints list contains IPs of pods that are not Running

check_i2() {
  local violations=()
  local detail=()

  for snap in $(snapshots); do
    label=$(snap_field "$snap" '.snapshot_label')
    ts=$(snap_field "$snap" '.timestamp')

    # Check if not-ready addresses exist in endpoint subsets
    not_ready_eps=$(snap_field "$snap" '
      .control_plane.endpoint_states // [] |
      [.[] | .notReadyAddresses // [] | length] | add // 0
    ')

    # Check if external probe returned non-200 while endpoints are listed as ready
    probe_code=$(snap_field "$snap" '.external_probe.httpCode // 200')
    has_endpoints=$(snap_field "$snap" '
      .control_plane.endpoint_states // [] |
      [.[] | select(.service == "nginx-stateless") | .subsets // [] | length] |
      add // 0
    ')

    if [ "$not_ready_eps" != "0" ] && [ "$not_ready_eps" != "null" ]; then
      violations+=("$label")
      detail+=("{\"snapshot\": \"$label\", \"ts\": \"$ts\", \"not_ready_endpoint_count\": $not_ready_eps}")
    fi

    if [ "$probe_code" != "200" ] && [ "$has_endpoints" != "0" ] && [ "$has_endpoints" != "null" ]; then
      violations+=("${label}_probe")
      detail+=("{\"snapshot\": \"$label\", \"ts\": \"$ts\", \"probe_code\": $probe_code, \"endpoints_listed\": $has_endpoints}")
    fi
  done

  if [ ${#violations[@]} -eq 0 ]; then
    echo '{"invariant": "I2", "name": "reachability_publication", "verdict": "PRESERVED", "violations": []}'
  else
    DETAILS=$(IFS=','; echo "[${detail[*]}]")
    echo "{\"invariant\": \"I2\", \"name\": \"reachability_publication\", \"verdict\": \"VIOLATED\", \"violation_count\": ${#violations[@]}, \"violations\": $DETAILS}"
  fi
}

# ── I3: Failure declaration consistency ────────────────────────────────────────
# Violation: a node is NotReady in the API yet pods remain Running on it
# according to the node-local crictl snapshot

check_i3() {
  local violations=()
  local detail=()

  for snap in $(snapshots); do
    label=$(snap_field "$snap" '.snapshot_label')
    ts=$(snap_field "$snap" '.timestamp')

    # Find nodes declared NotReady by the control plane
    not_ready_nodes=$(snap_field "$snap" '
      .control_plane.node_conditions // [] |
      [.[] | select(.conditions[].status == "False") | .name] | @json
    ')

    # For each not-ready node, check if node-local containers report Running
    node_data=$(snap_field "$snap" '.nodes // []')

    # Cross-check: any node in not_ready_nodes that has running containers?
    violation=$(echo "$node_data" | jq --argjson nr "$not_ready_nodes" '
      . as $nodes |
      $nr | map(. as $n | $nodes[] | select(.host == $n) |
        (.containers | fromjson? // []) |
        map(select(.state == "CONTAINER_RUNNING")) | length > 0
      ) | any
    ' 2>/dev/null || echo "false")

    if [ "$violation" = "true" ]; then
      violations+=("$label")
      detail+=("{\"snapshot\": \"$label\", \"ts\": \"$ts\", \"not_ready_nodes\": $not_ready_nodes}")
    fi
  done

  if [ ${#violations[@]} -eq 0 ]; then
    echo '{"invariant": "I3", "name": "failure_declaration_consistency", "verdict": "PRESERVED", "violations": []}'
  else
    DETAILS=$(IFS=','; echo "[${detail[*]}]")
    echo "{\"invariant\": \"I3\", \"name\": \"failure_declaration_consistency\", \"verdict\": \"VIOLATED\", \"violation_count\": ${#violations[@]}, \"violations\": $DETAILS}"
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
# Heuristic: if etcd revision advanced significantly between two snapshots
# but pod states or lease holders did NOT change, controllers may be acting
# on stale state. Also flags Warning events with reason=NodeNotReady on
# nodes that are actually Running.

check_i5() {
  local violations=()
  local detail=()
  local prev_revision=0
  local prev_label=""

  for snap in $(snapshots); do
    label=$(snap_field "$snap" '.snapshot_label')
    ts=$(snap_field "$snap" '.timestamp')
    revision=$(snap_field "$snap" '.etcd.current_revision // 0')

    # Large revision jump (> 500 in a short window) without pod state changes
    # is a signal that reconciliation traffic is high but state is unchanged.
    # Both values must be numeric — during a partition etcd is unreachable
    # and `revision` comes through as the string "null", which would otherwise
    # be dereferenced as a variable name inside $((…)) under `set -u`.
    if [[ "$prev_revision" =~ ^[0-9]+$ ]] && [[ "$revision" =~ ^[0-9]+$ ]] \
       && [ "$prev_revision" != "0" ]; then
      delta=$((revision - prev_revision))
      if [ "$delta" -gt 500 ]; then
        violations+=("$label")
        detail+=("{\"snapshot\": \"$label\", \"ts\": \"$ts\",
                   \"revision_delta\": $delta, \"from\": \"$prev_label\"}")
      fi
    fi

    # Check for Warning events about nodes that our snapshots show as Ready
    warn_count=$(snap_field "$snap" '
      .control_plane.warning_events // [] |
      [.[] | select(.reason == "NodeNotReady" or .reason == "FailedScheduling")] |
      length
    ')

    if [ "$warn_count" != "0" ] && [ "$warn_count" != "null" ]; then
      # Only flag if node conditions simultaneously show Ready (contradiction)
      ready_count=$(snap_field "$snap" '
        .control_plane.node_conditions // [] |
        [.[] | select(.conditions[].status == "True")] | length
      ')
      if [ "$ready_count" != "null" ] && [ "$ready_count" -gt 0 ]; then
        violations+=("${label}_event_mismatch")
        detail+=("{\"snapshot\": \"$label\", \"ts\": \"$ts\",
                   \"warning_events\": $warn_count, \"ready_nodes\": $ready_count}")
      fi
    fi

    prev_revision="$revision"
    prev_label="$label"
  done

  if [ ${#violations[@]} -eq 0 ]; then
    echo '{"invariant": "I5", "name": "observation_action_consistency", "verdict": "PRESERVED", "violations": []}'
  else
    DETAILS=$(IFS=','; echo "[${detail[*]}]")
    echo "{\"invariant\": \"I5\", \"name\": \"observation_action_consistency\", \"verdict\": \"VIOLATED\",
           \"violation_count\": ${#violations[@]}, \"violations\": $DETAILS}"
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
# endpoint status. The substrate-side counterpart to I1: tells you whether
# the consensus layer itself ever lost majority, distinguishing
# "the cluster lost quorum" from "the cluster kept quorum but exposed
# inconsistencies to its observers."
#
# Cluster size n is inferred as the maximum members observed across all
# snapshots. For a 3-member cluster, quorum is 2; for 5, it is 3.

check_i9() {
  local violations=()
  local detail=()
  local total_members=0

  # First pass: find the largest member count observed.
  for snap in $(snapshots); do
    count=$(snap_field "$snap" '.etcd.member_status | length // 0')
    if [[ "$count" =~ ^[0-9]+$ ]] && [ "$count" -gt "$total_members" ]; then
      total_members=$count
    fi
  done

  if [ "$total_members" -lt 3 ]; then
    echo '{"invariant": "I9", "name": "quorum_continuity", "verdict": "INSUFFICIENT_DATA", "note": "no snapshot showed an etcd cluster of >= 3 members; cannot infer quorum threshold"}'
    return
  fi

  local quorum=$(( total_members / 2 + 1 ))

  for snap in $(snapshots); do
    label=$(snap_field "$snap" '.snapshot_label')
    ts=$(snap_field "$snap" '.timestamp')
    healthy=$(snap_field "$snap" '.etcd.member_status | length // 0')

    if [[ "$healthy" =~ ^[0-9]+$ ]] && [ "$healthy" -lt "$quorum" ]; then
      violations+=("$label")
      detail+=("{\"snapshot\": \"$label\", \"ts\": \"$ts\",
                 \"healthy_members\": $healthy, \"quorum_required\": $quorum,
                 \"cluster_size\": $total_members}")
    fi
  done

  if [ ${#violations[@]} -eq 0 ]; then
    echo "{\"invariant\": \"I9\", \"name\": \"quorum_continuity\", \"verdict\": \"PRESERVED\", \"cluster_size\": $total_members, \"quorum_threshold\": $quorum, \"violations\": []}"
  else
    DETAILS=$(IFS=','; echo "[${detail[*]}]")
    echo "{\"invariant\": \"I9\", \"name\": \"quorum_continuity\", \"verdict\": \"VIOLATED\", \"cluster_size\": $total_members, \"quorum_threshold\": $quorum, \"violation_count\": ${#violations[@]}, \"violations\": $DETAILS}"
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
# Records the first snapshot at which any invariant was violated,
# relative to the first snapshot after fault injection.

divergence_timing() {
  local first_fault_snap=""
  local first_violation_snap=""
  local first_service_failure_snap=""

  for snap in $(snapshots); do
    label=$(snap_field "$snap" '.snapshot_label')
    ts=$(snap_field "$snap" '.timestamp')

    # First non-prefault snapshot = fault is active
    if [[ "$label" != "pre_fault" ]] && [ -z "$first_fault_snap" ]; then
      first_fault_snap="$label"
    fi

    # First snapshot with a Warning event or non-200 probe = service degradation
    probe=$(snap_field "$snap" '.external_probe.httpCode // 200')
    warns=$(snap_field "$snap" '.control_plane.warning_events // [] | length')
    if [ "$probe" != "200" ] && [ -z "$first_service_failure_snap" ]; then
      first_service_failure_snap="$label"
    fi
  done

  echo "{\"first_fault_snapshot\": \"$first_fault_snap\",
         \"first_service_failure_snapshot\": \"${first_service_failure_snap:-none}\"}"
}

# ── Assemble and print final report ───────────────────────────────────────────

SCENARIO_ID=$(snap_field "$(snapshots | head -1)" '.scenario_id // "unknown"')
RUN_ID=$(snap_field "$(snapshots | head -1)" '.run_id // "unknown"')
SNAP_COUNT=$(snapshots | wc -l)

I1=$(check_i1)
I2=$(check_i2)
I3=$(check_i3)
I4=$(check_i4)
I5=$(check_i5)
I6=$(check_i6)
I9=$(check_i9)
I10=$(check_i10)
TIMING=$(divergence_timing)

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
  --argjson timing "$TIMING" \
  '{
    scenario_id: $scenario,
    run_id: $run,
    snapshots_evaluated: $snap_count,
    invariants: [$i1, $i2, $i3, $i4, $i5, $i6, $i9, $i10],
    summary: {
      preserved: ([$i1,$i2,$i3,$i4,$i5,$i6,$i9,$i10] | map(select(.verdict == "PRESERVED")) | length),
      violated: ([$i1,$i2,$i3,$i4,$i5,$i6,$i9,$i10] | map(select(.verdict == "VIOLATED")) | length),
      insufficient_data: ([$i1,$i2,$i3,$i4,$i5,$i6,$i9,$i10] | map(select(.verdict == "INSUFFICIENT_DATA")) | length)
    },
    divergence_timing: $timing
  }'
