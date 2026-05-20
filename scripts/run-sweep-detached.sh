#!/bin/bash
# scripts/run-sweep-detached.sh
#
# Run the scenario sweep fully detached from the calling shell.
# Reason: the harness/shell that launches a long ansible-playbook run can be
# subject to wall-clock kill windows (CI, Claude Code's background-task
# timeout, terminal hangup, etc.). Plain `nohup … &` is not always enough;
# this script also redirects stdin from /dev/null and `disown`s the child
# so SIGHUP/SIGTERM never propagate.
#
# Usage:
#   scripts/run-sweep-detached.sh [RUN_ID] [LOG_PATH] [ANSIBLE_TAGS]
# Defaults:
#   RUN_ID = $(date +%Y%m%d_%H%M%S)
#   LOG_PATH = /tmp/sweep-<RUN_ID>.log
#   ANSIBLE_TAGS = '' (run every tag)
#
# Examples:
#   scripts/run-sweep-detached.sh
#   scripts/run-sweep-detached.sh 20260520_181609 /tmp/sweep.log \
#       's1,s2,s11'
#
# Watch progress with: tail -F <LOG_PATH>

set -u
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_DIR"

RUN_ID="${1:-$(date +%Y%m%d_%H%M%S)}"
LOG="${2:-/tmp/sweep-${RUN_ID}.log}"
TAGS="${3:-}"

TAG_ARGS=()
if [ -n "$TAGS" ]; then
  TAG_ARGS=(--tags "$TAGS")
fi

nohup ansible-playbook \
  -i inventory/hosts.ini playbooks/run-all-scenarios.yml \
  "${TAG_ARGS[@]}" \
  -e "results_base=$REPO_DIR/results" \
  -e "run_id=$RUN_ID" \
  > "$LOG" 2>&1 < /dev/null &

ANSIBLE_PID=$!
disown "$ANSIBLE_PID" 2>/dev/null || true

# Let ansible take its first breath before we declare success.
sleep 2

if kill -0 "$ANSIBLE_PID" 2>/dev/null; then
  echo "ansible_pid=$ANSIBLE_PID run_id=$RUN_ID log=$LOG tags=${TAGS:-all}"
  exit 0
else
  echo "ansible-playbook died before settling — last 20 log lines:" >&2
  tail -n 20 "$LOG" >&2
  exit 1
fi
