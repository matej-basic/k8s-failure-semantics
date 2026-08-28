#!/bin/bash
# scripts/violation-duration.sh
#
# REVIEW.md M4: "attach duration_s plus first_violation_ts to every VIOLATED
# verdict". This script answers the duration half.
#
#     violation-duration.sh <results_dir> <invariant_id>
#
# It prints one JSON object on stdout and never exits non-zero: a duration that
# cannot be measured is a JSON object saying so, not a failure and — the whole
# point — never a 0.
#
# ── The rule this file exists to enforce ──────────────────────────────────────
# A snapshot series cannot measure a duration. Snapshots are 15-60 s apart and
# a violation that opens and closes between two of them leaves no trace in
# them at all, so "first violating snapshot to last violating snapshot" is a
# bracket on the OBSERVATIONS, not a length of the violation. Durations
# therefore come from the M1 1 Hz trace, and where the trace is missing —
# every archived run in results/ predates M1 — duration_s is
#
#     null, with a reason
#
# never 0. A 0 would be a false measurement: it asserts the violation had no
# extent, when what actually happened is that nothing was recorded at the
# resolution a duration needs.
#
# ── Where each invariant's duration comes from ────────────────────────────────
# Declared in DURATION_SOURCES below, one row per invariant, so the mapping is
# a table and not a pile of conditionals:
#
#   I5  m2:node_ready
#       Reuses scripts/observer-disagreement-duration.sh verbatim. Its
#       `node_ready` question — "do two API servers give the same answer about
#       this node's Ready status at this instant" — IS check_i5's
#       node_disagreement clause, same objects, same observers, so its episode
#       lengths are I5's episode lengths. The revision-lag clause of I5 has no
#       counterpart in the trace, so coverage is reported as partial.
#
#   I2  trace:endpoints_not_ready       (trace.jsonl,      1 Hz)
#   I6  trace:etcd_revision_regressed   (trace_etcd.jsonl, 5 s)
#   I9  trace:etcd_quorum_or_split      (trace_etcd.jsonl, 5 s)
#       Computed here, because M2 does not ask these questions. Each predicate
#       is a strict subset of the corresponding check_i*() predicate, evaluated
#       on the fields the recorder already writes; the subset is named in
#       `covers` / `not_covered` so the number is never read as more than it is.
#
#   I1, I3, I4, I10  none
#       Not derivable. I1 and I3 need node-local crictl container state, I10
#       needs the Warning-event list, and none of the three is in the trace;
#       I4 is a cross-run invariant with no instant to measure from. These
#       report duration_s null with reason "no_trace_predicate" rather than a
#       number computed from something else that happened to be available.
#
# ── Censoring: identical to M2, deliberately ──────────────────────────────────
# A trace that stops early looks exactly like a violation that never ended, and
# M2 already settled how to tell them apart. The engine below is the same fold
# with the same rules, so the two files cannot disagree:
#
#   * the last line of a complete trace is a footer whose .stream ends "-end";
#     no footer means the recorder was SIGKILLed and the trace is TRUNCATED;
#   * an episode still open when a TRUNCATED trace ends is `censored`, is
#     EXCLUDED from the maximum, and its length is reported as censored_ms;
#   * an episode still open when a COMPLETE trace ends is counted, closed:false,
#     and flagged is_lower_bound — observation ended, the violation had not;
#   * a record that could not be evaluated (the sub-query that feeds the
#     predicate is null because the READ FAILED, per .errors[]) is
#     `insufficient`: it neither extends an episode nor closes one. Could-not-
#     read is never agreement, and never a violation either;
#   * a blind window — skipped .seq ticks or a run of insufficient records —
#     longer than GAP_BREAK_MS BREAKS the episode at the last record actually
#     observed to be violating, rather than asserting continuous violation
#     across missing data.
#
# Time axis is t_rel_ms, monotonic ms since the recorder started, for the same
# reason M2 uses it: S4, S23 and S27 move wall clocks on purpose.
#
# Runs on the macOS control machine: bash 3.2, BSD sed, no mapfile, no
# associative arrays.

set -u

RESULTS_DIR="${1:-}"
INVARIANT="${2:-}"

GAP_BREAK_MS="${GAP_BREAK_MS:-5000}"

