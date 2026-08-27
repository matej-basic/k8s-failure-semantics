#!/usr/bin/env bash
# scripts/revert-baseline.sh
# Roll every lab VM back to the baseline snapshot taken by
# scripts/snapshot-baseline.sh, then bring the cluster back up.
#
# This is the inter-scenario reset: it restores an identical starting state
# instead of trying to undo a fault, so no scenario can inherit residue from
# the one before it (leftover iptables/tc rules, a drifted etcd, a workload
# still mid-reschedule). That is a stronger guarantee than the fault-teardown
# sweep in playbooks/_health-check.yml, which can only remove what it knows
# about.
#
# DESTRUCTIVE: every change made since the snapshot is discarded on all VMs,
# including any results still living on the nodes. Copy anything you want to
# keep out of /opt/k8s-results first — scripts/aggregate-results.sh pulls
# results back to the control machine.
#
# Power-on order is etcd -> control plane -> workers, so the datastore has
# quorum before any API server starts looking for it.
#
# Usage:
#   scripts/revert-baseline.sh            # prompts before reverting
#   scripts/revert-baseline.sh --yes      # no prompt (for use inside a sweep)
#   scripts/revert-baseline.sh -n NAME    # revert to a named snapshot
#   scripts/revert-baseline.sh --no-wait  # revert + power on, skip health wait
#
# The vCenter password is read from terraform/terraform.tfvars and never printed.

set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"

SNAP_NAME="baseline"
ASSUME_YES=0
WAIT_HEALTHY=1

while [ $# -gt 0 ]; do
  case "$1" in
    -n|--name) SNAP_NAME="${2:?-n needs a value}"; shift 2 ;;
    -y|--yes)  ASSUME_YES=1; shift ;;
    --no-wait) WAIT_HEALTHY=0; shift ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

log()  { echo "$*"; }
sec()  { log ""; log "── $* ─────────────────────────────────────────"; }
ok()   { log "  [ OK ] $*"; }
bad()  { log "  [FAIL] $*"; }
warn() { log "  [WARN] $*"; }
die()  { bad "$*"; exit 1; }

# ── vCenter credentials ───────────────────────────────────────────────────────
TFVARS="$REPO_DIR/terraform/terraform.tfvars"
[ -f "$TFVARS" ] || die "terraform/terraform.tfvars not found"
# NB: awk, not `sed -E 's/\s*//'` — BSD sed on macOS does not understand \s,
# and silently returns the whole line instead of the value.
tfvar() {
  awk -v k="$1" '
    $0 ~ "^[[:space:]]*"k"[[:space:]]*=" {
      sub(/^[^=]*=[[:space:]]*/, "")
      sub(/[[:space:]]*$/, "")
      gsub(/^"|"$/, "")
      print; exit
    }' "$TFVARS"
}

GOVC_URL="$(tfvar vcenter_server)"
GOVC_USERNAME="$(tfvar vcenter_user)"
GOVC_PASSWORD="$(tfvar vcenter_password)"
GOVC_DATACENTER="$(tfvar datacenter)"
GOVC_INSECURE=true
VM_FOLDER="$(tfvar vm_folder)"
export GOVC_URL GOVC_USERNAME GOVC_PASSWORD GOVC_DATACENTER GOVC_INSECURE
[ -n "$GOVC_PASSWORD" ] || die "vcenter_password is empty in terraform.tfvars"

command -v govc >/dev/null 2>&1 || die "govc not on PATH"

# Fail loudly here rather than letting every later govc call fail silently.
govc about >/dev/null 2>&1 || die "cannot reach or authenticate to vCenter at $GOVC_URL"

INVENTORY="$REPO_DIR/inventory/hosts.ini"
[ -f "$INVENTORY" ] || die "inventory/hosts.ini not found"

# Read loop rather than `mapfile`: macOS ships bash 3.2, which has neither
# mapfile nor readarray.
VMS=()
while IFS= read -r h; do VMS+=("$h"); done < <(
  awk '/^[a-z0-9_-]+ +ansible_host=/{print $1}' "$INVENTORY"
)
[ "${#VMS[@]}" -gt 0 ] || die "no hosts with ansible_host= found in $INVENTORY"

vm_ip()   { awk -v h="$1" '$1==h{sub(/.*ansible_host=/,""); print $1}' "$INVENTORY"; }
vm_path() { echo "$VM_FOLDER/$1"; }

log "revert-baseline — $(date '+%Y-%m-%d %H:%M:%S %Z')"
log "vCenter: $GOVC_URL   folder: $VM_FOLDER   snapshot: $SNAP_NAME"

