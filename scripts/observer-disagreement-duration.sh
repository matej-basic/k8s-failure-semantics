#!/bin/bash
# scripts/observer-disagreement-duration.sh
#
# REVIEW.md M2, second output: the MAXIMUM DISAGREEMENT DURATION per question
# per scenario, computed from the M1 1 Hz trace.
#
#   observer-disagreement-duration.sh [options] <results_dir> [<results_dir> ...]
#
#     --output FILE   also write the JSON to FILE (stdout always gets it)
#     --trace  FILE   read this trace instead of <results_dir>/trace.jsonl
#     -h, --help
#
#   Environment:
#     GAP_BREAK_MS    (default 5000) a blind window longer than this BREAKS a
#                     disagreement episode instead of spanning it.
#     MIN_OBSERVERS   (default 2) observers that must have ANSWERED a question
#                     in a record before that record is evaluated at all.
#
# Runs on the macOS control machine: bash 3.2, BSD sed, no mapfile, no
# associative arrays, no `\s` in sed. All of the analysis is one jq program.
#
# ── What is being measured ────────────────────────────────────────────────────
# Each k8s trace record carries an .observers[] array — one entry per API
# server, each with its answer to the three M2 questions, added by
# roles/metrics-collect/templates/trace-recorder.sh.j2. For each question and
# each record the observers that ANSWERED are compared:
#
#   >= MIN_OBSERVERS answered, all the same        -> agree
#   >= MIN_OBSERVERS answered, two or more values  -> disagree
#   fewer than MIN_OBSERVERS answered              -> INSUFFICIENT
#
# The third case is the whole point of the exercise. An observer that timed
# out, was refused, or returned a body that would not parse is `unreadable`;
# it contributes NOTHING to the comparison. "Could not read" is never
# "agreed", and a record where nobody could read is not a record of consensus —
# it is a record of nothing, and it is counted separately as insufficient.
#
# The same rule covers the trace's own .errors[]: a sub-query named there
# nulled ITS OWN M1 field, and no answer here is derived from those fields at
# all — every answer comes from .observers[].answers, whose per-observer state
# already distinguishes a failed read from a value. Records that carry no
# .observers block are insufficient for every question, and the sub-query
# errors they name are reported alongside so the reason is visible.
#
# ── Time axis ─────────────────────────────────────────────────────────────────
# t_rel_ms — monotonic milliseconds since the recorder started. NOT ts /
# ts_epoch_ms: S4, S23 and S27 move a node's wall clock on purpose, and a
# duration measured on a clock that jumps is not a duration.
#
# ── Episodes, gaps and truncation ─────────────────────────────────────────────
# An episode opens on the first `disagree` record and closes on the first
# `agree` record after it, at that record's t_rel_ms. Between those:
#
#   * `insufficient` records do NOT close an episode — nothing was observed, so
#     nothing contradicts it — but they do not extend the evidence either.
#   * .seq is the tick index, so a jump in .seq is a tick the recorder SKIPPED.
#     Skipped ticks and runs of insufficient records are the same thing here:
#     unobserved time. A blind window longer than GAP_BREAK_MS BREAKS the
#     episode at the last record actually observed to disagree
#     (end_reason "unobserved_gap"), because asserting continuous disagreement
#     across seconds of missing data is not a measurement. Shorter windows are
#     spanned, and the time they cover is reported per episode as
#     unobserved_ms, so span_ms always has observed_ms next to it.
#   * The last line of a complete trace is a footer record whose .stream ends
#     "-end". A trace with NO footer was SIGKILLed and is TRUNCATED. An episode
#     still open at the end of a truncated trace did not end — the DATA ended.
#     It is emitted with end_reason "trace_truncated" and censored:true, its
#     length is reported as censored_ms, and it is EXCLUDED from
#     max_disagreement_ms; max_disagreement_is_lower_bound then says so. An
#     episode open at the end of a COMPLETE trace is different — observation
#     genuinely ended while the observers still disagreed — and it is counted,
#     with end_reason "observation_ended" and is_lower_bound:true.

set -u

