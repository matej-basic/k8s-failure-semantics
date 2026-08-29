#!/bin/bash
# scripts/repeat-scenario.sh
#
# Suite-wide repetition harness (REVIEW.md M3).
#
# Runs a scenario K times in sequence, writing each iteration to its own
# results directory:
#
#     results/<sN>/<run_id>/run_1/
#     results/<sN>/<run_id>/run_2/
#     ...
#
# — the same shape S6 has always produced, so check-invariants.sh,
# aggregate-results.sh and build-report.sh keep working unchanged, and the
# cross-run statistics REVIEW.md asks for (median/IQR per timing measurement,
# violation frequency instead of a boolean, I4 for any scenario with N > 1)
# have a directory layout to read.
#
#
# ── Why a wrapper script and not more Ansible ────────────────────────────────
#
# S6 repeats by writing five longhand `import_playbook:` entries. That is not
# an oversight: Ansible cannot loop `import_playbook` (imports are resolved at
# parse time, before any loop exists), and the inner file is a MULTI-PLAY
# playbook — each play targets a different host group — so it cannot be
# folded into `include_tasks` either. The alternatives were:
#
#   (a) More longhand imports, per scenario.  23 scenarios x K entries, and K
#       is still frozen at edit time. `-e repeat_count=10` cannot work: the
#       iteration count is the number of import entries in the file, and no
#       variable can change that. This is the option that produced the claim
#       in README.md that does not do anything.
#
#   (b) A driver playbook that shells out to `ansible-playbook` from a
#       `command:` task on localhost, looping over `range(1, K+1)`.  This does
#       work — but nesting Ansible inside Ansible buffers the inner run's
#       output until the task finishes (a multi-hour scenario shows nothing
#       for hours), makes Ctrl-C ambiguous, doubles the fork/SSH bookkeeping,
#       and still needs a shell script's worth of logic for logging, resume
#       and per-iteration failure isolation.
#
#   (c) This: one `ansible-playbook` invocation per iteration, driven from
#       bash.  K is a genuine runtime argument; each iteration is a separate
#       process, so one failed iteration does not abort the rest; output
#       streams live; the run is resumable after an interrupt; and each
#       iteration gets its own log next to its own results.
#
# (c) also matches what the operator actually does by hand today, so nothing
# about a single run changes shape.
#
#
# ── S6 is preserved exactly ──────────────────────────────────────────────────
#
# A scenario's UNIT OF REPETITION is `scenarios/<sN>/run-one.yml` when that
# file exists, and `scenarios/<sN>/playbook.yml` otherwise.  S6 is the only
# scenario with a run-one.yml, so:
#
#   * `repeat-scenario.sh s6 -n 5` runs scenarios/s6/run-one.yml five times
#     with exactly the two variables scenarios/s6/playbook.yml passes it
#     (`run_number`, `run_results_dir`) and nothing else — the same plays, the
#     same vars, the same output paths.
#   * scenarios/s6/playbook.yml is left in place and still works, so the S6
#     entry in playbooks/run-all-scenarios.yml is untouched.
#
# Every other scenario has no run-one.yml, so its playbook.yml is the unit and
# the harness pins `results_dir` for it with an extra-var (highest precedence,
# so it wins over the group_vars default AND over any play var).  No scenario
# except s6 sets results_dir as a play var, and no scenario except s6 derives a
# path from results_base, so this is a complete override.
#
#
# ── Usage ────────────────────────────────────────────────────────────────────
#
#   scripts/repeat-scenario.sh [options] <target> [<target> ...]
#
#   target := sN        iterations from -n, else the plan, else the default
#           | sN:K      exactly K iterations of sN
#
# Options:
#   -n, --iterations K   iterations for targets that do not carry :K
#   -r, --run-id ID      run_id for this batch (default: date +%Y%m%d_%H%M%S).
#                        All iterations of all targets share it, which is what
#                        groups them into one experiment.
#       --results-base D results root (default: <repo>/results)
#       --plan           targets = every scenario registered in
#                        playbooks/run-all-scenarios.yml, counts from
#                        inventory/group_vars/all.yml
#       --start-at N     begin at iteration N (default 1)
#       --resume         skip iterations that already completed successfully
#       --stop-on-error  abort the batch on the first failed iteration
#                        (default: record it and carry on)
#       --health-check / --no-health-check
#                        run playbooks/_health-check.yml between iterations.
#                        Default: on for a scenario whose unit is playbook.yml
#                        (that is what run-all-scenarios.yml does between two
#                        scenarios today), OFF for one whose unit is
#                        run-one.yml, because such a unit already contains its
#                        own reset play — S6 has never had a fleet-wide fault
#                        teardown between its iterations and does not get one
#                        now unless you ask.
#       --no-invariants  do not backfill a missing invariant_report.json
#       --extra "ARGS"   extra ansible-playbook args, appended verbatim.
#                        Repeatable. e.g. --extra "-e s22_variant=kubelet"
#       --detached       re-exec under nohup, fully detached (implies --yes)
#       --log FILE       log file for --detached
#   -y, --yes            do not prompt before a long batch
#   -N, --dry-run        print the exact commands and exit; contacts nothing
#   -h, --help           this text
#
# Examples:
#   scripts/repeat-scenario.sh s2 -n 5             # N=5 for one scenario
#   scripts/repeat-scenario.sh s6 -n 5             # S6 exactly as designed
#   scripts/repeat-scenario.sh s1:5 s2:5 s20:3     # per-scenario N
#   scripts/repeat-scenario.sh --plan              # the plan's counts
#   scripts/repeat-scenario.sh --plan -n 5 --detached   # REVIEW.md's N>=5
#
# THE DEFAULT IS N=1.  A full pass of the 23 scenarios already takes several
# hours; N=5 across all of them is a multi-day run. The harness will not
# silently commit the lab to that — the operator opts in with -n or the plan.

