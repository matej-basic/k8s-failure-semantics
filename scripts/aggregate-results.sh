#!/bin/bash
# scripts/aggregate-results.sh
# Cross-scenario analysis: reads all invariant_report.json files and
# produces the heatmap data (Figure 7 in the paper) plus timing comparisons.
# Usage: aggregate-results.sh <results_base>

set -euo pipefail

BASE="${1:-/opt/k8s-results}"

SCENARIOS=(s1 s2 s3 s4 s5 s6 s8 s11 s12 s15 s17 s18 s19)
INVARIANTS=(I1 I2 I3 I4 I5)

# ── Collect per-scenario invariant verdicts ───────────────────────────────────

collect_verdicts() {
  local out='[]'
  for sc in "${SCENARIOS[@]}"; do
    # Find the most recent run directory for this scenario
    report=$(find "$BASE/$sc" -name "invariant_report.json" 2>/dev/null \
      | sort | tail -1)

    if [ -z "$report" ]; then
      row=$(jq -n --arg sc "$sc" \
        '{scenario: $sc, I1: "NO_DATA", I2: "NO_DATA", I3: "NO_DATA", I4: "NO_DATA", I5: "NO_DATA"}')
    else
      row=$(jq --arg sc "$sc" '
        . as $r |
        {
          scenario: $sc,
          I1: ($r.invariants[] | select(.invariant == "I1") | .verdict),
          I2: ($r.invariants[] | select(.invariant == "I2") | .verdict),
          I3: ($r.invariants[] | select(.invariant == "I3") | .verdict),
          I4: ($r.invariants[] | select(.invariant == "I4") | .verdict),
          I5: ($r.invariants[] | select(.invariant == "I5") | .verdict)
        }
      ' "$report" 2>/dev/null || \
      jq -n --arg sc "$sc" \
        '{scenario: $sc, I1: "PARSE_ERROR", I2: "PARSE_ERROR", I3: "PARSE_ERROR", I4: "PARSE_ERROR", I5: "PARSE_ERROR"}')
    fi

    out=$(echo "$out" | jq --argjson row "$row" '. + [$row]')
  done
  echo "$out"
}

# ── Divergence vs service failure timing ─────────────────────────────────────

collect_timing() {
  local out='[]'
  for sc in "${SCENARIOS[@]}"; do
    report=$(find "$BASE/$sc" -name "invariant_report.json" 2>/dev/null \
      | sort | tail -1)
    if [ -n "$report" ]; then
      timing=$(jq --arg sc "$sc" \
        '{scenario: $sc, timing: .divergence_timing}' "$report" 2>/dev/null \
        || jq -n --arg sc "$sc" '{scenario: $sc, timing: null}')
      out=$(echo "$out" | jq --argjson t "$timing" '. + [$t]')
    fi
  done
  echo "$out"
}

# ── S6 repeat-run recovery variance ──────────────────────────────────────────

collect_recovery_variance() {
  local s6_dir="$BASE/s6"
  if [ ! -d "$s6_dir" ]; then
    echo '{"scenario": "s6", "variance": "NO_DATA"}'
    return
  fi

  summaries=$(find "$s6_dir" -name "run_summary.json" 2>/dev/null | sort)
  if [ -z "$summaries" ]; then
    echo '{"scenario": "s6", "variance": "NO_DATA"}'
    return
  fi

  # Collect all final lease holders from each run
  holders=()
  for s in $summaries; do
    h=$(jq -r '.final_lease_holder // "unknown"' "$s" 2>/dev/null || echo "unknown")
    holders+=("$h")
  done

  run_count=${#holders[@]}
  unique_holders=$(printf '%s\n' "${holders[@]}" | sort -u | wc -l)

  HOLDER_LIST=$(printf '"%s",' "${holders[@]}" | sed 's/,$//')

  jq -n \
    --argjson runs "$run_count" \
    --argjson unique "$unique_holders" \
    --argjson deterministic "$([ "$unique_holders" -eq 1 ] && echo true || echo false)" \
    "{
      scenario: \"s6\",
      run_count: \$runs,
      unique_final_states: \$unique,
      deterministic_recovery: \$deterministic,
      lease_holders: [$HOLDER_LIST]
    }"
}

# ── Amplification metrics (S5, S8, S12) ──────────────────────────────────────

collect_amplification() {
  local out='[]'
  for sc in s5 s8 s12; do
    amp_file=$(find "$BASE/$sc" -name "amplification_metrics.json" 2>/dev/null | sort | tail -1)
    lease_file=$(find "$BASE/$sc" -name "lease_analysis.json" 2>/dev/null | sort | tail -1)

    if [ -n "$amp_file" ]; then
      entry=$(jq --arg sc "$sc" '. + {scenario: $sc}' "$amp_file" 2>/dev/null \
        || jq -n --arg sc "$sc" '{scenario: $sc, data: "PARSE_ERROR"}')
      out=$(echo "$out" | jq --argjson e "$entry" '. + [$e]')
    elif [ -n "$lease_file" ]; then
      entry=$(jq --arg sc "$sc" '. + {scenario: $sc}' "$lease_file" 2>/dev/null \
        || jq -n --arg sc "$sc" '{scenario: $sc, data: "PARSE_ERROR"}')
      out=$(echo "$out" | jq --argjson e "$entry" '. + [$e]')
    fi
  done
  echo "$out"
}

# ── S15 termination race timing ───────────────────────────────────────────────

collect_termination_timing() {
  local s15_dir
  s15_dir=$(find "$BASE/s15" -maxdepth 2 -type d 2>/dev/null | sort | tail -1)
  if [ -z "$s15_dir" ]; then
    echo '{"scenario": "s15", "data": "NO_DATA"}'
    return
  fi

  deletion_ts=$(cat "$s15_dir/pod_deletion_ts.txt" 2>/dev/null || echo "unknown")
  endpoint_ts=$(cat "$s15_dir/endpoint_removal_ts.txt" 2>/dev/null || echo "unknown")
  traffic=$(cat "$s15_dir/traffic_analysis.json" 2>/dev/null || echo 'null')

  jq -n \
    --arg del "$deletion_ts" \
    --arg ep "$endpoint_ts" \
    --argjson traffic "$traffic" \
    '{
      scenario: "s15",
      pod_deletion_ts: $del,
      endpoint_removal_ts: $ep,
      traffic: $traffic
    }'
}

