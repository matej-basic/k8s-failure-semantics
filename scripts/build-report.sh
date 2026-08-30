#!/usr/bin/env bash
# scripts/build-report.sh
#
# Walk the results directory and emit a single self-contained report.html
# that lets you browse every scenario run, snapshot, and invariant verdict
# in a web browser. No CDN, no build step — just open the file.
#
# Usage:
#   scripts/build-report.sh [results_dir] [output_html]
# Defaults:
#   results_dir = ./results
#   output_html = ./report.html

set -euo pipefail

RESULTS_DIR="${1:-./results}"
OUTPUT_HTML="${2:-./report.html}"

if [ ! -d "$RESULTS_DIR" ]; then
  echo "build-report: results directory '$RESULTS_DIR' does not exist" >&2
  exit 1
fi

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RESULTS_ABS="$(cd "$RESULTS_DIR" && pwd)"

# ── Collect every run's data into one JSON blob ───────────────────────────────
# Shape:
#   {
#     generated_at: "...",
#     results_path: "...",
#     aggregate: <aggregate_report.json or null>,
#     scenarios: {
#       "s1": {
#         runs: {
#           "20260520_091812": {
#             snapshots: { "pre_fault": {...}, "t_plus_30": {...}, ... },
#             invariant_report: {...} | null,
#             run_index: "<text>" | null
#           }
#         }
#       }
#     }
#   }

build_data() {
  python3 - "$RESULTS_ABS" <<'PY'
import json, os, sys, datetime
root = sys.argv[1]
data = {
    "generated_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "results_path": root,
    "aggregate": None,
    "scenarios": {},
}

agg_path = os.path.join(root, "aggregate_report.json")
if os.path.isfile(agg_path):
    try:
        with open(agg_path) as f:
            data["aggregate"] = json.load(f)
    except Exception as e:
        data["aggregate"] = {"error": f"failed to parse: {e}"}

# Per-scenario interpretations (results/interpretations/<sid>.json), each written
# by a dedicated analysis pass over that scenario's raw runs. These carry the
# data_interpretation / scientific_interpretation / per_invariant / per_run
# narrative the report renders beside the measured verdicts. They are evidence
# ABOUT the data, never a substitute for it: every claim in them is expected to
# be traceable to a file under the scenario's own run directories.
data["interpretations"] = {}
interp_dir = os.path.join(root, "interpretations")
if os.path.isdir(interp_dir):
    for fn in sorted(os.listdir(interp_dir)):
        if not fn.endswith(".json"):
            continue
        sid = fn[:-5]
        try:
            with open(os.path.join(interp_dir, fn)) as f:
                data["interpretations"][sid] = json.load(f)
        except Exception as e:
            data["interpretations"][sid] = {"error": f"failed to parse: {e}"}

for sc in sorted(os.listdir(root)):
    sc_path = os.path.join(root, sc)
    if not os.path.isdir(sc_path) or not sc.startswith("s"):
        continue
    runs = {}
    # A run directory is either a single run, with snapshot_*.json directly
    # inside it, or a repeated batch produced by scripts/repeat-scenario.sh,
    # which nests each iteration in run_<K>/ and drops a repeat_manifest.json
    # beside them. Without this expansion a batch reads as zero snapshots and
    # the whole scenario silently disappears from the report -- the failure
    # would look like "the scenario was never run" rather than "the report
    # cannot read this layout".
    #
    # Iterations are surfaced as separate runs keyed "<run_id>/run_<K>", so a
    # repeated scenario shows one entry per iteration and every consumer that
    # already handles several runs per scenario keeps working unchanged.
    def iteration_dirs(run_path):
        names = []
        for fn in os.listdir(run_path):
            if not fn.startswith("run_"):
                continue
            if not os.path.isdir(os.path.join(run_path, fn)):
                continue
            tail = fn[len("run_"):]
            if tail.isdigit():
                names.append((int(tail), fn))
        # Numeric, not lexical: run_10 must not sort before run_2.
        return [fn for _, fn in sorted(names)]

    expanded = []
    for run in sorted(os.listdir(sc_path)):
        run_path = os.path.join(sc_path, run)
        if not os.path.isdir(run_path):
            continue
        iters = iteration_dirs(run_path)
        is_batch = iters and (
            os.path.isfile(os.path.join(run_path, "repeat_manifest.json"))
            or not any(f.startswith("snapshot_") for f in os.listdir(run_path))
        )
        if is_batch:
            for it in iters:
                expanded.append((run + "/" + it, os.path.join(run_path, it)))
        else:
            expanded.append((run, run_path))

    # ── What gets embedded, and why not everything ────────────────────────
    # This report inlines snapshots so it stays one self-contained file. That
    # is right at N=1 and does not survive N=5: the 2026-08-29 campaign left
    # 1011 snapshots at a 247 KB median, so embedding them all meant ~228 MB
    # of JSON. The build ran 30 minutes at 100 % CPU and would have produced a
    # page no browser opens (REVIEW.md D36).
    #
    # Two reductions, in order of how much they buy:
    #
    # 1. Drop fields the template never reads. `disagreement` is 122.7 KB of a
    #    267 KB snapshot — 46 % — and appears in report-template.html only in
    #    prose, never as a data reference. `observer_answers` and `trace_meta`
    #    have no references at all. All three stay on disk; they are simply
    #    not inlined. warning_events is kept but capped, since only the recent
    #    ones are ever looked at.
    #
    # 2. Embed full snapshots for the FIRST iteration of each scenario only.
    #    Later iterations carry their invariant_report, which is what the
    #    heatmap and per-invariant pages actually consume; the drill-down that
    #    needs raw snapshots is preserved for one representative run per
    #    scenario. Set REPORT_FULL_SNAPSHOTS=1 to inline every iteration and
    #    accept the size.
    DROP_FIELDS = ("disagreement", "observer_answers", "trace_meta")
    WARNING_EVENT_CAP = 25
    full_snapshots = os.environ.get("REPORT_FULL_SNAPSHOTS") == "1"

    def slim(snap):
        for k in DROP_FIELDS:
            snap.pop(k, None)
        cp = snap.get("control_plane")
        if isinstance(cp, dict):
            we = cp.get("warning_events")
            if isinstance(we, list) and len(we) > WARNING_EVENT_CAP:
                cp["warning_events"] = we[-WARNING_EVENT_CAP:]
                cp["warning_events_truncated"] = len(we)
        return snap

    for idx, (run, run_path) in enumerate(expanded):
        embed_snaps = full_snapshots or idx == 0
        snaps = {}
        for fn in sorted(os.listdir(run_path)):
            full = os.path.join(run_path, fn)
            if fn.startswith("snapshot_") and fn.endswith(".json"):
                label = fn[len("snapshot_"):-len(".json")]
                if not embed_snaps:
                    # Relative to the report, so the pair (report.html +
                    # results/) is portable: the raw data ships alongside and
                    # the page fetches from it. Absolute paths would only work
                    # on the machine that built the report.
                    snaps[label] = {
                        "_lazy": True,
                        "_path": os.path.relpath(full, os.path.dirname(root)),
                    }
                    continue
                try:
                    with open(full) as f:
                        snaps[label] = slim(json.load(f))
                except Exception as e:
                    snaps[label] = {"_parse_error": str(e)}
        invariant_report = None
        ir_path = os.path.join(run_path, "invariant_report.json")
        if os.path.isfile(ir_path):
            try:
                with open(ir_path) as f:
                    invariant_report = json.load(f)
            except Exception as e:
                invariant_report = {"_parse_error": str(e)}
        else:
            # Some scenarios write invariant_report.txt (raw JSON) instead.
            ir_txt = os.path.join(run_path, "invariant_report.txt")
            if os.path.isfile(ir_txt):
                try:
                    with open(ir_txt) as f:
                        invariant_report = json.load(f)
                except Exception as e:
                    invariant_report = {"_parse_error": str(e), "_source": "invariant_report.txt"}
        run_index = None
        idx_path = os.path.join(run_path, "run_index.txt")
        if os.path.isfile(idx_path):
            with open(idx_path) as f:
                run_index = f.read()
        runs[run] = {
            "snapshots": snaps,
            "invariant_report": invariant_report,
            "run_index": run_index,
        }
    if runs:
        data["scenarios"][sc] = {"runs": runs}

json.dump(data, sys.stdout, separators=(",", ":"))
PY
}