usage() {
  sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

OUTPUT=""
TRACE_OVERRIDE=""
DIRS=""

while [ $# -gt 0 ]; do
  case "$1" in
    --output) OUTPUT="${2:-}"; shift 2 ;;
    --trace)  TRACE_OVERRIDE="${2:-}"; shift 2 ;;
    -h|--help) usage 0 ;;
    -*) echo "unknown option: $1" >&2; usage 2 ;;
    *)  DIRS="$DIRS $1"; shift ;;
  esac
done

if [ -z "$DIRS" ]; then
  echo "usage: $0 [--output FILE] [--trace FILE] <results_dir> [...]" >&2
  exit 2
fi

command -v jq >/dev/null 2>&1 || { echo '{"error":"jq_not_found"}'; exit 2; }

GAP_BREAK_MS="${GAP_BREAK_MS:-5000}"
MIN_OBSERVERS="${MIN_OBSERVERS:-2}"

JQ_PROG=$(cat <<'JQEOF'
def QKEYS: ["node_ready", "stateful_pod_node", "stateless_endpoint_set"];

# The M1 field each question would have come from in a single-observer record.
# Used only to REPORT why a record without an .observers block is unusable.
def backing($q):
  if   $q == "node_ready"             then "nodes"
  elif $q == "stateful_pod_node"      then "stateful_pod"
  else "endpoints" end;

( [ .[] | select((.stream // "") | endswith("-end")) ] | last ) as $footer
| ( [ .[] | select(((.stream // "") | endswith("-end")) | not) ] ) as $recs
| ( $recs | map(select((.t_rel_ms | type) == "number")) | sort_by(.t_rel_ms) ) as $data
| ( if $footer != null and ($footer.interval_s | type) == "number"
    then ($footer.interval_s * 1000) else 1000 end ) as $interval_ms
| ( $footer == null ) as $truncated

# Every tick where .seq jumped by more than 1: a tick the recorder could not
# keep up with, reported verbatim so a duration can be read with its blind
# spots in view.
| ( [ range(1; ($data | length))
      | . as $i
      | $data[$i - 1] as $a | $data[$i] as $b
      | select((($a.seq | type) == "number") and (($b.seq | type) == "number"))
      | select(($b.seq - $a.seq) > 1)
      | { after_seq: $a.seq, before_seq: $b.seq,
          missing_ticks: ($b.seq - $a.seq - 1),
          gap_ms: ($b.t_rel_ms - $a.t_rel_ms) } ] ) as $seq_gaps

| ( [ $data[] | (.observers // [])[]? | .observer ] | unique ) as $observer_ids

| def classify($rec; $q):
    ( if ($rec.observers | type) != "array" then null
      else [ $rec.observers[]
             | select((.answers | type) == "object")
             | .answers[$q]
             | select((.state // "") == "answered")
             | (.answer | tostring) ]
      end ) as $ans
    | if $ans == null then
        { st: "insufficient", why: "no_observers_block",
          errors: [ ($rec.errors // [])[] | select(. == backing($q) or . == "observers") ],
          answered: 0, values: [] }
      elif ($ans | length) < $MIN then
        { st: "insufficient", why: "too_few_observers_answered",
          errors: [ ($rec.errors // [])[] | select(. == backing($q) or . == "observers") ],
          answered: ($ans | length), values: ($ans | unique) }
      elif (($ans | unique | length) > 1) then
        { st: "disagree", why: null, errors: [],
          answered: ($ans | length), values: ($ans | unique) }
      else
        { st: "agree", why: null, errors: [],
          answered: ($ans | length), values: ($ans | unique) }
      end;

  def per_record($q):
    [ $data[]
      | . as $r
      | classify($r; $q) as $c
      | { t: $r.t_rel_ms, seq: ($r.seq // null), ts: ($r.ts // null) } + $c ];

  # Fold the classified series into episodes. `cur.last_t` is the last moment
  # disagreement was actually OBSERVED, which is what a gap is measured from
  # and where an episode broken by a gap is closed — never the current record,
  # which is on the far side of the blind window.
  def episodes($series):
    ( reduce $series[] as $x ({ cur: null, eps: [] };
        ( if .cur != null and (($x.t - .cur.last_t) > $GAP)
          then { cur: null,
                 eps: (.eps + [ .cur + { end_t: .cur.last_t, end_seq: .cur.last_seq,
                                         end_reason: "unobserved_gap", closed: true,
                                         censored: false } ]) }
          else . end )
        | if $x.st == "disagree" then
            ( if .cur == null then
                .cur = { start_t: $x.t, start_seq: $x.seq, start_ts: $x.ts,
                         values_at_start: $x.values,
                         last_t: $x.t, last_seq: $x.seq,
                         observed_points: 1, unobserved_ms: 0 }
              else
                .cur.unobserved_ms += ( [ ($x.t - .cur.last_t - $interval_ms), 0 ] | max )
                | .cur.last_t = $x.t
                | .cur.last_seq = $x.seq
                | .cur.observed_points += 1
              end )
          elif $x.st == "agree" then
            ( if .cur == null then .
              else { cur: null,
                     eps: (.eps + [ .cur + { end_t: $x.t, end_seq: $x.seq,
                                             end_reason: "agreement_observed",
                                             closed: true, censored: false } ]) }
              end )
          else .   # insufficient: neither extends nor closes
          end )
      | if .cur == null then .eps
        else .eps + [ .cur + { end_t: .cur.last_t, end_seq: .cur.last_seq,
                               end_reason: (if $truncated then "trace_truncated"
                                            else "observation_ended" end),
                               closed: false,
                               censored: $truncated } ]
        end )
    | map( . + { span_ms: (.end_t - .start_t) }
           | . + { observed_ms: (.span_ms - .unobserved_ms) } );

  def block($q):
    ( per_record($q) ) as $series
    | ( episodes($series) ) as $eps
    | ( [ $eps[] | select(.censored | not) ] ) as $counted
    | ( [ $eps[] | select(.censored) ] ) as $censored
    | ( [ $counted[].span_ms ] | max ) as $maxms
    | { question: $q,
        records_total: ($series | length),
        records_agree:        ( [ $series[] | select(.st == "agree") ]        | length ),
        records_disagree:     ( [ $series[] | select(.st == "disagree") ]     | length ),
        records_insufficient: ( [ $series[] | select(.st == "insufficient") ] | length ),
        insufficient_reasons:
          ( [ $series[] | select(.st == "insufficient") | .why ]
            | group_by(.) | map({ (.[0]): length }) | add // {} ),
        read_errors_seen:
          ( [ $series[] | .errors[]? ] | unique ),
        distinct_answers_seen:
          ( [ $series[] | select(.st != "insufficient") | .values[] ] | unique ),
        max_disagreement_ms: $maxms,
        max_disagreement_is_lower_bound:
          ( ( [ $counted[] | select(.closed | not) | .span_ms ] | max ) != null
            and ( ( [ $counted[] | select(.closed | not) | .span_ms ] | max ) == $maxms ) ),
        max_disagreement_window:
          ( [ $counted[] | select(.span_ms == $maxms) ] | first ),
        total_disagreement_ms: ( [ $counted[].span_ms ] | add // 0 ),
        censored_ms: ( [ $censored[].span_ms ] | max ),
        episode_count: ($eps | length),
        episodes: $eps,
        # INSUFFICIENT_DATA  nothing in this trace could be evaluated at all
        #                    (no .observers block, or never two observers that
        #                    answered) — say so, never "they agreed".
        # NO_DISAGREEMENT    evaluable records exist and none disagreed.
        # MEASURED           at least one episode with a real, countable length.
        # CENSORED_ONLY      the only disagreement found was still open when a
        #                    TRUNCATED trace ran out. Its length is a lower
        #                    bound in censored_ms and max_disagreement_ms is
        #                    deliberately null: the disagreement did not end,
        #                    the data did.
        verdict:
          ( if ( [ $series[] | select(.st != "insufficient") ] | length ) == 0
              then "INSUFFICIENT_DATA"
            elif ($eps | length) == 0 then "NO_DISAGREEMENT"
            elif ($counted | length) == 0 then "CENSORED_ONLY"
            else "MEASURED" end ) };

  { schema: "observer-disagreement-duration/v1",
    scenario_id: ( [ $data[].scenario_id ] | map(select(. != null)) | unique | first ),
    run_id:      ( [ $data[].run_id ]      | map(select(. != null)) | unique | first ),
    source: $source,
    gap_break_ms: $GAP,
    min_observers: $MIN,
    time_axis: "t_rel_ms",
    trace: {
      present: true,
      records: ($data | length),
      stream: ( [ $data[].stream ] | unique ),
      source_host: ( [ $data[].source_host ] | map(select(. != null)) | unique | first ),
      first_t_rel_ms: ( [ $data[].t_rel_ms ] | min ),
      last_t_rel_ms:  ( [ $data[].t_rel_ms ] | max ),
      interval_ms: $interval_ms,
      footer_present: ($footer != null),
      truncated: $truncated,
      exit_reason: ($footer.exit_reason // null),
      footer_records: ($footer.records // null),
      malformed_tail: $malformed,
      seq_gap_count: ($seq_gaps | length),
      seq_gaps: $seq_gaps,
      observers_present: (($observer_ids | length) > 0),
      observers: $observer_ids
    },
    questions: [ QKEYS[] | block(.) ] }
JQEOF
)

emit_absent() {  # $1 = results_dir, $2 = trace path, $3 = reason
  jq -n --arg dir "$1" --arg src "$2" --arg reason "$3" \
        --argjson gap "$GAP_BREAK_MS" --argjson minobs "$MIN_OBSERVERS" \
    '{ schema: "observer-disagreement-duration/v1",
       scenario_id: null, run_id: null,
       source: $src, gap_break_ms: $gap, min_observers: $minobs,
       time_axis: "t_rel_ms",
       trace: { present: false, reason: $reason },
       questions:
         [ "node_ready", "stateful_pod_node", "stateless_endpoint_set"
           | { question: .,
               records_total: 0, records_agree: 0, records_disagree: 0,
               records_insufficient: 0,
               max_disagreement_ms: null,
               max_disagreement_is_lower_bound: false,
               max_disagreement_window: null,
               total_disagreement_ms: 0, censored_ms: null,
               episode_count: 0, episodes: [],
               verdict: "INSUFFICIENT_DATA" } ] }'
}

analyse_one() {  # $1 = results_dir
  local dir="$1" trace tmp lines kept

  if [ -n "$TRACE_OVERRIDE" ]; then trace="$TRACE_OVERRIDE"; else trace="$dir/trace.jsonl"; fi

  if [ ! -f "$trace" ]; then emit_absent "$dir" "$trace" "trace_file_not_found"; return 0; fi
  if [ ! -s "$trace" ]; then emit_absent "$dir" "$trace" "trace_file_empty"; return 0; fi

  tmp=$(mktemp "${TMPDIR:-/tmp}/odd.XXXXXX") || return 1

  # A SIGKILLed recorder can leave a half-written final line. jq stops at the
  # first unparseable value having already emitted every good one before it, so
  # this both sanitises the input and detects the damage.
  lines=$(awk 'END { print NR }' "$trace")
  jq -c . "$trace" > "$tmp" 2>/dev/null
  kept=$(awk 'END { print NR }' "$tmp")
  if [ "${kept:-0}" -eq 0 ]; then
    rm -f "$tmp"
    emit_absent "$dir" "$trace" "no_parseable_records"
    return 0
  fi
  if [ "${kept:-0}" -lt "${lines:-0}" ]; then MALFORMED=true; else MALFORMED=false; fi

  jq -s \
    --arg source "$trace" \
    --argjson GAP "$GAP_BREAK_MS" \
    --argjson MIN "$MIN_OBSERVERS" \
    --argjson malformed "$MALFORMED" \
    "$JQ_PROG" "$tmp"
  local rc=$?
  rm -f "$tmp"
  return $rc
}

RESULT=""
for d in $DIRS; do
  ONE=$(analyse_one "$d") || { echo "{\"error\":\"analysis_failed\",\"results_dir\":\"$d\"}" >&2; exit 1; }
  if [ -z "$RESULT" ]; then RESULT="$ONE"; else RESULT="$RESULT
$ONE"; fi
done

# One results_dir (the normal case, and the one trace-stop.yml uses) yields one
# object; several yield an array, so a consumer never has to guess.
COUNT=$(printf '%s\n' "$DIRS" | awk '{ print NF }')
if [ "${COUNT:-1}" -gt 1 ]; then
  RESULT=$(printf '%s\n' "$RESULT" | jq -s '.')
fi

printf '%s\n' "$RESULT"
if [ -n "$OUTPUT" ]; then printf '%s\n' "$RESULT" > "$OUTPUT"; fi
exit 0