set -u

# ── bash 3.2 (macOS) ─────────────────────────────────────────────────────────
# No `mapfile`, no `declare -A`, no `${var^^}`. Parallel indexed arrays and
# awk only. BSD sed has no \s.

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SWEEP_PLAYBOOK="$REPO_DIR/playbooks/run-all-scenarios.yml"
HEALTH_PLAYBOOK="$REPO_DIR/playbooks/_health-check.yml"
GROUP_VARS="$REPO_DIR/inventory/group_vars/all.yml"
INVENTORY="$REPO_DIR/inventory/hosts.ini"
HARNESS_VERSION=1

die() { echo "repeat-scenario: $*" >&2; exit 2; }

usage() {
  awk 'NR>1 && /^# /{sub(/^# ?/,""); print; next} NR>1 && /^#$/{print ""; next} NR>1 && !/^#/{exit}' "$0"
}

# ── Defaults ─────────────────────────────────────────────────────────────────
ITERATIONS=""
RUN_ID=""
RESULTS_BASE="$REPO_DIR/results"
USE_PLAN=0
START_AT=1
RESUME=0
STOP_ON_ERROR=0
HEALTH_CHECK=1
HEALTH_CHECK_EXPLICIT=0
BACKFILL_INVARIANTS=1
DETACHED=0
DETACH_LOG=""
ASSUME_YES=0
DRY_RUN=0
EXTRA_ARGS=()
TARGETS=()

ORIG_ARGS=("$@")

while [ $# -gt 0 ]; do
  case "$1" in
    -n|--iterations)   ITERATIONS="${2:-}"; shift 2 ;;
    -r|--run-id)       RUN_ID="${2:-}"; shift 2 ;;
    --results-base)    RESULTS_BASE="${2:-}"; shift 2 ;;
    --plan)            USE_PLAN=1; shift ;;
    --start-at)        START_AT="${2:-}"; shift 2 ;;
    --resume)          RESUME=1; shift ;;
    --stop-on-error)   STOP_ON_ERROR=1; shift ;;
    --continue-on-error) STOP_ON_ERROR=0; shift ;;
    --health-check)    HEALTH_CHECK=1; HEALTH_CHECK_EXPLICIT=1; shift ;;
    --no-health-check) HEALTH_CHECK=0; HEALTH_CHECK_EXPLICIT=1; shift ;;
    --invariants)      BACKFILL_INVARIANTS=1; shift ;;
    --no-invariants)   BACKFILL_INVARIANTS=0; shift ;;
    --extra)           EXTRA_ARGS+=("${2:-}"); shift 2 ;;
    --detached)        DETACHED=1; shift ;;
    --log)             DETACH_LOG="${2:-}"; shift 2 ;;
    -y|--yes)          ASSUME_YES=1; shift ;;
    -N|--dry-run)      DRY_RUN=1; shift ;;
    -h|--help)         usage; exit 0 ;;
    -*)                die "unknown option: $1 (try --help)" ;;
    *)                 TARGETS+=("$1"); shift ;;
  esac
