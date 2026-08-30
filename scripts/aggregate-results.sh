#!/bin/bash
# scripts/aggregate-results.sh
# Cross-scenario analysis: reads all invariant_report.json files and
# produces the heatmap data (Figure 7 in the paper) plus timing comparisons.
# Usage: aggregate-results.sh <results_base>
#
# Reads both results layouts: a single run (results/<sN>/<run_id>/) and a
# repeated batch written by scripts/repeat-scenario.sh
# (results/<sN>/<run_id>/run_<K>/). For a batch it also produces the cross-run
# statistics REVIEW.md M3 asks for: violation FREQUENCY per invariant instead
# of a boolean, median and IQR for every timing measurement, and a real I4
# (recovery coherence) computed across the repetitions.

set -euo pipefail

BASE="${1:-/opt/k8s-results}"

SCENARIOS=(s1 s2 s3 s4 s5 s6 s8 s11 s12 s14 s15 s17 s18 s19 s20 s21 s22 s23 s24 s25 s26 s27 s28)
INVARIANTS=(I1 I2 I3 I4 I5 I6 I9 I10)

# ── Repeated-batch layout (REVIEW.md M3) ─────────────────────────────────────
#
# scripts/repeat-scenario.sh runs any scenario K times and writes
#
#     results/<sN>/<run_id>/repeat_manifest.json        batch level
#     results/<sN>/<run_id>/run_1/ … run_<K>/            one ordinary run each,
#                                                        plus iteration_meta.json
#
# while a single run is still results/<sN>/<run_id>/ with the snapshots
# directly inside it. A <run_id> is a repeated batch iff it carries a
# repeat_manifest.json, or it has run_<K>/ subdirectories and no snapshots of
# its own — the same discriminator scripts/build-report.sh uses (commit
# b328713). The two must not drift apart.
#
# Two rules the rest of this file depends on:
#
#   NUMERIC SORT. Iteration directories are run_1 … run_<K>, not zero padded,
#   so `find … | sort | tail -1` orders run_10 before run_2. collect_verdicts
#   and collect_timing both used to do exactly that to pick "the most recent
#   run", which silently reads the wrong iteration as soon as a batch passes
#   nine runs. Every listing below sorts numerically.
#
#   ONE BATCH AT A TIME. All iterations of a batch share one run_id and one
#   cluster state; statistics are computed WITHIN a batch. Merging every batch
#   a scenario ever produced (which is what `find "$BASE/s6" -name
#   run_summary.json` did) mixes cluster states and is not a sample of
#   anything.
#
# Only iterations whose iteration_meta.json says status "ok" enter the
# statistics: a failed iteration can have written partial snapshots.

# All run_<K> subdirectories of a batch root, in NUMERIC order.
iter_dirs_of() {  # $1 = batch root
  local root="$1" d name num
  for d in "$root"/run_*/; do
    [ -d "$d" ] || continue
    d="${d%/}"
    name=$(basename "$d")
    num="${name#run_}"
    case "$num" in ''|*[!0-9]*) continue ;; esac
    printf '%d\t%s\n' "$((10#$num))" "$d"
  done | LC_ALL=C sort -n -k1,1 | cut -f2
}