# ── 1. Every VM must actually have the snapshot ───────────────────────────────
# Checked up-front: a partial revert would leave the fleet split across two
# points in time, which is worse than not reverting at all.
sec "1. Checking '$SNAP_NAME' exists on all ${#VMS[@]} VMs"
missing=()
for vm in "${VMS[@]}"; do
  if govc snapshot.tree -vm "$(vm_path "$vm")" 2>/dev/null | grep -qx "$SNAP_NAME"; then
    ok "$vm"
  else
    bad "$vm — no snapshot named '$SNAP_NAME'"; missing+=("$vm")
  fi
done
[ "${#missing[@]}" -eq 0 ] || die "${#missing[@]} VM(s) missing the snapshot: ${missing[*]}
       refusing to revert — a partial rollback splits the fleet across two states"

# ── 2. Confirm ────────────────────────────────────────────────────────────────
if [ "$ASSUME_YES" != 1 ]; then
  log ""
  log "  About to revert ${#VMS[@]} VMs to '$SNAP_NAME'."
  log "  ALL changes on those VMs since the snapshot will be lost."
  printf '  Type "revert" to continue: '
  read -r reply
  [ "$reply" = "revert" ] || die "aborted"
fi

# ── 3. Revert ─────────────────────────────────────────────────────────────────
# snapshot.revert leaves the VM in the power state the snapshot recorded, and
# the baseline is taken cold — so every VM lands powered off and is started
# again below, in dependency order.
sec "2. Reverting"
for vm in "${VMS[@]}"; do
  if govc snapshot.revert -vm "$(vm_path "$vm")" "$SNAP_NAME" >/dev/null 2>&1; then
    ok "$vm — reverted"
  else
    die "$vm — revert FAILED; the fleet is now partially reverted, fix by hand"
  fi
done

# ── 4. Power on: etcd -> control plane -> workers ─────────────────────────────
sec "3. Powering on (etcd -> control plane -> workers)"
start_group() {
  local prefix="$1"
  for vm in "${VMS[@]}"; do
    case "$vm" in
      "$prefix"*)
        state="$(govc vm.info "$(vm_path "$vm")" 2>/dev/null | sed -n 's/^ *Power state: *//p')"
        if [ "$state" = "poweredOn" ]; then ok "$vm already on"; else
          govc vm.power -on "$(vm_path "$vm")" >/dev/null 2>&1 \
            && ok "$vm — powering on" || warn "$vm — power-on request failed"
        fi
        ;;
    esac
  done
  return 0
}

wait_ssh() {
  local -a group=("$@")
  local deadline=$((SECONDS + 600))
  local pending=("${group[@]}")
  while [ $SECONDS -lt $deadline ]; do
    pending=()
    for vm in "${group[@]}"; do
      nc -z -G 3 -w 3 "$(vm_ip "$vm")" 22 >/dev/null 2>&1 || pending+=("$vm")
    done
    [ "${#pending[@]}" -eq 0 ] && return 0
    sleep 10
  done
  warn "still unreachable after 10 min: ${pending[*]}"
  return 1
}

group_members() {
  local prefix="$1"
  for vm in "${VMS[@]}"; do case "$vm" in "$prefix"*) echo "$vm" ;; esac; done
}

for prefix in etcd cp worker; do
  group=()
  while IFS= read -r h; do group+=("$h"); done < <(group_members "$prefix")
  [ "${#group[@]}" -eq 0 ] && continue
  start_group "$prefix"
  log "  waiting for SSH on: ${group[*]}"
  wait_ssh "${group[@]}" && ok "$prefix group up" || warn "$prefix group incomplete"
done

# ── 5. Wait for the cluster to come back ──────────────────────────────────────
if [ "$WAIT_HEALTHY" != 1 ]; then
  sec "Done (--no-wait)"
  log "VMs reverted and powered on; cluster health not checked."
  exit 0
fi

sec "4. Waiting for the cluster to become Ready"
CP1="$(vm_ip cp1)"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o LogLevel=ERROR -o ConnectTimeout=10 -i "$HOME/.ssh/id_rsa")

deadline=$((SECONDS + 600))
ready=0
while [ $SECONDS -lt $deadline ]; do
  not_ready="$(ssh "${SSH_OPTS[@]}" "ansible@$CP1" \
    'sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl get nodes --no-headers 2>/dev/null | grep -cv " Ready"' 2>/dev/null)"
  case "${not_ready:-}" in
    0) ready=1; break ;;
  esac
  sleep 15
done

if [ "$ready" = 1 ]; then
  ok "all nodes Ready"
  ssh "${SSH_OPTS[@]}" "ansible@$CP1" \
    'sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl get nodes' 2>/dev/null | sed 's/^/      /'
else
  warn "nodes did not all become Ready within 10 min — inspect the cluster before running a scenario"
  exit 1
fi

sec "Done"
log "Fleet restored to '$SNAP_NAME'. Safe to run the next scenario."
