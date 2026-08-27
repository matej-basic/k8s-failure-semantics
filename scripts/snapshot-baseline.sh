#!/usr/bin/env bash
# scripts/snapshot-baseline.sh
# Take a cold baseline snapshot of all 11 lab VMs, so a scenario run can be
# rolled back to an identical starting state with scripts/revert-baseline.sh.
#
# Why the VMs are powered off first
# ---------------------------------
# vCenter has no cross-VM consistency group: each VM's snapshot is its own
# point in time. Snapshotting 11 running VMs therefore captures 11 slightly
# different instants, and a 5-member etcd cluster restored that way can come
# back with members at different raft log positions — a subtly inconsistent
# baseline that every later scenario would silently inherit. A cold snapshot
# has no such skew, and it also avoids the clock problem: a memory snapshot
# resumes with a stale clock, and Kubernetes is unforgiving about time skew
# (certificate validity, etcd leases, the controller-manager lease).
#
# The sequence is: health-gate -> guest shutdown -> snapshot -> power on ->
# wait for SSH -> health-check again. Snapshotting a broken cluster just
# enshrines the breakage, so the run refuses to start unless the cluster is
# healthy (override with --skip-health).
#
# Usage:
#   scripts/snapshot-baseline.sh                  # snapshot as "baseline"
#   scripts/snapshot-baseline.sh -n post-install  # custom snapshot name
#   scripts/snapshot-baseline.sh --replace        # delete an existing one first
#   scripts/snapshot-baseline.sh --skip-health    # skip the pre-flight gate
#   scripts/snapshot-baseline.sh --list           # show existing snapshots
#   scripts/snapshot-baseline.sh --delete -n NAME # delete a snapshot everywhere
#
# The vCenter password is read from terraform/terraform.tfvars and never printed.

set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"

SNAP_NAME="baseline"
DO_REPLACE=0
SKIP_HEALTH=0
MODE="create"

while [ $# -gt 0 ]; do
  case "$1" in
    -n|--name)     SNAP_NAME="${2:?-n needs a value}"; shift 2 ;;
    --replace)     DO_REPLACE=1; shift ;;
    --skip-health) SKIP_HEALTH=1; shift ;;
    --list)        MODE="list"; shift ;;
    --delete)      MODE="delete"; shift ;;
    -h|--help)     sed -n '2,30p' "$0"; exit 0 ;;
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

# ── Hosts come from the generated inventory, so this follows the topology ─────
# Every cluster VM is an `ansible_host=` line; the observer (localhost) is not.
INVENTORY="$REPO_DIR/inventory/hosts.ini"
[ -f "$INVENTORY" ] || die "inventory/hosts.ini not found — run terraform apply first"
# NB: read loop rather than `mapfile` — macOS ships bash 3.2, which has no
# mapfile/readarray, and this script must run on the control machine as-is.
VMS=()
while IFS= read -r h; do VMS+=("$h"); done < <(
  awk '/^[a-z0-9_-]+ +ansible_host=/{print $1}' "$INVENTORY"
)
[ "${#VMS[@]}" -gt 0 ] || die "no hosts with ansible_host= found in $INVENTORY"

ETCD_COUNT=0
for _h in "${VMS[@]}"; do case "$_h" in etcd*) ETCD_COUNT=$((ETCD_COUNT+1)) ;; esac; done

vm_ip() { awk -v h="$1" '$1==h{sub(/.*ansible_host=/,""); print $1}' "$INVENTORY"; }
vm_path() { echo "$VM_FOLDER/$1"; }
power_state() { govc vm.info "$(vm_path "$1")" 2>/dev/null | sed -n 's/^ *Power state: *//p'; }

log "snapshot-baseline — $(date '+%Y-%m-%d %H:%M:%S %Z')"
log "vCenter: $GOVC_URL   folder: $VM_FOLDER   snapshot: $SNAP_NAME"
log "VMs (${#VMS[@]}): ${VMS[*]}"

# ── --list / --delete short-circuit before anything is changed ────────────────
if [ "$MODE" = "list" ]; then
  sec "Existing snapshots"
  for vm in "${VMS[@]}"; do
    out="$(govc snapshot.tree -vm "$(vm_path "$vm")" -f -D 2>/dev/null | sed 's/^/      /')"
    log "  $vm:"; [ -n "$out" ] && log "$out" || log "      (none)"
  done
  exit 0