is_batch() {  # $1 = <run_id> dir
  if [ -f "$1/repeat_manifest.json" ]; then return 0; fi
  if [ -n "$(iter_dirs_of "$1")" ] && ! ls "$1"/snapshot_*.json >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

# Where one run's invariant report is. Some scenarios write invariant_report.txt
# (raw JSON) instead of .json; build-report.sh accepts both, so we do too.
report_of() {  # $1 = single-run dir
  if [ -f "$1/invariant_report.json" ]; then printf '%s\n' "$1/invariant_report.json"; return 0; fi
  if [ -f "$1/invariant_report.txt" ]; then printf '%s\n' "$1/invariant_report.txt"; return 0; fi
  return 1
}

run_has_data() {  # $1 = single-run dir
  if report_of "$1" >/dev/null 2>&1; then return 0; fi
  if ls "$1"/snapshot_*.json >/dev/null 2>&1; then return 0; fi
  return 1
}

# The newest <run_id> for a scenario that actually holds data. A run_id that
# produced an invariant report wins over one that only got as far as snapshots,
# so a batch that died before its first report cannot hide the last good one.
latest_batch() {  # $1 = scenario
  # bash 3.2 + `set -u`: a later name in the same `local` cannot reference an
  # earlier one, so the derived paths are assigned on their own lines.
  local sc="$1" name dirs d fallback=""
  local base="$BASE/$sc"
  [ -d "$base" ] || return 0
  for name in $(ls -1 "$base" 2>/dev/null | LC_ALL=C sort -r); do
    [ -d "$base/$name" ] || continue
    dirs=$(batch_run_dirs "$sc" "$name")
    [ -n "$dirs" ] || continue
    [ -n "$fallback" ] || fallback="$name"
    for d in $dirs; do
      if report_of "$d" >/dev/null 2>&1; then printf '%s\n' "$name"; return 0; fi
    done
  done
  if [ -n "$fallback" ]; then printf '%s\n' "$fallback"; fi
  return 0
}

# THE code path both layouts read through: the completed iterations of a
# repeated batch (numeric order), or — for a single run — the run_id directory
# itself, so a single run is simply a batch of one and no caller needs to know
# which layout it is looking at.
batch_run_dirs() {  # $1 = scenario, $2 = run_id
  local sc="$1" rid="$2" d status
  local root="$BASE/$sc/$rid"
  [ -d "$root" ] || return 0
  if is_batch "$root"; then
    for d in $(iter_dirs_of "$root"); do
      status="ok"
      if [ -f "$d/iteration_meta.json" ]; then
        status=$(jq -r '.status // "ok"' "$d/iteration_meta.json" 2>/dev/null || echo "ok")
      fi
      [ "$status" = "ok" ] || continue
      run_has_data "$d" || continue
      printf '%s\n' "$d"
    done
  else
    if run_has_data "$root"; then printf '%s\n' "$root"; fi
  fi
}

batch_n() {  # $1 = scenario, $2 = run_id -> number of usable iterations
  # awk, not `grep -c`: grep exits 1 on an empty batch and `set -e` would turn
  # a zero count into a dead script.
  batch_run_dirs "$1" "$2" | awk 'END { print NR + 0 }'
}

batch_layout() {  # $1 = scenario, $2 = run_id
  if [ -d "$BASE/$1/$2" ] && is_batch "$BASE/$1/$2"; then echo repeated; else echo single; fi
}

# How many iterations the harness set out to run — the denominator for "did the
# batch finish". Falls back to what is on disk when there is no manifest.
batch_planned() {  # $1 = scenario, $2 = run_id
  local root="$BASE/$1/$2" p
  if [ -f "$root/repeat_manifest.json" ]; then
    p=$(jq -r '.iterations_planned // empty' "$root/repeat_manifest.json" 2>/dev/null || echo "")
    case "$p" in ''|*[!0-9]*) ;; *) printf '%s\n' "$p"; return 0 ;; esac
  fi
  batch_n "$1" "$2"
}

batch_reports() {  # $1 = scenario, $2 = run_id -> report paths, numeric order
  local d
  for d in $(batch_run_dirs "$1" "$2"); do
    report_of "$d" 2>/dev/null || true
  done
}

# Snapshots of one run directory in CHRONOLOGICAL order (.snapshot_index, then
# .timestamp) — the same key check-invariants.sh orders by, never filename
# order.
ordered_snapshots() {  # $1 = single-run dir
  local dir="$1" f idx ts
  for f in "$dir"/snapshot_*.json; do
    [ -e "$f" ] || continue
    idx=$(jq -r '.snapshot_index // empty' "$f" 2>/dev/null || echo "")
    ts=$(jq -r '.timestamp // empty' "$f" 2>/dev/null || echo "")
    case "$idx" in ''|*[!0-9]*) idx=9999 ;; esac
    [ -n "$ts" ] || ts="9999-99-99T99:99:99Z"
    printf '%04d\t%s\t%s\n' "$idx" "$ts" "$f"
  done | LC_ALL=C sort -k1,1 -k2,2 | cut -f3
}