if [ -z "$RESULTS_DIR" ] || [ -z "$INVARIANT" ]; then
  echo '{"duration_s": null, "source": "none", "reason": "usage: violation-duration.sh <results_dir> <invariant_id>"}'
  exit 0
fi

command -v jq >/dev/null 2>&1 || {
  echo '{"duration_s": null, "source": "none", "reason": "jq_not_found"}'
  exit 0
}

SELF_DIR=$(cd "$(dirname "$0")" && pwd)

# ── The declaration ───────────────────────────────────────────────────────────
# invariant | mode | argument | covers | not_covered
#
#   mode m2     — argument is the question key in disagreement_duration.json
#   mode trace  — argument is <trace file>:<predicate name>
#   mode none   — argument is the reason
DURATION_SOURCES='
I1|none|no_trace_predicate: dual ownership is decided from node-local crictl container lists, which the 1 Hz trace does not record||
I2|trace|trace.jsonl:endpoints_not_ready|published endpoints carrying notReadyAddresses, summed over the same two workload services check_i2 reads|in-cluster service probe (not in the trace)
I3|none|no_trace_predicate: the check pairs a withdrawn Ready/taint with node-local crictl containers, and containers are not in the trace||
I4|none|not_measurable: I4 is a cross-run invariant with no instant of violation inside one run||
I5|m2|node_ready|two API servers disagreeing about a node Ready status|watch-cache revision lag (no counterpart in the trace)
I6|trace|trace_etcd.jsonl:etcd_revision_regressed|observed etcd revision below the highest already observed|
I9|trace|trace_etcd.jsonl:etcd_quorum_or_split|members below quorum, or divergent leader/raft term among responders|
I10|none|no_trace_predicate: reconciliation termination is a set difference over Warning events, which the trace does not record||
'

row=$(printf '%s\n' "$DURATION_SOURCES" | awk -F'|' -v inv="$INVARIANT" '$1 == inv { print; exit }')

if [ -z "$row" ]; then
  jq -n --arg inv "$INVARIANT" \
    '{duration_s: null, source: "none",
      reason: ("unknown_invariant: no duration source declared for " + $inv)}'
  exit 0
fi

MODE=$(printf '%s' "$row" | awk -F'|' '{ print $2 }')
ARG=$(printf '%s' "$row" | awk -F'|' '{ print $3 }')
COVERS=$(printf '%s' "$row" | awk -F'|' '{ print $4 }')
NOT_COVERED=$(printf '%s' "$row" | awk -F'|' '{ print $5 }')

emit_null() {  # $1 = source, $2 = reason
  jq -n --arg src "$1" --arg reason "$2" --arg cov "$COVERS" --arg nc "$NOT_COVERED" \
    '{duration_s: null,
      duration_ms: null,
      source: $src,
      reason: $reason,
      time_axis: "t_rel_ms",
      is_lower_bound: false,
      censored: false,
      covers:      (if $cov == "" then null else $cov end),
      not_covered: (if $nc  == "" then null else $nc  end),
      note: "duration_s is null, not 0: nothing was recorded at the resolution a duration needs. A 0 here would assert the violation had no extent."}'
}

if [ "$MODE" = "none" ]; then
  emit_null "none" "$ARG"
  exit 0
fi

