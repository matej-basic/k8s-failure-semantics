#!/bin/bash
# scripts/aggregate-results.sh
# Cross-scenario analysis: reads all invariant_report.json files and
# produces the heatmap data (Figure 7 in the paper) plus timing comparisons.
# Usage: aggregate-results.sh <results_base>

set -euo pipefail

BASE="${1:-/opt/k8s-results}"

SCENARIOS=(s1 s2 s3 s4 s5 s6 s8 s11 s12 s14 s15 s17 s18 s19 s20 s21 s22 s23 s24 s25 s26 s27 s28)
INVARIANTS=(I1 I2 I3 I4 I5 I6 I9 I10)

# ── Collect per-scenario invariant verdicts ───────────────────────────────────

collect_verdicts() {
  local out='[]'
  for sc in "${SCENARIOS[@]}"; do
    # Find the most recent run directory for this scenario
    report=$(find "$BASE/$sc" -name "invariant_report.json" 2>/dev/null \
      | sort | tail -1)

    if [ -z "$report" ]; then
      # NO_DATA means the scenario never produced a report — it was skipped or
      # it died mid-run. That is not the same as a scenario that ran and found
      # nothing, and the row carries run_validity so the two cannot be read as
      # the same thing (S5 and S6 sat in the May 2026 heatmap as NO_DATA rows
      # beside real verdicts, and I4 went unevaluated suite-wide as a result).
      row=$(jq -n --arg sc "$sc" \
        '{scenario: $sc, run_validity: "NOT_RUN", fault_efficacy: null,
          I1: "NO_DATA", I2: "NO_DATA", I3: "NO_DATA", I4: "NO_DATA", I5: "NO_DATA", I6: "NO_DATA", I9: "NO_DATA", I10: "NO_DATA"}')
    else
      # Build the row by indexing each invariant we know about. Using //
      # "NO_DATA" gracefully handles reports written before I6/I9/I10
      # existed (older runs whose checker did not emit them).
      row=$(jq --arg sc "$sc" '
        (.invariants // []) as $inv |
        ($inv | map({(.invariant): .verdict}) | add) as $by_id |
        {
          scenario: $sc,
          run_validity: (.run_validity // "UNKNOWN"),
          fault_efficacy: (if .fault_efficacy
                           then {verdict: .fault_efficacy.verdict,
                                 fired: (.fault_efficacy.fired // []),
                                 missing_required: (.fault_efficacy.missing_required // [])}
                           else null end),
          I1:  ($by_id.I1  // "NO_DATA"),
          I2:  ($by_id.I2  // "NO_DATA"),
          I3:  ($by_id.I3  // "NO_DATA"),
          I4:  ($by_id.I4  // "NO_DATA"),
          I5:  ($by_id.I5  // "NO_DATA"),
          I6:  ($by_id.I6  // "NO_DATA"),
          I9:  ($by_id.I9  // "NO_DATA"),
          I10: ($by_id.I10 // "NO_DATA")
        }
      ' "$report" 2>/dev/null || \
      jq -n --arg sc "$sc" \
        '{scenario: $sc, run_validity: "PARSE_ERROR", fault_efficacy: null, I1: "PARSE_ERROR", I2: "PARSE_ERROR", I3: "PARSE_ERROR", I4: "PARSE_ERROR", I5: "PARSE_ERROR", I6: "PARSE_ERROR", I9: "PARSE_ERROR", I10: "PARSE_ERROR"}')
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

# Overall statistics.
#
# Counted over runs whose fault actually did something: a run labelled
# FAULT_INEFFECTIVE measured an undisturbed cluster, so its verdicts describe
# nothing and must not enter the rate. DETECTOR_INVALID verdicts are counted
# separately for the same reason — they are disqualified detectors, not
# findings, and folding them into the denominator is how the May 2026 sweep
# arrived at a 45% violation rate built largely on artifacts.
VALID_VERDICTS=$(echo "$VERDICTS" | jq '[.[] | select((.run_validity // "UNKNOWN") != "FAULT_INEFFECTIVE" and (.run_validity // "UNKNOWN") != "NOT_RUN")]')
TOTAL_PRESERVED=$(echo "$VALID_VERDICTS" | jq '[.[].I1, .[].I2, .[].I3, .[].I4, .[].I5, .[].I6, .[].I9, .[].I10 | select(. == "PRESERVED")] | length')
TOTAL_VIOLATED=$(echo "$VALID_VERDICTS" | jq '[.[].I1, .[].I2, .[].I3, .[].I4, .[].I5, .[].I6, .[].I9, .[].I10 | select(. == "VIOLATED")] | length')
TOTAL_INVALID=$(echo "$VERDICTS" | jq '[.[].I1, .[].I2, .[].I3, .[].I4, .[].I5, .[].I6, .[].I9, .[].I10 | select(. == "DETECTOR_INVALID")] | length')
RUNS_INEFFECTIVE=$(echo "$VERDICTS" | jq '[.[] | select(.run_validity == "FAULT_INEFFECTIVE")] | length')
RUNS_NOT_RUN=$(echo "$VERDICTS" | jq '[.[] | select(.run_validity == "NOT_RUN")] | length')

jq -n \
  --argjson verdicts "$VERDICTS" \
  --argjson timing "$TIMING" \
  --argjson variance "$VARIANCE" \
  --argjson amplification "$AMPLIFICATION" \
  --argjson termination "$TERMINATION" \
  --argjson preserved "$TOTAL_PRESERVED" \
  --argjson violated "$TOTAL_VIOLATED" \
  --argjson invalid "$TOTAL_INVALID" \
  --argjson ineffective "$RUNS_INEFFECTIVE" \
  --argjson notrun "$RUNS_NOT_RUN" \
  '{
    generated_at: now | todate,
    summary: {
      total_invariant_checks: ($preserved + $violated),
      total_preserved: $preserved,
      total_violated: $violated,
      detectors_invalidated: $invalid,
      runs_fault_ineffective: $ineffective,
      scenarios_not_run: $notrun,
      violation_rate_pct: (if ($preserved + $violated) > 0
        then ($violated * 100 / ($preserved + $violated) | round)
        else 0 end),
      counting_note: "Rates cover runs whose fault produced an observable change. DETECTOR_INVALID verdicts (invariants already violated at baseline) and FAULT_INEFFECTIVE runs are reported separately and excluded from the denominator."
    },
    invariant_heatmap: $verdicts,
    divergence_timing: $timing,
    recovery_variance_s6: $variance,
    amplification_metrics: $amplification,
    termination_race_s15: $termination
  }'