DATA_JSON="$(build_data)"

# Escape closing script tag in case any JSON contains it (defensive).
DATA_JSON="${DATA_JSON//<\/script>/<\\/script>}"

TEMPLATE="$REPO_DIR/scripts/report-template.html"
if [ ! -f "$TEMPLATE" ]; then
  echo "build-report: template not found at $TEMPLATE" >&2
  exit 1
fi

# Inject the data blob at the marker. With many scenarios the JSON can
# exceed argv size limits (~256 KB on macOS), so stage it in a temp file
# and pass only the path to python.
DATA_FILE="$(mktemp -t report-data.json.XXXXXX)"
trap 'rm -f "$DATA_FILE"' EXIT
printf '%s' "$DATA_JSON" > "$DATA_FILE"

python3 - "$TEMPLATE" "$OUTPUT_HTML" "$DATA_FILE" <<'PY'
import sys, pathlib
tmpl_path, out_path, data_path = sys.argv[1], sys.argv[2], sys.argv[3]
tmpl = pathlib.Path(tmpl_path).read_text()
data = pathlib.Path(data_path).read_text()
marker = "/*__REPORT_DATA__*/null"
if marker not in tmpl:
    sys.exit(f"marker {marker!r} not found in template")
out = tmpl.replace(marker, data)
pathlib.Path(out_path).write_text(out)
print(f"wrote {out_path} ({len(out):,} bytes)")
PY