fi

if [ "$MODE" = "delete" ]; then
  sec "Deleting snapshot '$SNAP_NAME' from ${#VMS[@]} VMs"
  rc=0
  for vm in "${VMS[@]}"; do
    if govc snapshot.remove -vm "$(vm_path "$vm")" "$SNAP_NAME" >/dev/null 2>&1; then
      ok "$vm — removed"
    else
      warn "$vm — no snapshot named '$SNAP_NAME' (or removal failed)"; rc=1
    fi
  done
  exit $rc
fi

# ── 1. Health gate — never snapshot a broken cluster ──────────────────────────
CP1="$(vm_ip cp1)"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o LogLevel=ERROR -o ConnectTimeout=10 -i "$HOME/.ssh/id_rsa")

if [ "$SKIP_HEALTH" = 1 ]; then
  sec "1. Health gate — SKIPPED (--skip-health)"
else
  sec "1. Health gate"
  for vm in "${VMS[@]}"; do
    ip="$(vm_ip "$vm")"
    ssh "${SSH_OPTS[@]}" "ansible@$ip" true >/dev/null 2>&1 \
      && ok "$(printf '%-8s %-11s' "$vm" "$ip") SSH" \
      || die "$vm ($ip) unreachable over SSH — refusing to snapshot"
  done

  not_ready="$(ssh "${SSH_OPTS[@]}" "ansible@$CP1" \
    'sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl get nodes --no-headers 2>/dev/null | grep -cv " Ready"')"
  [ "${not_ready:-1}" = 0 ] || die "not every node is Ready (${not_ready:-?} not ready) — refusing to snapshot"
  ok "all nodes Ready"

  ETCD_ENDPOINTS="$(awk '/^etcd_endpoints=/{sub(/^etcd_endpoints=/,""); print; exit}' "$INVENTORY")"
  [ -n "$ETCD_ENDPOINTS" ] || die "etcd_endpoints not found in $INVENTORY"
  etcd_ok="$(ssh "${SSH_OPTS[@]}" "ansible@$(vm_ip etcd1)" \
    "sudo ETCDCTL_API=3 etcdctl --endpoints='$ETCD_ENDPOINTS' \
       --cacert=/etc/etcd/pki/ca.crt --cert=/etc/etcd/pki/server.crt \
       --key=/etc/etcd/pki/server.key \
       endpoint health --write-out=json 2>/dev/null \
       | jq '[.[]|select(.health==true)]|length'" 2>/dev/null)"
  case "${etcd_ok:-}" in
    ''|*[!0-9]*) die "could not read etcd health from etcd1 — refusing to snapshot" ;;
  esac
  [ "$etcd_ok" -eq "$ETCD_COUNT" ] \
    || die "etcd reports $etcd_ok/$ETCD_COUNT healthy members — refusing to snapshot"
  ok "etcd $etcd_ok/$ETCD_COUNT members healthy"
fi

# ── 2. Existing snapshots ─────────────────────────────────────────────────────
sec "2. Existing '$SNAP_NAME' snapshots"
existing=()
for vm in "${VMS[@]}"; do
  if govc snapshot.tree -vm "$(vm_path "$vm")" 2>/dev/null | grep -qx "$SNAP_NAME"; then
    existing+=("$vm")
  fi
done
if [ "${#existing[@]}" -gt 0 ]; then
  if [ "$DO_REPLACE" = 1 ]; then
    for vm in "${existing[@]}"; do
      govc snapshot.remove -vm "$(vm_path "$vm")" "$SNAP_NAME" >/dev/null 2>&1 \
        && ok "$vm — old snapshot removed" || warn "$vm — could not remove old snapshot"
    done
  else
    die "${#existing[@]} VM(s) already have a snapshot named '$SNAP_NAME': ${existing[*]}
       re-run with --replace to overwrite, or -n NAME to use a different name"
  fi
else
  ok "none — clean"
fi