# ── Assemble final aggregate report ──────────────────────────────────────────

VERDICTS=$(collect_verdicts)
TIMING=$(collect_timing)
VARIANCE=$(collect_recovery_variance)
AMPLIFICATION=$(collect_amplification)
TERMINATION=$(collect_termination_timing)

# Overall statistics
TOTAL_PRESERVED=$(echo "$VERDICTS" | jq '[.[].I1, .[].I2, .[].I3, .[].I4, .[].I5 | select(. == "PRESERVED")] | length')
TOTAL_VIOLATED=$(echo "$VERDICTS" | jq '[.[].I1, .[].I2, .[].I3, .[].I4, .[].I5 | select(. == "VIOLATED")] | length')

jq -n \
  --argjson verdicts "$VERDICTS" \
  --argjson timing "$TIMING" \
  --argjson variance "$VARIANCE" \
  --argjson amplification "$AMPLIFICATION" \
  --argjson termination "$TERMINATION" \
  --argjson preserved "$TOTAL_PRESERVED" \
  --argjson violated "$TOTAL_VIOLATED" \
  '{
    generated_at: now | todate,
    summary: {
      total_invariant_checks: ($preserved + $violated),
      total_preserved: $preserved,
      total_violated: $violated,
      violation_rate_pct: (if ($preserved + $violated) > 0
        then ($violated * 100 / ($preserved + $violated) | round)
        else 0 end)
    },
    invariant_heatmap: $verdicts,
    divergence_timing: $timing,
    recovery_variance_s6: $variance,
    amplification_metrics: $amplification,
    termination_race_s15: $termination
  }'