# The final post-fault state of ONE run, as a single comparable string. Must
# stay in step with i4_final_state() in check-invariants.sh — the two scripts
# are independent, but they have to answer this question the same way.
#   1. run_summary.json .final_lease_holder   (S6 writes it; any scenario may)
#   2. run_summary.json .final_pod_placement  when there is no holder
#   3. the last snapshot labelled post_*, else the last snapshot, read at
#      .control_plane.controller_manager_lease.holder
# Empty output means unreadable; the caller counts that separately and keeps it
# out of the distinct-state count.
#
# The fingerprint describes CLUSTER STATE, not lease identity. It used to be
# the controller-manager lease holder, which is `<node>_<uuid>` with the uuid
# minted per acquisition — so five repetitions produced five distinct strings
# whether or not they converged, and I4 came back VIOLATED in 22 of 23
# scenarios (REVIEW.md D34):
#
#   run_1 cp2_94b2cc66-…   run_3 cp2_d731d495-…   same node, different uuid
#
# Stripping the uuid would not have fixed it either: which control-plane node
# wins a leader election after a fault is not what I4 asks. I4 asks whether
# repetitions of one fault converge to the same cluster state.
#
# So: the Ready node set, the running workload set by REPLICA COUNT, and the
# healthy etcd member count. Pod names carry a ReplicaSet hash and a random
# suffix and are stripped to the workload — including them would reintroduce
# exactly the defect above. Placement is deliberately NOT part of the
# fingerprint: which worker hosts a replacement replica is scheduler
# non-determinism, not a recovery-determinism violation.
final_state_of() {  # $1 = single-run dir
  local dir="$1" snap last post label
  last=""; post=""
  for snap in $(ordered_snapshots "$dir"); do
    last="$snap"
    label=$(jq -r '.snapshot_label // ""' "$snap" 2>/dev/null || echo "")
    case "$label" in
      post_*) post="$snap" ;;
    esac
  done
  snap="${post:-$last}"
  [ -n "$snap" ] || { printf '\n'; return 0; }

  # An unreadable control-plane view yields empty output, which the caller
  # counts as runs_unreadable rather than as a state of its own — counting it
  # as a distinct state is how an incomplete batch becomes a false VIOLATED.
  jq -r '
    if ((.control_plane.node_conditions // []) | length) == 0 then ""
    else
      ([ .control_plane.node_conditions[]?
         | select((.conditions[]? | select(.type == "Ready") | .status) == "True")
         | .name ] | sort | join(",")) as $nodes
      | ([ .control_plane.pod_states[]?
           | select(.phase == "Running")
           | (.name | sub("-[a-z0-9]{8,10}-[a-z0-9]{5}$"; "")) ]
         | group_by(.) | map("\(.[0])=\(length)") | sort | join(",")) as $wl
      | ([ .etcd.member_status[]?
           | select(((.Status.errors // []) | length) == 0) ] | length) as $etcd
      | "nodes[\($nodes)] wl[\($wl)] etcd[\($etcd)]"
    end' "$snap" 2>/dev/null || echo ""
}

# ── Cross-run recovery variance (I4's evidence) ───────────────────────────────
# Generalised beyond S6: any scenario with more than one completed iteration in
# one batch gets an entry. Iterating batch_run_dirs of ONE batch is deliberate —
# the previous implementation ran `find "$BASE/s6" -name run_summary.json`,
# which merges every batch S6 ever produced into one sample.
#
# `unknown` and null are filtered OUT of unique_final_states and reported as
# runs_unreadable instead. Counting them as states of their own turns an
# incomplete batch into "recovery is non-deterministic" — a false VIOLATED.
collect_recovery_variance() {  # $1 = scenario
  local sc="$1" rid layout n planned d st
  local states run_numbers
  states=(); run_numbers=()

  rid=$(latest_batch "$sc")
  if [ -z "$rid" ]; then
    # Historical shape, kept verbatim so anything reading
    # recovery_variance_s6.variance still recognises "no data".
    jq -n --arg sc "$sc" '{scenario: $sc, variance: "NO_DATA"}'
    return
  fi

  layout=$(batch_layout "$sc" "$rid")
  planned=$(batch_planned "$sc" "$rid")

  for d in $(batch_run_dirs "$sc" "$rid"); do
    st=$(final_state_of "$d")
    case "$st" in
      ""|null|unknown|Unknown|UNKNOWN) st="unknown" ;;
    esac
    states+=("$st")
    case "$(basename "$d")" in
      run_*) run_numbers+=("$(basename "$d" | sed 's/^run_//')") ;;
      *)     run_numbers+=(1) ;;
    esac
  done

  n=${#states[@]}
  local states_json numbers_json
  if [ "$n" -eq 0 ]; then states_json='[]'; numbers_json='[]'
  else
    states_json=$(printf '%s\n' "${states[@]}" | jq -R . | jq -cs .)
    numbers_json=$(printf '%s\n' "${run_numbers[@]}" | jq -R . | jq -cs 'map(tonumber? // .)')
  fi

  jq -n \
    --arg sc "$sc" \
    --arg rid "$rid" \
    --arg layout "$layout" \
    --argjson n "$n" \
    --argjson planned "$planned" \
    --argjson holders "$states_json" \
    --argjson run_numbers "$numbers_json" \
    '($holders | map(select(. != "unknown" and . != "" and . != null))) as $readable
     | ($readable | unique | length) as $uniq
     | ((($holders | length) - ($readable | length))) as $unreadable
     | {
         scenario: $sc,
         run_id: $rid,
         layout: $layout,
         run_count: $n,
         run_numbers: $run_numbers,
         runs_expected: $planned,
         runs_unreadable: $unreadable,
         unique_final_states: $uniq,
         deterministic_recovery: (if $n < 2 or $uniq == 0 then null
                                  else ($uniq == 1) end),
         lease_holders: $holders,
         # The batch-root I4 verdict. This is the verdict OF RECORD: unlike the
         # per-iteration reports (each written before the batch finished) this
         # one sees every completed iteration.
         i4_verdict: (if $n < 2 then "INSUFFICIENT_DATA"
                      elif $uniq == 0 then "INSUFFICIENT_DATA"
                      elif $uniq <= 1 then "PRESERVED"
                      else "VIOLATED" end),
         note: (if $n < 2
                then "fewer than 2 completed iterations in this batch — I4 needs N > 1"
                elif $uniq == 0
                then "no iteration produced a readable final state"
                elif $uniq <= 1
                then "all readable repetitions converged to the same final state"
                else "repetitions of one fault reached \($uniq) different final states" end)
       }'
}

collect_recovery_variance_all() {
  local out='[]' sc rid n entry
  for sc in "${SCENARIOS[@]}"; do
    rid=$(latest_batch "$sc")
    [ -n "$rid" ] || continue
    n=$(batch_n "$sc" "$rid")
    [ "$n" -gt 1 ] || continue
    entry=$(collect_recovery_variance "$sc")
    out=$(printf '%s' "$out" | jq --argjson e "$entry" '. + [$e]')
  done
  printf '%s' "$out"
}

# ── Collect per-scenario invariant verdicts ───────────────────────────────────

collect_verdicts() {
  local out='[]' sc rid layout n planned reports row
  for sc in "${SCENARIOS[@]}"; do
    rid=$(latest_batch "$sc")
    reports=""
    if [ -n "$rid" ]; then
      reports=$(batch_reports "$sc" "$rid")
    fi

    if [ -z "$reports" ]; then
      # NO_DATA means the scenario never produced a report — it was skipped or
      # it died mid-run. That is not the same as a scenario that ran and found
      # nothing, and the row carries run_validity so the two cannot be read as
      # the same thing (S5 and S6 sat in the May 2026 heatmap as NO_DATA rows
      # beside real verdicts, and I4 went unevaluated suite-wide as a result).
      row=$(jq -n --arg sc "$sc" \
        '{scenario: $sc, run_validity: "NOT_RUN", fault_class: null, fault_efficacy: null,
          not_applicable: {}, layout: "none", n: 0, n_planned: 0, frequency: {},
          I1: "NO_DATA", I2: "NO_DATA", I3: "NO_DATA", I4: "NO_DATA", I5: "NO_DATA", I6: "NO_DATA", I9: "NO_DATA", I10: "NO_DATA"}')
    else
      layout=$(batch_layout "$sc" "$rid")
      n=$(batch_n "$sc" "$rid")
      planned=$(batch_planned "$sc" "$rid")

      # One jq over EVERY iteration report of the batch, in numeric run order.
      # A single run is a batch of one and takes the identical path, which is
      # why the scalar row it produces is byte-for-byte what it always was.
      row=$(jq -s --arg sc "$sc" --arg layout "$layout" \
                  --argjson planned "$planned" --argjson recovery "$RECOVERY" '
        . as $reports
        | ($reports | length) as $n
        | ($reports | last) as $meta
        | ["I1","I2","I3","I4","I5","I6","I9","I10"] as $ids
        # verdict tables, one object per iteration: {"I1": "PRESERVED", …}
        | [ $reports[] | (.invariants // []) | map({key: .invariant, value: .verdict}) | from_entries ] as $byrun

        # Verdict of record for the heatmap cell. VIOLATED if any repetition
        # violated it — one reproducible violation is a finding, and averaging
        # it away would be the wrong reduction; else PRESERVED if any
        # repetition could evaluate it at all; else the most common
        # non-evaluable label (ties broken by label, so the output is stable).
        | ( $ids
            | map( . as $id
                   | ([ $byrun[] | .[$id] // null | select(. != null) ]) as $vs
                   | { key: $id,
                       value: (if ($vs | length) == 0 then "NO_DATA"
                               elif ($vs | any(. == "VIOLATED")) then "VIOLATED"
                               elif ($vs | any(. == "PRESERVED")) then "PRESERVED"
                               else ($vs | group_by(.) | map({v: .[0], c: length})
                                         | sort_by([.c, .v]) | last | .v) end) } )
            | from_entries ) as $scalar

        # How often each invariant was violated across the repetitions.
        # violation_frequency uses the suite-wide denominator (PRESERVED +
        # VIOLATED, i.e. `evaluable`) — the same population summary.denominator
        # is computed over — and is null when nothing was evaluable. n is the
        # number of repetitions that reported this invariant at all.
        | ( $ids
            | map( . as $id
                   | ([ $byrun[] | .[$id] // null | select(. != null) ]) as $vs
                   | ([ $vs[] | select(. == "VIOLATED") ] | length) as $viol
                   | ([ $vs[] | select(. == "PRESERVED") ] | length) as $pres
                   | { key: $id,
                       value: { n: ($vs | length),
                                violated: $viol,
                                preserved: $pres,
                                insufficient_data: ([ $vs[] | select(. == "INSUFFICIENT_DATA") ] | length),
                                not_applicable:    ([ $vs[] | select(. == "NOT_APPLICABLE") ] | length),
                                detector_invalid:  ([ $vs[] | select(. == "DETECTOR_INVALID") ] | length),
                                evaluable: ($viol + $pres),
                                # fraction of evaluable repetitions that
                                # violated, 4 dp; null when nothing in the
                                # batch was evaluable
                                violation_frequency:
                                  (if ($viol + $pres) > 0
                                   then (($viol * 10000 / ($viol + $pres) | round) / 10000)
                                   else null end) } } )
            | from_entries
            # I4 is computed ACROSS the batch, not per run. Each iteration own
            # invariant_report.json carries a provisional I4 that predates the
            # D34 fingerprint fix and is spuriously VIOLATED almost everywhere.
            # Tallying those provisional values here produced a frequency block
            # contradicting the corrected verdict beside it: s2 showed
            # I4 = PRESERVED next to frequency.I4 violated 4, frequency 1.
            # A reader quoting the frequency would get it exactly backwards
            # (REVIEW.md D38).
            #
            # The counts are kept, because "4 of 5 iterations disagreed under
            # the old fingerprint" is a real observation about that fingerprint,
            # but they are marked provisional and carry no violation_frequency,
            # so nothing downstream can mistake them for the verdict. The
            # verdict of record is the scalar I4 field, from recovery_variance.
            | (if has("I4")
               then .I4 |= (. + { provisional: true,
                                  violation_frequency: null,
                                  note: "Per-run I4 predates the D34 fingerprint fix and is provisional. The verdict of record is the scalar I4 field, computed across the batch from recovery_variance." })
               else . end) ) as $freq

        | ([ $recovery[] | select(.scenario == $sc) ] | first) as $rv
        | ($meta.invariants // []) as $inv
        | ({
            scenario: $sc,
            layout: $layout,
            n: $n,
            n_planned: $planned,
            # A repeated batch is only FAULT_INEFFECTIVE when EVERY repetition
            # measured an undisturbed cluster; one effective repetition means
            # the batch has something to say.
            run_validity:
              (if ([ $reports[] | .run_validity // "UNKNOWN" ] | length) > 0
                  and ([ $reports[] | .run_validity // "UNKNOWN" ] | all(. == "FAULT_INEFFECTIVE"))
               then "FAULT_INEFFECTIVE"
               else ($meta.run_validity // "UNKNOWN") end),
            fault_class: ($meta.fault_class // null),
            fault_class_source: ($meta.fault_class_source // null),
            # Why each NOT_APPLICABLE cell is not applicable, keyed by
            # invariant, so the heatmap can say "this fault cannot break this
            # invariant" instead of leaving a blank the reader fills in with
            # "preserved".
            not_applicable:
              ($inv | map(select(.verdict == "NOT_APPLICABLE")
                          | {(.invariant): (.not_applicable.reason // "not applicable to this fault class")})
                    | add // {}),
            fault_efficacy: (if $meta.fault_efficacy
                             then {verdict: $meta.fault_efficacy.verdict,
                                   fired: ($meta.fault_efficacy.fired // []),
                                   missing_required: ($meta.fault_efficacy.missing_required // [])}
                             else null end),
            frequency: $freq
          } + $scalar)
        # I4 is cross-run by construction, and each iteration wrote its report
        # before the batch finished, so run_3 only ever saw runs 1-3. For a
        # repeated batch the cell is recomputed here, at the batch root, where
        # the batch is complete.
        # `[…] | index(.I4)` would evaluate .I4 against the LITERAL ARRAY, not
        # against the row — the same trap check-invariants.sh documents for
        # `has`. Bind the current cell first.
        | .I4 as $cur
        | if $layout == "repeated" and $rv != null
             and (["PRESERVED","VIOLATED","INSUFFICIENT_DATA","NO_DATA"] | index($cur) != null)
          then . + {I4: $rv.i4_verdict, I4_source: "batch_recompute",
                    I4_note: "recomputed across the whole batch; the per-iteration I4 in each run_<K>/invariant_report.json is provisional. Evidence: recovery_variance entry for this scenario."}
          else . + {I4_source: "per_run"} end
      ' $reports 2>/dev/null || \
      jq -n --arg sc "$sc" \
        '{scenario: $sc, run_validity: "PARSE_ERROR", fault_class: null, fault_efficacy: null, not_applicable: {}, layout: "unknown", n: 0, n_planned: 0, frequency: {}, I1: "PARSE_ERROR", I2: "PARSE_ERROR", I3: "PARSE_ERROR", I4: "PARSE_ERROR", I5: "PARSE_ERROR", I6: "PARSE_ERROR", I9: "PARSE_ERROR", I10: "PARSE_ERROR"}')
    fi

    out=$(printf '%s' "$out" | jq --argjson row "$row" '. + [$row]')
  done
  printf '%s' "$out"
}

# ── Divergence vs service failure timing ─────────────────────────────────────
#
# Every numeric leaf of .divergence_timing becomes a distribution across the
# repetitions of one batch: {n, min, q1, median, q3, iqr, max, values}.
#
# PERCENTILE CONVENTION: linear interpolation between order statistics — R
# type 7, which is also numpy's default (np.percentile / np.quantile with
# method="linear"). h = (n-1)*p, result = x[floor(h)] + (h-floor(h)) *
# (x[floor(h)+1] - x[floor(h)]). Stated because at the N=5 REVIEW.md asks for
# the convention visibly moves Q1 and Q3: for 1,2,3,4,5 type 7 gives Q1=2,
# Q3=4, while the "nearest rank" and Tukey hinge conventions do not agree with
# that or with each other. All arithmetic is jq's, not bash's — bash 3.2 has no
# floating point at all.
collect_timing() {
  local out='[]' sc rid layout n planned reports entry
  for sc in "${SCENARIOS[@]}"; do
    rid=$(latest_batch "$sc")
    [ -n "$rid" ] || continue
    reports=$(batch_reports "$sc" "$rid")
    [ -n "$reports" ] || continue
    layout=$(batch_layout "$sc" "$rid")
    n=$(batch_n "$sc" "$rid")
    planned=$(batch_planned "$sc" "$rid")

    entry=$(jq -s --arg sc "$sc" --arg layout "$layout" --argjson planned "$planned" '
      def pct($v; $p):
        ($v | length) as $len
        | if $len == 0 then null
          elif $len == 1 then $v[0]
          else (($len - 1) * $p) as $h
               | ($h | floor) as $lo
               | ($h - $lo) as $frac
               | ($v[$lo] + $frac * ($v[([$lo + 1, $len - 1] | min)] - $v[$lo]))
          end;

      . as $reports
      | [ $reports[] | .divergence_timing // {} ] as $ts
      # Paths are kept as arrays, not dotted strings: a numeric leaf inside an
      # array needs its integer index to be fetched back with getpath.
      | ([ $ts[] | paths(type == "number") ] | unique) as $paths
      | { scenario: $sc,
          layout: $layout,
          n: ($reports | length),
          n_planned: $planned,
          # The representative single-run view, unchanged in shape from what
          # this key has always held: the last iteration of the batch.
          timing: ($ts | last),
          statistics:
            ( [ $paths[] | . as $p
                | ([ $ts[] | (try getpath($p) catch null) | numbers ] | sort) as $v
                | { key: ($p | map(tostring) | join(".")),
                    value: (if ($v | length) == 0 then null
                            else { n: ($v | length),
                                   min: $v[0],
                                   q1: pct($v; 0.25),
                                   median: pct($v; 0.5),
                                   q3: pct($v; 0.75),
                                   iqr: (pct($v; 0.75) - pct($v; 0.25)),
                                   max: $v[-1],
                                   # sorted, so the quartiles above can be
                                   # checked by hand against them
                                   values: $v }
                            end) } ]
              | from_entries ),
          percentile_convention: "linear interpolation between order statistics (R type 7 / numpy default)" }
    ' $reports 2>/dev/null || jq -n --arg sc "$sc" '{scenario: $sc, timing: null, statistics: {}}')

    out=$(printf '%s' "$out" | jq --argjson t "$entry" '. + [$t]')
  done
  printf '%s' "$out"
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

# Recovery variance is computed FIRST: collect_verdicts needs it to recompute
# the I4 cell of every repeated batch at the batch root, where the batch is
# complete. (Each iteration's own invariant_report.json was written before the
# batch finished, so run_3's I4 could only ever see runs 1-3; those per-run
# verdicts carry provisional: true.)
RECOVERY=$(collect_recovery_variance_all)
VERDICTS=$(collect_verdicts)
TIMING=$(collect_timing)
# recovery_variance_s6 stays as an ALIAS onto the s6 entry of the array:
# scripts/report-template.html and check-invariants.sh's I4 note both name that
# key. When S6 has no batch with N > 1 it keeps its historical
# {"scenario":"s6","variance":"NO_DATA"} shape.
VARIANCE=$(printf '%s' "$RECOVERY" | jq -c '([.[] | select(.scenario == "s6")] | first) // null')
if [ "$VARIANCE" = "null" ]; then
  VARIANCE=$(collect_recovery_variance s6)
fi
AMPLIFICATION=$(collect_amplification)
TERMINATION=$(collect_termination_timing)

# Repetition census (REVIEW.md M3): which scenarios were actually repeated, how
# deep, and which batch the numbers above were computed from.
BATCHES='[]'
for sc in "${SCENARIOS[@]}"; do
  rid=$(latest_batch "$sc")
  [ -n "$rid" ] || continue
  BATCHES=$(printf '%s' "$BATCHES" \
    | jq --arg sc "$sc" --arg rid "$rid" \
         --arg layout "$(batch_layout "$sc" "$rid")" \
         --argjson n "$(batch_n "$sc" "$rid")" \
         --argjson planned "$(batch_planned "$sc" "$rid")" \
         '. + [{scenario: $sc, run_id: $rid, layout: $layout, n: $n, n_planned: $planned}]')
done
REPETITION=$(printf '%s' "$BATCHES" | jq -c '{
    scenarios_with_n_gt_1: ([.[] | select(.n > 1)] | length),
    max_n: ([.[].n] | max // 0),
    batches: .
  }')

# Overall statistics.
#
# REVIEW.md M4: "The current summary.violation_rate_pct: 45 mixes real
# findings, artifacts and inapplicable checks into one number." The fix is a
# single, stated denominator, and everything it excludes counted and published
# beside it rather than quietly dropped:
#
#   DENOMINATOR = cells whose verdict is PRESERVED or VIOLATED, taken from runs
#                 whose fault demonstrably did something.
#
#   excluded, and why
#     FAULT_INEFFECTIVE   the run measured an undisturbed cluster, so every one
#                         of its verdicts describes nothing. Excluded whole-run.
#     NOT_RUN             the scenario produced no report at all.
#     DETECTOR_INVALID    the invariant was already violated at baseline; that
#                         is a disqualified detector, not a finding.
#     NOT_APPLICABLE      this fault cannot produce the state the invariant
#                         forbids, so the cell is a question never asked.
#                         Counting it as PRESERVED is what inflated the
#                         preserved column and deflated the rate.
#     INSUFFICIENT_DATA   the run carries no evidence either way.
#
# Each exclusion is reported as its own count, so the rate can be recomputed by
# hand from the published numbers.
VALID_VERDICTS=$(echo "$VERDICTS" | jq '[.[] | select((.run_validity // "UNKNOWN") != "FAULT_INEFFECTIVE" and (.run_validity // "UNKNOWN") != "NOT_RUN")]')
CELLS='[.[].I1, .[].I2, .[].I3, .[].I4, .[].I5, .[].I6, .[].I9, .[].I10]'

TOTAL_PRESERVED=$(echo "$VALID_VERDICTS" | jq "$CELLS"' | map(select(. == "PRESERVED")) | length')
TOTAL_VIOLATED=$(echo "$VALID_VERDICTS"  | jq "$CELLS"' | map(select(. == "VIOLATED")) | length')
TOTAL_INSUFFICIENT=$(echo "$VALID_VERDICTS" | jq "$CELLS"' | map(select(. == "INSUFFICIENT_DATA")) | length')
# The three exclusions are counted over EVERY row, not just the valid ones, so
# the published numbers add up to the full grid.
TOTAL_INVALID=$(echo "$VERDICTS" | jq "$CELLS"' | map(select(. == "DETECTOR_INVALID")) | length')
TOTAL_NA=$(echo "$VERDICTS"      | jq "$CELLS"' | map(select(. == "NOT_APPLICABLE")) | length')
CELLS_TOTAL=$(echo "$VERDICTS"   | jq "$CELLS"' | length')
CELLS_INEFFECTIVE_RUNS=$(echo "$VERDICTS" | jq '[.[] | select(.run_validity == "FAULT_INEFFECTIVE")] | length * 8')
RUNS_INEFFECTIVE=$(echo "$VERDICTS" | jq '[.[] | select(.run_validity == "FAULT_INEFFECTIVE")] | length')
RUNS_NOT_RUN=$(echo "$VERDICTS" | jq '[.[] | select(.run_validity == "NOT_RUN")] | length')
# Which invariant x fault-class cells were ruled out, so a reader can audit the
# applicability table from the aggregate alone.
NA_BREAKDOWN=$(echo "$VERDICTS" | jq -c '
  [ .[] | . as $r | (.not_applicable // {}) | to_entries[]
    | {scenario: $r.scenario, fault_class: $r.fault_class, invariant: .key, reason: .value} ]')

jq -n \
  --argjson verdicts "$VERDICTS" \
  --argjson timing "$TIMING" \
  --argjson variance "$VARIANCE" \
  --argjson recovery "$RECOVERY" \
  --argjson repetition "$REPETITION" \
  --argjson amplification "$AMPLIFICATION" \
  --argjson termination "$TERMINATION" \
  --argjson preserved "$TOTAL_PRESERVED" \
  --argjson violated "$TOTAL_VIOLATED" \
  --argjson insufficient "$TOTAL_INSUFFICIENT" \
  --argjson invalid "$TOTAL_INVALID" \
  --argjson notapplicable "$TOTAL_NA" \
  --argjson na_breakdown "$NA_BREAKDOWN" \
  --argjson cells_total "$CELLS_TOTAL" \
  --argjson cells_ineffective "$CELLS_INEFFECTIVE_RUNS" \
  --argjson ineffective "$RUNS_INEFFECTIVE" \
  --argjson notrun "$RUNS_NOT_RUN" \
  '{
    generated_at: now | todate,
    summary: {
      total_invariant_checks: ($preserved + $violated),
      total_preserved: $preserved,
      total_violated: $violated,
      detectors_invalidated: $invalid,
      not_applicable: $notapplicable,
      insufficient_data: $insufficient,
      runs_fault_ineffective: $ineffective,
      scenarios_not_run: $notrun,
      violation_rate_pct: (if ($preserved + $violated) > 0
        then ($violated * 100 / ($preserved + $violated) | round)
        else 0 end),
      # The denominator, spelled out. cells_total is the full grid
      # (scenarios x invariants); every exclusion below is subtracted from it
      # and what remains is what the rate is computed over, so the number can
      # be re-derived by hand and cannot quietly change meaning again.
      denominator: {
        definition: "invariant cells whose verdict is PRESERVED or VIOLATED, from runs whose fault produced an observable change",
        cells_total: $cells_total,
        counted: ($preserved + $violated),
        excluded: {
          insufficient_data: $insufficient,
          detector_invalid: $invalid,
          not_applicable: $notapplicable,
          cells_in_fault_ineffective_runs: $cells_ineffective,
          cells_in_scenarios_not_run: ($notrun * 8)
        },
        excludes_note: "INSUFFICIENT_DATA measured nothing. DETECTOR_INVALID measured the detector (the invariant was already violated at baseline). NOT_APPLICABLE is an invariant this fault class cannot break, previously reported PRESERVED, which inflated the preserved column. FAULT_INEFFECTIVE runs measured an undisturbed cluster and are excluded whole."
      },
      not_applicable_breakdown: $na_breakdown,
      # REVIEW.md M3: how much repetition the numbers above actually rest on.
      # scenarios_with_n_gt_1 = 0 means every rate here is a sample of one.
      repetition: $repetition,
      counting_note: "One rate, one population. Rates cover runs whose fault produced an observable change, over cells that were actually evaluable. DETECTOR_INVALID, NOT_APPLICABLE, INSUFFICIENT_DATA and FAULT_INEFFECTIVE runs are each counted separately above and none of them enters the denominator."
    },
    invariant_heatmap: $verdicts,
    divergence_timing: $timing,
    # One entry per scenario whose newest batch has N > 1.
    # recovery_variance_s6 is the alias onto the s6 entry, kept because
    # report-template.html and the I4 note in check-invariants.sh both refer
    # to that key by name.
    recovery_variance: $recovery,
    recovery_variance_s6: $variance,
    amplification_metrics: $amplification,
    termination_race_s15: $termination
  }'