# ── 3. Guest shutdown ─────────────────────────────────────────────────────────
# Workers and control plane first, etcd last: the k8s layer goes quiet before
# the datastore it depends on.
sec "3. Powering off (guest shutdown via VMware Tools)"
ORDER_DOWN=(); for p in worker cp etcd; do
  for vm in "${VMS[@]}"; do [[ "$vm" == $p* ]] && ORDER_DOWN+=("$vm"); done
done

for vm in "${ORDER_DOWN[@]}"; do
  state="$(power_state "$vm")"
  if [ "$state" = "poweredOff" ]; then ok "$vm already off"; continue; fi
  govc vm.power -s "$(vm_path "$vm")" >/dev/null 2>&1 || warn "$vm — shutdown request failed"
done

log "  waiting for all VMs to reach poweredOff (up to 5 min)..."
still_on=("${VMS[@]}")   # declared up-front: `set -u` would abort on an unset array
deadline=$((SECONDS + 300))
while [ $SECONDS -lt $deadline ]; do
  still_on=()
  for vm in "${VMS[@]}"; do
    [ "$(power_state "$vm")" = "poweredOff" ] || still_on+=("$vm")
  done
  [ "${#still_on[@]}" -eq 0 ] && break
  sleep 10
done

if [ "${#still_on[@]}" -gt 0 ]; then
  warn "${#still_on[@]} VM(s) did not shut down cleanly: ${still_on[*]}"
  warn "forcing power off — a forced stop risks an unclean filesystem in the snapshot"
  for vm in "${still_on[@]}"; do
    govc vm.power -off -force "$(vm_path "$vm")" >/dev/null 2>&1 \
      && warn "$vm — forced off" || die "$vm — could not power off"
  done
fi
ok "all ${#VMS[@]} VMs powered off"

# ── 4. Snapshot ───────────────────────────────────────────────────────────────
sec "4. Creating snapshot '$SNAP_NAME'"
DESC="k8s-failure-semantics baseline, cold, taken $(date '+%Y-%m-%d %H:%M:%S %Z')"
for vm in "${VMS[@]}"; do
  # -m=false: no memory state (the VM is off, so there is none to capture).
  if govc snapshot.create -vm "$(vm_path "$vm")" -d "$DESC" -m=false "$SNAP_NAME" >/dev/null 2>&1; then
    ok "$vm — snapshot created"
  else
    die "$vm — snapshot FAILED; the fleet is powered off and partially snapshotted"
  fi
done

# ── 5. Power back on ──────────────────────────────────────────────────────────
# Reverse of the shutdown order: etcd must have quorum before the API servers
# start looking for it.
sec "5. Powering on (etcd -> control plane -> workers)"
ORDER_UP=(); for p in etcd cp worker; do
  for vm in "${VMS[@]}"; do [[ "$vm" == $p* ]] && ORDER_UP+=("$vm"); done
done

for vm in "${ORDER_UP[@]}"; do
  govc vm.power -on "$(vm_path "$vm")" >/dev/null 2>&1 && ok "$vm — powering on" \
    || warn "$vm — power-on request failed"
done

log "  waiting for SSH on all ${#VMS[@]} VMs (up to 10 min)..."
down=("${VMS[@]}")
deadline=$((SECONDS + 600))
while [ $SECONDS -lt $deadline ]; do
  down=()
  for vm in "${VMS[@]}"; do
    nc -z -G 3 -w 3 "$(vm_ip "$vm")" 22 >/dev/null 2>&1 || down+=("$vm")
  done
  [ "${#down[@]}" -eq 0 ] && break
  sleep 10
done
[ "${#down[@]}" -eq 0 ] || die "still unreachable after 10 min: ${down[*]}"
ok "all ${#VMS[@]} VMs answering on port 22"

# ── 6. Post-snapshot health ───────────────────────────────────────────────────
sec "6. Cluster health after power-on"
log "  giving the control plane 60s to settle..."
sleep 60
ssh "${SSH_OPTS[@]}" "ansible@$CP1" \
  'sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl get nodes' 2>/dev/null | sed 's/^/      /' \
  || warn "could not read node list — check the cluster by hand"

sec "Done"
log "Baseline snapshot '$SNAP_NAME' taken on ${#VMS[@]} VMs."
log "Roll back to it with: scripts/revert-baseline.sh -n $SNAP_NAME"