done

[ -n "$ITERATIONS" ] && { case "$ITERATIONS" in ''|*[!0-9]*) die "--iterations must be a positive integer, got '$ITERATIONS'";; esac; }
[ -n "$ITERATIONS" ] && [ "$ITERATIONS" -lt 1 ] && die "--iterations must be >= 1"
case "$START_AT" in ''|*[!0-9]*) die "--start-at must be a positive integer, got '$START_AT'";; esac
[ "$START_AT" -lt 1 ] && die "--start-at must be >= 1"

command -v jq >/dev/null 2>&1 || die "jq is required (brew install jq)"
[ -f "$SWEEP_PLAYBOOK" ] || die "not a k8s-failure-semantics checkout: $SWEEP_PLAYBOOK missing"

# ── The registered scenario list ─────────────────────────────────────────────
# Single source of truth is playbooks/run-all-scenarios.yml — CLAUDE.md already
# requires every new scenario tag to be registered there, so parsing it means
# the harness can never drift behind the suite. Order is preserved, which
# matters: S28 mutates etcd membership and is registered last on purpose.
registered_scenarios() {
  awk '
    /^[[:space:]]*tags:[[:space:]]*s[0-9]+[[:space:]]*$/ {
      t = $2
      if (!(t in seen)) { seen[t] = 1; order[++n] = t }
    }
    END { for (i = 1; i <= n; i++) print order[i] }
  ' "$SWEEP_PLAYBOOK"
}

# ── The repetition plan ──────────────────────────────────────────────────────
# inventory/group_vars/all.yml carries:
#     scenario_repeat_default: <int>
#     scenario_repeat_counts:
#       s6: 5
# so the plan is visible to Ansible as well as to this script. Flat map of
# `sN: <int>` under one key, two-space indented — parseable with awk without
# pulling in a YAML dependency the macOS controller does not have.
plan_default() {
  local v
  v=$(awk '/^scenario_repeat_default:[[:space:]]*[0-9]+/ { print $2; exit }' "$GROUP_VARS" 2>/dev/null)
  case "${v:-}" in ''|*[!0-9]*) echo 1 ;; *) echo "$v" ;; esac
}

plan_count_for() {
  # $1 = scenario id. Prints the plan's count, or nothing if it has no entry.
  awk -v want="$1" '
    /^scenario_repeat_counts:/ { inblock = 1; next }
    inblock && /^[^[:space:]#]/ { inblock = 0 }
    inblock && /^[[:space:]]+[a-z0-9]+:[[:space:]]*[0-9]+/ {
      key = $1; sub(/:$/, "", key)
      if (key == want) { print $2; exit }
    }
  ' "$GROUP_VARS" 2>/dev/null
}

PLAN_DEFAULT=$(plan_default)

# ── Resolve targets into parallel arrays SC_IDS / SC_COUNTS ──────────────────
# Precedence, highest first:  sN:K  >  -n K  >  scenario_repeat_counts[sN]
#                             >  scenario_repeat_default
SC_IDS=()
SC_COUNTS=()

add_target() {
  local tok="$1" id count
  case "$tok" in
    *:*) id="${tok%%:*}"; count="${tok##*:}" ;;
    *)   id="$tok";       count="" ;;
  esac
  case "$id" in
    s[0-9]|s[0-9][0-9]) : ;;
    *) die "not a scenario id: '$id' (expected sN, e.g. s2 or s20)" ;;
  esac
  [ -d "$REPO_DIR/scenarios/$id" ] || die "no such scenario: scenarios/$id"

  if [ -z "$count" ]; then
    if [ -n "$ITERATIONS" ]; then
      count="$ITERATIONS"
    else
      count=$(plan_count_for "$id")
      [ -n "$count" ] || count="$PLAN_DEFAULT"
    fi
  fi
  case "$count" in ''|*[!0-9]*) die "iteration count for $id must be a positive integer, got '$count'";; esac
  [ "$count" -lt 1 ] && die "iteration count for $id must be >= 1"

  SC_IDS+=("$id")
  SC_COUNTS+=("$count")
}

