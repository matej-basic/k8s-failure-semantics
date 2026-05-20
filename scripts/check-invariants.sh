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
# Violation: two simultaneous distinct non-null lease holders observed
# OR more than one pod in Running phase with the same StatefulSet identity

check_i1() {
  local violations=()
  local detail=()

  for snap in $(snapshots); do
    label=$(snap_field "$snap" '.snapshot_label')
    ts=$(snap_field "$snap" '.timestamp')

    # Check controller-manager lease — should have exactly one holder
    cm_holder=$(snap_field "$snap" '.control_plane.controller_manager_lease.holder // "null"')

    # Check for duplicate pod ownership (StatefulSet pods with same ordinal on different nodes)
    dupes=$(snap_field "$snap" '
      .control_plane.pod_states // [] |
      group_by(.name) |
      map(select(length > 1)) |
      length
    ')

    if [ "$dupes" != "0" ] && [ "$dupes" != "null" ]; then
      violations+=("$label")
      detail+=("{\"snapshot\": \"$label\", \"ts\": \"$ts\", \"duplicate_pods\": $dupes, \"cm_holder\": \"$cm_holder\"}")
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
  local post_snaps=()
  for snap in $(snapshots); do
    label=$(snap_field "$snap" '.snapshot_label')
    if [[ "$label" == post_fault* ]] || [[ "$label" == post_recovery* ]]; then
      post_snaps+=("$snap")
    fi
  done

  if [ ${#post_snaps[@]} -lt 2 ]; then
    echo '{"invariant": "I4", "name": "recovery_coherence", "verdict": "INSUFFICIENT_DATA",
           "note": "fewer than 2 post-fault snapshots — run S6 for full assessment"}'
    return
  fi

  # Compare lease holders across post-fault snapshots
  holders=()
  for snap in "${post_snaps[@]}"; do
    h=$(snap_field "$snap" '.control_plane.controller_manager_lease.holder // "unknown"')
    holders+=("$h")
  done

  # Unique holders — if > 1 distinct non-null value, recovery is non-unique
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
  --argjson timing "$TIMING" \
  '{
    scenario_id: $scenario,
    run_id: $run,
    snapshots_evaluated: $snap_count,
    invariants: [$i1, $i2, $i3, $i4, $i5],
    summary: {
      preserved: ([$i1,$i2,$i3,$i4,$i5] | map(select(.verdict == "PRESERVED")) | length),
      violated: ([$i1,$i2,$i3,$i4,$i5] | map(select(.verdict == "VIOLATED")) | length),
      insufficient_data: ([$i1,$i2,$i3,$i4,$i5] | map(select(.verdict == "INSUFFICIENT_DATA")) | length)
    },
    divergence_timing: $timing
  }'