# ── Mode m2: reuse observer-disagreement-duration.sh ───────────────────────────
if [ "$MODE" = "m2" ]; then
  DD="$RESULTS_DIR/disagreement_duration.json"
  SRC_LABEL="observer-disagreement-duration/v1:$ARG"

  if [ ! -f "$DD" ]; then
    # The scenario did not run M2's analysis, but the trace it reads may still
    # be here — run it rather than re-deriving the same thing differently.
    if [ -f "$RESULTS_DIR/trace.jsonl" ] && [ -x "$SELF_DIR/observer-disagreement-duration.sh" ]; then
      DD=$(mktemp "${TMPDIR:-/tmp}/vd.XXXXXX") || { emit_null "$SRC_LABEL" "mktemp_failed"; exit 0; }
      bash "$SELF_DIR/observer-disagreement-duration.sh" "$RESULTS_DIR" > "$DD" 2>/dev/null \
        || { rm -f "$DD"; emit_null "$SRC_LABEL" "observer_disagreement_duration_failed"; exit 0; }
      SRC_LABEL="$SRC_LABEL (computed on demand from trace.jsonl)"
    else
      emit_null "$SRC_LABEL" "trace_absent: neither disagreement_duration.json nor trace.jsonl is present in this results dir, so no duration was ever recorded"
      exit 0
    fi
    CLEANUP="$DD"
  else
    CLEANUP=""
  fi

  OUT=$(jq -c --arg q "$ARG" --arg src "$SRC_LABEL" --arg cov "$COVERS" --arg nc "$NOT_COVERED" '
    (if type == "array" then .[0] else . end) as $d
    | ($d.questions // [] | map(select(.question == $q)) | first) as $b
    | if ($d.trace.present // false) | not then
        { duration_s: null, duration_ms: null, source: $src,
          reason: ("trace_absent: " + ($d.trace.reason // "no trace")),
          is_lower_bound: false, censored: false }
      elif $b == null then
        { duration_s: null, duration_ms: null, source: $src,
          reason: "question_not_in_report", is_lower_bound: false, censored: false }
      elif $b.verdict == "INSUFFICIENT_DATA" then
        { duration_s: null, duration_ms: null, source: $src,
          reason: "insufficient: no record in the trace could be evaluated for this question",
          is_lower_bound: false, censored: false }
      elif $b.verdict == "CENSORED_ONLY" then
        { duration_s: null, duration_ms: null, source: $src,
          reason: "censored_only: the only episode found was still open when a TRUNCATED trace ran out — the violation did not end, the data did",
          is_lower_bound: false, censored: true,
          censored_ms: $b.censored_ms }
      elif $b.verdict == "NO_DISAGREEMENT" then
        { duration_s: null, duration_ms: null, source: $src,
          reason: "no_episode_in_trace: the snapshot series recorded a violation the 1 Hz trace never saw (the two sample different instants)",
          is_lower_bound: false, censored: false }
      else
        { duration_s: (($b.max_disagreement_ms // 0) / 1000 * 1000 | round / 1000),
          duration_ms: $b.max_disagreement_ms,
          source: $src,
          reason: "max episode length on the t_rel_ms axis",
          is_lower_bound: ($b.max_disagreement_is_lower_bound // false),
          censored: false,
          censored_ms: $b.censored_ms,
          episode_count: $b.episode_count,
          total_ms: $b.total_disagreement_ms,
          window: $b.max_disagreement_window }
      end
    | . + { time_axis: "t_rel_ms",
            covers:      (if $cov == "" then null else $cov end),
            not_covered: (if $nc  == "" then null else $nc  end) }
  ' "$DD" 2>/dev/null)

  [ -n "${CLEANUP:-}" ] && rm -f "$CLEANUP"
  if [ -z "$OUT" ]; then
    emit_null "$SRC_LABEL" "disagreement_duration_unparseable"
  else
    printf '%s\n' "$OUT"
  fi
  exit 0
fi

# ── Mode trace: compute the episodes here, with M2's censoring rules ───────────
TRACE_FILE="$RESULTS_DIR/$(printf '%s' "$ARG" | awk -F: '{ print $1 }')"
PREDICATE=$(printf '%s' "$ARG" | awk -F: '{ print $2 }')
SRC_LABEL="trace:$PREDICATE"

if [ ! -f "$TRACE_FILE" ]; then
  emit_null "$SRC_LABEL" "trace_absent: $(basename "$TRACE_FILE") is not present in this results dir, so no duration was ever recorded"
  exit 0
fi
if [ ! -s "$TRACE_FILE" ]; then
  emit_null "$SRC_LABEL" "trace_empty: $(basename "$TRACE_FILE") is present but empty"
  exit 0
fi

TMP=$(mktemp "${TMPDIR:-/tmp}/vd.XXXXXX") || { emit_null "$SRC_LABEL" "mktemp_failed"; exit 0; }

# A SIGKILLed recorder can leave a half-written final line. jq emits every good
# record before the first unparseable one, so this both sanitises and detects.
LINES=$(awk 'END { print NR }' "$TRACE_FILE")
jq -c . "$TRACE_FILE" > "$TMP" 2>/dev/null
KEPT=$(awk 'END { print NR }' "$TMP")
if [ "${KEPT:-0}" -eq 0 ]; then
  rm -f "$TMP"
  emit_null "$SRC_LABEL" "no_parseable_records in $(basename "$TRACE_FILE")"
  exit 0
fi
if [ "${KEPT:-0}" -lt "${LINES:-0}" ]; then MALFORMED=true; else MALFORMED=false; fi

JQ_EPISODES=$(cat <<'JQEOF'
# ── classify one record ───────────────────────────────────────────────────────
# "violate" / "ok" / "insufficient". A field that is null because .errors[]
# names its sub-query is a FAILED READ, and a failed read is insufficient — it
# is never counted as a violation and never as a clear.
def classify($r; $pred):
  if $pred == "endpoints_not_ready" then
    ( if (($r.errors // []) | index("endpoints")) != null or ($r.endpoints | type) != "object"
      then {st: "insufficient", why: "endpoints_read_failed"}
      elif (($r.endpoints.not_ready_count // 0) > 0)
      then {st: "violate", why: null, detail: {not_ready_count: $r.endpoints.not_ready_count}}
      else {st: "ok", why: null} end )
  elif $pred == "etcd_quorum_or_split" then
    ( if (($r.errors // []) | index("etcd")) != null or ($r.members | type) != "array"
      then {st: "insufficient", why: "etcd_read_failed"}
      else
        ( ($r.expected_members // 0) ) as $exp
        | ( if $exp >= 3 then (($exp / 2 | floor) + 1) else null end ) as $quorum
        | ( [ $r.members[].leader_id ] | map(select(. != null)) | unique ) as $leaders
        | ( [ $r.members[].raft_term ] | map(select(. != null)) | unique ) as $terms
        | if $quorum == null then {st: "insufficient", why: "expected_members_below_3"}
          elif (($r.healthy_members // 0) < $quorum)
            then {st: "violate", why: null,
                  detail: {reason: "below_quorum", healthy: $r.healthy_members, quorum: $quorum}}
          elif (($leaders | length) > 1) or (($terms | length) > 1)
            then {st: "violate", why: null,
                  detail: {reason: "leader_or_term_divergence", leaders: $leaders, terms: $terms}}
          else {st: "ok", why: null} end
      end )
  elif $pred == "etcd_revision_regressed" then
    ( if (($r.errors // []) | index("etcd")) != null or ($r.etcd_revision | type) != "number"
      then {st: "insufficient", why: "etcd_revision_unreadable"}
      elif ($r.etcd_revision < ($r._running_max // $r.etcd_revision))
      then {st: "violate", why: null,
            detail: {revision: $r.etcd_revision, highest_seen: $r._running_max}}
      else {st: "ok", why: null} end )
  else {st: "insufficient", why: "unknown_predicate"} end;

( [ .[] | select((.stream // "") | endswith("-end")) ] | last ) as $footer
| ( [ .[] | select(((.stream // "") | endswith("-end")) | not) ] ) as $recs
| ( $recs | map(select((.t_rel_ms | type) == "number")) | sort_by(.t_rel_ms) ) as $sorted
| ( if $footer != null and ($footer.interval_s | type) == "number"
    then ($footer.interval_s * 1000) else 1000 end ) as $interval_ms
| ( $footer == null ) as $truncated

# Running maximum of the observed etcd revision, attached before classification
# so the regression predicate stays a pure per-record function.
| ( reduce $sorted[] as $r ({max: null, out: []};
      ( if ($r.etcd_revision | type) == "number"
        then (if .max == null or $r.etcd_revision > .max then .max = $r.etcd_revision else . end)
        else . end )
      | .out += [ $r + {_running_max: .max} ] ) | .out ) as $data

| ( [ $data[] | . as $r | classify($r; $PRED)
      + {t: $r.t_rel_ms, seq: ($r.seq // null), ts: ($r.ts // null)} ] ) as $series

| ( reduce $series[] as $x ({cur: null, eps: []};
      ( if .cur != null and (($x.t - .cur.last_t) > $GAP)
        then { cur: null,
               eps: (.eps + [ .cur + {end_t: .cur.last_t, end_seq: .cur.last_seq,
                                      end_reason: "unobserved_gap",
                                      closed: true, censored: false} ]) }
        else . end )
      | if $x.st == "violate" then
          ( if .cur == null then
              .cur = {start_t: $x.t, start_seq: $x.seq, start_ts: $x.ts,
                      detail_at_start: ($x.detail // null),
                      last_t: $x.t, last_seq: $x.seq,
                      observed_points: 1, unobserved_ms: 0}
            else
              .cur.unobserved_ms += ([($x.t - .cur.last_t - $interval_ms), 0] | max)
              | .cur.last_t = $x.t | .cur.last_seq = $x.seq
              | .cur.observed_points += 1
            end )
        elif $x.st == "ok" then
          ( if .cur == null then .
            else { cur: null,
                   eps: (.eps + [ .cur + {end_t: $x.t, end_seq: $x.seq,
                                          end_reason: "clear_observed",
                                          closed: true, censored: false} ]) }
            end )
        else . end )                     # insufficient: neither extends nor closes
    | if .cur == null then .eps
      else .eps + [ .cur + {end_t: .cur.last_t, end_seq: .cur.last_seq,
                            end_reason: (if $truncated then "trace_truncated"
                                         else "observation_ended" end),
                            closed: false, censored: $truncated} ]
      end
  | map(. + {span_ms: (.end_t - .start_t)} | . + {observed_ms: (.span_ms - .unobserved_ms)}) ) as $eps

| ( [ $eps[] | select(.censored | not) ] ) as $counted
| ( [ $eps[] | select(.censored) ] )       as $censored
| ( [ $counted[].span_ms ] | max )         as $maxms
| ( [ $series[] | select(.st != "insufficient") ] | length ) as $evaluable

| { source: ("trace:" + $PRED),
    time_axis: "t_rel_ms",
    trace: { file: $SOURCE, records: ($data | length), interval_ms: $interval_ms,
             footer_present: ($footer != null), truncated: $truncated,
             malformed_tail: $MALFORMED,
             records_violate:      ([ $series[] | select(.st == "violate") ] | length),
             records_ok:           ([ $series[] | select(.st == "ok") ] | length),
             records_insufficient: ([ $series[] | select(.st == "insufficient") ] | length),
             insufficient_reasons:
               ([ $series[] | select(.st == "insufficient") | .why ]
                | group_by(.) | map({(.[0]): length}) | add // {}) },
    episode_count: ($eps | length),
    episodes: $eps,
    censored_ms: ([ $censored[].span_ms ] | max) }
  + ( if $evaluable == 0 then
        { duration_s: null, duration_ms: null, is_lower_bound: false, censored: false,
          reason: "insufficient: no record in this trace could be evaluated for this predicate" }
      elif ($eps | length) == 0 then
        { duration_s: null, duration_ms: null, is_lower_bound: false, censored: false,
          reason: "no_episode_in_trace: the snapshot series recorded a violation the trace never saw (the two sample different instants)" }
      elif ($counted | length) == 0 then
        { duration_s: null, duration_ms: null, is_lower_bound: false, censored: true,
          reason: "censored_only: the only episode found was still open when a TRUNCATED trace ran out — the violation did not end, the data did" }
      else
        { duration_s: ($maxms / 1000 * 1000 | round / 1000),
          duration_ms: $maxms,
          is_lower_bound: ((([ $counted[] | select(.closed | not) | .span_ms ] | max) != null)
                           and (([ $counted[] | select(.closed | not) | .span_ms ] | max) == $maxms)),
          censored: false,
          total_ms: ([ $counted[].span_ms ] | add // 0),
          reason: "max episode length on the t_rel_ms axis" }
      end )
  + { covers:      (if $COV == "" then null else $COV end),
      not_covered: (if $NCOV == "" then null else $NCOV end) }
JQEOF
)

OUT=$(jq -s \
  --arg PRED "$PREDICATE" \
  --arg SOURCE "$(basename "$TRACE_FILE")" \
  --arg COV "$COVERS" \
  --arg NCOV "$NOT_COVERED" \
  --argjson GAP "$GAP_BREAK_MS" \
  --argjson MALFORMED "$MALFORMED" \
  -c "$JQ_EPISODES" "$TMP" 2>/dev/null)

rm -f "$TMP"

if [ -z "$OUT" ]; then
  emit_null "$SRC_LABEL" "trace_analysis_failed"
else
  printf '%s\n' "$OUT"
fi
exit 0