if [ "$USE_PLAN" -eq 1 ]; then
  [ ${#TARGETS[@]} -eq 0 ] || die "--plan takes its targets from the sweep playbook; do not also list scenarios"
  for s in $(registered_scenarios); do add_target "$s"; done
else
  [ ${#TARGETS[@]} -gt 0 ] || { usage; exit 2; }
  for t in "${TARGETS[@]}"; do add_target "$t"; done
fi

[ ${#SC_IDS[@]} -gt 0 ] || die "nothing to run"

[ -n "$RUN_ID" ] || RUN_ID="$(date +%Y%m%d_%H%M%S)"
case "$RUN_ID" in
  */*) die "run_id must not contain '/': it is a single path component" ;;
esac

# ── Detached re-exec ─────────────────────────────────────────────────────────
# Same reasoning as scripts/run-sweep-detached.sh: the shell that launches a
# multi-hour run can be killed by a CI/terminal/agent wall-clock window, so
# redirect stdin from /dev/null and disown the child. The batch's run_id is
# pinned here so the caller is told where the results will land.
if [ "$DETACHED" -eq 1 ] && [ "$DRY_RUN" -eq 0 ]; then
  [ -n "$DETACH_LOG" ] || DETACH_LOG="/tmp/repeat-${RUN_ID}.log"
  CHILD=()
  for a in "${ORIG_ARGS[@]}"; do
    [ "$a" = "--detached" ] && continue
    CHILD+=("$a")
  done
  CHILD+=(--run-id "$RUN_ID" --yes)
  nohup "$0" "${CHILD[@]}" > "$DETACH_LOG" 2>&1 < /dev/null &
  CHILD_PID=$!
  disown "$CHILD_PID" 2>/dev/null || true
  sleep 2
  if kill -0 "$CHILD_PID" 2>/dev/null; then
    echo "pid=$CHILD_PID run_id=$RUN_ID log=$DETACH_LOG results=$RESULTS_BASE"
    exit 0
  fi
  echo "repeat-scenario: detached child died immediately — last 20 lines:" >&2
  tail -n 20 "$DETACH_LOG" >&2
  exit 1
fi

# ── Per-scenario unit of repetition ──────────────────────────────────────────
iter_playbook() {
  if [ -f "$REPO_DIR/scenarios/$1/run-one.yml" ]; then
    echo "$REPO_DIR/scenarios/$1/run-one.yml"
  else
    echo "$REPO_DIR/scenarios/$1/playbook.yml"
  fi
}
iter_playbook_rel() {
  local p; p=$(iter_playbook "$1"); echo "${p#$REPO_DIR/}"
}

# ── Batch plan ───────────────────────────────────────────────────────────────
TOTAL_ITERS=0
i=0
while [ $i -lt ${#SC_IDS[@]} ]; do
  n="${SC_COUNTS[$i]}"
  [ "$n" -ge "$START_AT" ] && TOTAL_ITERS=$(( TOTAL_ITERS + n - START_AT + 1 ))
  i=$(( i + 1 ))
done

echo "repeat-scenario: run_id=$RUN_ID results_base=$RESULTS_BASE"
echo "repeat-scenario: ${#SC_IDS[@]} scenario(s), $TOTAL_ITERS iteration(s) total"
i=0
while [ $i -lt ${#SC_IDS[@]} ]; do
  printf '    %-4s N=%-3s unit=%s\n' \
    "${SC_IDS[$i]}" "${SC_COUNTS[$i]}" "$(iter_playbook_rel "${SC_IDS[$i]}")"
  i=$(( i + 1 ))
done

# A scenario pass is hours, not minutes. Say so before committing the lab.
if [ "$TOTAL_ITERS" -gt 10 ] && [ "$ASSUME_YES" -eq 0 ] && [ "$DRY_RUN" -eq 0 ]; then
  if [ -t 0 ]; then
    echo
    echo "That is $TOTAL_ITERS full scenario passes. A single pass takes hours;"
    echo "this batch is likely a multi-day run against the live lab."
    printf 'Continue? [y/N] '
    read -r reply
    case "$reply" in y|Y|yes|YES) : ;; *) echo "aborted."; exit 1 ;; esac
  else
    die "$TOTAL_ITERS iterations is a multi-day batch and stdin is not a terminal; pass --yes to confirm"
  fi
fi

# ── Iteration runner ─────────────────────────────────────────────────────────

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Cluster health in one word, for the per-iteration record. Asks EACH
# control-plane node for its own /healthz rather than going through one API
# server or the VIP: when S3 took out cp1 and cp3, cp2 still answered 200 and
# the VIP was dead, so any single-endpoint probe would have called that
# healthy. Echoes "healthy", or "degraded:<detail>". Never fails the caller.
cluster_health_probe() {
  local cps ip up=0 total=0 vip_code=""
  cps=$(awk '/^\[control_plane\]/{f=1;next} /^\[/{f=0} f && /ansible_host=/{
          for (i=1;i<=NF;i++) if ($i ~ /^ansible_host=/) { sub(/^ansible_host=/,"",$i); print $i }
        }' "$INVENTORY" 2>/dev/null)
  for ip in $cps; do
    total=$(( total + 1 ))
    if [ "$(ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
              "${SSH_USER:-ansible}@$ip" \
              'curl -sk -o /dev/null -w "%{http_code}" --max-time 5 https://127.0.0.1:6443/healthz' \
              2>/dev/null)" = "200" ]; then
      up=$(( up + 1 ))
    fi
  done
  [ "$total" -eq 0 ] && { printf 'unknown'; return 0; }
  if [ "$up" -eq "$total" ]; then printf 'healthy'
  else printf 'degraded:apiservers_%s_of_%s' "$up" "$total"; fi
}

# The probe above is one instantaneous sample, and an API server reconnecting
# to etcd after a fault is briefly unavailable without being broken: the first
# instrumented S3 iteration recorded apiservers_0_of_3 immediately after its
# teardown, while the inter-iteration health check — which retries — passed,
# and all three answered 200 a minute later. A single sample would therefore
# mark the NEXT run started_degraded on a cluster that was fine, and a noisy
# record is worse than none for the analysis this exists to support.
#
# So allow the same tolerance the health check has: re-probe for up to
# health_settle_seconds before concluding the cluster is actually degraded.
# Reports the first reading too, because "recovered after 40s" is itself a
# measurement about the scenario.
cluster_health_settled() {
  local deadline first now result
  first=$(cluster_health_probe)
  [ "$first" = "healthy" ] && { printf '%s' "$first"; return 0; }
  deadline=$(( $(date +%s) + ${HEALTH_SETTLE_SECONDS:-90} ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    sleep 10
    result=$(cluster_health_probe)
    if [ "$result" = "healthy" ]; then
      printf 'healthy_after_settle(first=%s)' "$first"
      return 0
    fi
  done
  printf '%s' "$result"
}

# Written into every iteration directory. This is the file that makes N
# discoverable from a single results_dir without parsing directory names —
# check-invariants.sh is handed one directory and has to decide whether it is
# iteration K of N (see the I4 note in the header of this repo's REVIEW work).
write_iteration_meta() {
  local dir="$1" scen="$2" num="$3" total="$4" status="$5" rc="$6"
  local started="$7" finished="$8" dur="$9"
  jq -n \
    --arg scenario "$scen" \
    --arg run_id "$RUN_ID" \
    --arg unit "$(iter_playbook_rel "$scen")" \
    --arg results_dir "$dir" \
    --arg status "$status" \
    --arg started_at "$started" \
    --arg finished_at "$finished" \
    --arg harness "scripts/repeat-scenario.sh" \
    --argjson run_number "$num" \
    --argjson iterations_planned "$total" \
    --argjson rc "$rc" \
    --argjson duration_s "$dur" \
    --argjson harness_version "$HARNESS_VERSION" \
    '{scenario: $scenario, run_id: $run_id, run_number: $run_number,
      iterations_planned: $iterations_planned, unit_playbook: $unit,
      results_dir: $results_dir, status: $status, rc: $rc,
      started_at: $started_at, finished_at: $finished_at,
      duration_s: $duration_s,
      harness: $harness, harness_version: $harness_version}' \
    > "$dir/iteration_meta.json"
}

# Rewritten after every iteration, so an interrupted batch still leaves a
# valid, truthful manifest behind.
write_manifest() {
  local scen="$1" total="$2" started="$3" finished="$4" iters_file="$5"
  local root="$RESULTS_BASE/$scen/$RUN_ID"
  jq -n \
    --arg scenario "$scen" \
    --arg run_id "$RUN_ID" \
    --arg unit "$(iter_playbook_rel "$scen")" \
    --arg results_base "$RESULTS_BASE" \
    --arg started_at "$started" \
    --arg finished_at "$finished" \
    --arg harness "scripts/repeat-scenario.sh" \
    --argjson iterations_planned "$total" \
    --argjson start_at "$START_AT" \
    --argjson harness_version "$HARNESS_VERSION" \
    --slurpfile iters "$iters_file" \
    '($iters[0] // []) as $it |
     {scenario: $scenario, run_id: $run_id, unit_playbook: $unit,
      results_base: $results_base,
      iterations_planned: $iterations_planned, start_at: $start_at,
      iterations_completed: ([$it[] | select(.status == "ok")] | length),
      iterations_failed:    ([$it[] | select(.status == "failed")] | length),
      iterations_reused:    ([$it[] | select(.reused == true)] | length),
      started_at: $started_at, finished_at: $finished_at,
      harness: $harness, harness_version: $harness_version,
      iterations: $it}' \
    > "$root/repeat_manifest.json"
}

# Scenarios end by running check-invariants.sh themselves; s6/run-one.yml does
# not (it predates that convention). Backfill it so every iteration directory
# carries a comparable invariant_report.json for the cross-run statistics —
# without touching the scenario. Skipped when the scenario already wrote one.
backfill_invariants() {
  local dir="$1"
  [ "$BACKFILL_INVARIANTS" -eq 1 ] || return 0
  [ -f "$dir/invariant_report.json" ] && return 0
  ls "$dir"/snapshot_*.json >/dev/null 2>&1 || return 0
  echo "    backfilling invariant_report.json"
  if "$REPO_DIR/scripts/check-invariants.sh" "$dir" > "$dir/invariant_report.json.tmp" 2>/dev/null; then
    mv "$dir/invariant_report.json.tmp" "$dir/invariant_report.json"
    cp "$dir/invariant_report.json" "$dir/invariant_report.txt"
  else
    rm -f "$dir/invariant_report.json.tmp"
    echo "    check-invariants.sh failed for $dir — left unwritten" >&2
  fi
}

# INTERRUPTED breaks out of the loops for any reason (signal or
# --stop-on-error); SIGNALLED distinguishes a real signal, so the exit code
# does not claim 130 (killed) for an ordinary early abort.
INTERRUPTED=0
SIGNALLED=0
trap 'INTERRUPTED=1; SIGNALLED=1; echo; echo "repeat-scenario: interrupted."' INT TERM

BATCH_RC=0
BATCH_STARTED=$(now_iso)

i=0
while [ $i -lt ${#SC_IDS[@]} ]; do
  SCEN="${SC_IDS[$i]}"
  N="${SC_COUNTS[$i]}"
  i=$(( i + 1 ))

  UNIT=$(iter_playbook "$SCEN")

  # A scenario whose unit is run-one.yml owns its own inter-iteration reset —
  # S6's first play deletes and redeploys the workloads before every iteration.
  # Injecting playbooks/_health-check.yml between those iterations would add a
  # fleet-wide fault-teardown sweep S6 has never run, so it is off by default
  # here and only happens if the operator asks for it with --health-check.
  # Scenarios whose unit is playbook.yml get it, because that is what
  # run-all-scenarios.yml puts between two scenario passes today.
  SCEN_HEALTH="$HEALTH_CHECK"
  if [ "$HEALTH_CHECK_EXPLICIT" -eq 0 ]; then
    case "$UNIT" in */run-one.yml) SCEN_HEALTH=0 ;; esac
  fi

  ROOT="$RESULTS_BASE/$SCEN/$RUN_ID"
  ITERS_FILE="$ROOT/.iterations.json"
  SCEN_STARTED=$(now_iso)

  if [ "$DRY_RUN" -eq 0 ]; then
    mkdir -p "$ROOT" || die "cannot create $ROOT"
    [ -f "$ITERS_FILE" ] || echo '[]' > "$ITERS_FILE"
  fi

  K="$START_AT"
  while [ "$K" -le "$N" ]; do
    [ "$INTERRUPTED" -eq 1 ] && break
    DIR="$ROOT/run_$K"

    # ── The ansible-playbook invocation for this iteration ──────────────────
    # s6 (run-one.yml): exactly the two vars scenarios/s6/playbook.yml passes,
    #   and nothing more, so S6's plays see byte-identical inputs.
    # everything else (playbook.yml): results_dir pinned as an extra-var, which
    #   outranks the group_vars default and any play var.
    CMD=(ansible-playbook -i "$INVENTORY" "$UNIT"
         -e "results_base=$RESULTS_BASE"
         -e "run_id=$RUN_ID")
    case "$UNIT" in
      */run-one.yml)
        CMD+=(-e "run_number=$K" -e "run_results_dir=$DIR") ;;
      *)
        CMD+=(-e "results_dir=$DIR" -e "run_number=$K") ;;
    esac
    if [ ${#EXTRA_ARGS[@]} -gt 0 ]; then
      for e in "${EXTRA_ARGS[@]}"; do
        # Split on whitespace on purpose: --extra takes a fragment of a
        # command line ("-e s22_variant=kubelet"), not a single token.
        for w in $e; do CMD+=("$w"); done
      done
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
      echo
      echo "# $SCEN iteration $K/$N -> $DIR"
      printf '%q ' "${CMD[@]}"; echo
      if [ "$SCEN_HEALTH" -eq 1 ] && [ "$K" -lt "$N" ]; then
        printf '%q ' ansible-playbook -i "$INVENTORY" "$HEALTH_PLAYBOOK"; echo
      fi
      K=$(( K + 1 ))
      continue
    fi

    if [ "$RESUME" -eq 1 ] && [ -f "$DIR/iteration_meta.json" ] \
       && [ "$(jq -r '.status // ""' "$DIR/iteration_meta.json" 2>/dev/null)" = "ok" ]; then
      # Carry the previous batch's iteration_meta forward verbatim and flag it
      # `reused`. The iteration DID complete, so it must keep counting towards
      # iterations_completed; what did not happen is this batch re-running it.
      echo "== $SCEN iteration $K/$N — already complete, reusing (--resume)"
      jq --slurpfile m "$DIR/iteration_meta.json" --argjson k "$K" --arg dir "run_$K" \
        '(map(select(.run_number != $k))) + [($m[0] + {dir: $dir, reused: true})] | sort_by(.run_number)' \
        "$ITERS_FILE" > "$ITERS_FILE.tmp" && mv "$ITERS_FILE.tmp" "$ITERS_FILE"
      K=$(( K + 1 ))
      continue
    fi

    mkdir -p "$DIR"
    LOG="$DIR/ansible.log"
    STARTED=$(now_iso); T0=$(date +%s)

    # ── Cluster health going IN ───────────────────────────────────────────
    # Some scenarios legitimately leave the cluster broken: S3 has twice taken
    # out two of three API servers and the VIP, needing a kubelet restart to
    # come back. That is accepted — it is what a fault-injection suite does —
    # but a run that STARTED on a degraded cluster is measuring the previous
    # scenario's wreckage, not its own fault, and nothing recorded that.
    #
    # Cheap, direct, and independent of any one API server: ask each
    # control-plane node for its own /healthz. Recorded, never fatal.
    PRE_HEALTH=$(cluster_health_settled)
    echo "-- pre-iteration cluster health: $PRE_HEALTH"

    echo
    echo "== $SCEN iteration $K/$N  ($(iter_playbook_rel "$SCEN")) -> $DIR"
    "${CMD[@]}" 2>&1 | tee "$LOG"
    # bash 3.2 has PIPESTATUS; ${PIPESTATUS[0]} is ansible-playbook's rc.
    RC=${PIPESTATUS[0]}

    T1=$(date +%s); FINISHED=$(now_iso); DUR=$(( T1 - T0 ))
    if [ "$RC" -eq 0 ]; then STATUS=ok; else STATUS=failed; BATCH_RC=1; fi
    echo "== $SCEN iteration $K/$N $STATUS (rc=$RC, ${DUR}s)"

    backfill_invariants "$DIR"
    write_iteration_meta "$DIR" "$SCEN" "$K" "$N" "$STATUS" "$RC" \
      "$STARTED" "$FINISHED" "$DUR"

    jq --slurpfile m "$DIR/iteration_meta.json" --argjson k "$K" --arg dir "run_$K" \
      '(map(select(.run_number != $k))) + [($m[0] + {dir: $dir})] | sort_by(.run_number)' \
      "$ITERS_FILE" > "$ITERS_FILE.tmp" && mv "$ITERS_FILE.tmp" "$ITERS_FILE"
    write_manifest "$SCEN" "$N" "$SCEN_STARTED" "$(now_iso)" "$ITERS_FILE"

    if [ "$RC" -ne 0 ] && [ "$STOP_ON_ERROR" -eq 1 ]; then
      echo "repeat-scenario: stopping (--stop-on-error)" >&2
      INTERRUPTED=1
      break
    fi

    # Between iterations, not after the last one: leave the cluster in the
    # state the final iteration left it, exactly as a single run does.
    HEALTH_RC=""
    if [ "$SCEN_HEALTH" -eq 1 ] && [ "$K" -lt "$N" ] && [ "$INTERRUPTED" -eq 0 ]; then
      echo "-- inter-iteration health check"
      if ansible-playbook -i "$INVENTORY" "$HEALTH_PLAYBOOK" \
           -e "results_base=$RESULTS_BASE" >> "$LOG" 2>&1; then
        HEALTH_RC=passed
      else
        HEALTH_RC=failed
        echo "-- health check FAILED after $SCEN run_$K (see $LOG)" >&2
        BATCH_RC=1
        if [ "$STOP_ON_ERROR" -eq 1 ]; then INTERRUPTED=1; break; fi
      fi
    fi

    # ── Cluster health coming OUT, written beside the run's own evidence ──
    # cluster_health.json is what lets analysis separate "this fault produced
    # this result" from "this run inherited a broken cluster". The batch
    # deliberately carries on either way (that is the default and the operator
    # asked to keep it), so the record is the safeguard, not the stopping.
    POST_HEALTH=$(cluster_health_settled)
    echo "-- post-iteration cluster health: $POST_HEALTH"
    jq -n --arg pre "$PRE_HEALTH" --arg post "$POST_HEALTH" \
          --arg hc "${HEALTH_RC:-not_run}" --arg scen "$SCEN" --argjson k "$K" \
      '{scenario: $scen, run_number: $k,
        cluster_health_before: $pre,
        cluster_health_after:  $post,
        inter_iteration_health_check: $hc,
        started_degraded: (($pre | startswith("degraded"))),
        left_degraded:    (($post | startswith("degraded"))),
        recovered_after_settle: (($post | startswith("healthy_after_settle"))),
        note: "started_degraded=true means this iteration ran against a cluster the PREVIOUS scenario left broken, so its verdicts describe inherited damage rather than its own fault. left_degraded=true is often legitimate - a fault-injection scenario may deliberately end with a control plane that has not finished recovering."}' \
      > "$DIR/cluster_health.json" 2>/dev/null || true

    K=$(( K + 1 ))
  done

  [ "$DRY_RUN" -eq 0 ] && write_manifest "$SCEN" "$N" "$SCEN_STARTED" "$(now_iso)" "$ITERS_FILE"
  [ "$INTERRUPTED" -eq 1 ] && break
done

if [ "$DRY_RUN" -eq 1 ]; then
  echo
  echo "# dry run — nothing was executed"
  exit 0
fi

echo
echo "repeat-scenario: batch $RUN_ID finished (started $BATCH_STARTED, ended $(now_iso))"
i=0
while [ $i -lt ${#SC_IDS[@]} ]; do
  M="$RESULTS_BASE/${SC_IDS[$i]}/$RUN_ID/repeat_manifest.json"
  [ -f "$M" ] && jq -r '"    \(.scenario): \(.iterations_completed)/\(.iterations_planned) ok, \(.iterations_failed) failed, \(.iterations_reused) reused"' "$M"
  i=$(( i + 1 ))
done
[ "$SIGNALLED" -eq 1 ] && exit 130
exit "$BATCH_RC"
