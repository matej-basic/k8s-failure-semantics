#!/usr/bin/env bash
# scripts/preflight.sh
# Read-only pre-deployment check for the k8s-failure-semantics lab.
#
# Verifies, without changing anything:
#   1. Required tools are on PATH
#   2. vCenter/ESXi DNS resolves and TCP 443 answers
#   3. vCenter credentials in terraform/terraform.tfvars authenticate
#   4. Terraform is initialised and a refresh-only plan succeeds
#   5. All 11 VMs + the API VIP respond on the network
#   6. SSH as the ansible user works on every node
#
# Writes results/preflight-report.txt. Nothing is provisioned or modified.
# The vCenter password is never printed.
#
# Usage: scripts/preflight.sh

set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"

REPORT="$REPO_DIR/results/preflight-report.txt"
mkdir -p "$(dirname "$REPORT")"
: > "$REPORT"

log() { echo "$*" | tee -a "$REPORT"; }
sec() { log ""; log "── $* ─────────────────────────────────────────"; }
ok()   { log "  [ OK ] $*"; }
bad()  { log "  [FAIL] $*"; }
warn() { log "  [WARN] $*"; }

log "preflight — $(date '+%Y-%m-%d %H:%M:%S %Z')"
log "repo: $REPO_DIR"
log "host: $(hostname) / $(uname -srm)"

# ── 1. tools ──────────────────────────────────────────────────────────────────
sec "1. Tooling"
for t in terraform ansible ansible-playbook kubectl ssh jq curl python3; do
  if command -v "$t" >/dev/null 2>&1; then
    ver=$("$t" --version 2>/dev/null | head -1)
    ok "$(printf '%-17s' "$t") ${ver:-present}"
  else
    if [ "$t" = kubectl ]; then warn "$t missing (only needed after the cluster is up)"
    else bad "$t missing"; fi
  fi
done

# ── 2. tfvars ─────────────────────────────────────────────────────────────────
sec "2. terraform.tfvars"
TFVARS="$REPO_DIR/terraform/terraform.tfvars"
if [ ! -f "$TFVARS" ]; then
  bad "terraform/terraform.tfvars not found — copy terraform.tfvars.example"
  log ""; log "preflight aborted."; exit 1
fi
tfvar() { grep -E "^\s*$1\s*=" "$TFVARS" | head -1 | sed -E 's/^[^=]*=\s*"?([^"]*)"?\s*$/\1/'; }
VC_HOST=$(tfvar vcenter_server)
VC_USER=$(tfvar vcenter_user)
VC_PASS=$(tfvar vcenter_password)
ESXI_HOST=$(tfvar esxi_host)
SSH_KEY=$(tfvar ansible_ssh_private_key_file)
SSH_USER=$(tfvar ansible_user)
ok "vcenter_server = $VC_HOST"
ok "vcenter_user   = $VC_USER"
ok "esxi_host      = $ESXI_HOST"
[ -n "$VC_PASS" ] && ok "vcenter_password set (${#VC_PASS} chars)" || bad "vcenter_password empty"

# ── 3. vCenter reachability + auth ────────────────────────────────────────────
sec "3. vCenter"
VC_REACHABLE=0
for h in "$VC_HOST" "$ESXI_HOST"; do
  ip=$(python3 -c "import socket,sys;print(socket.gethostbyname('$h'))" 2>/dev/null)
  if [ -n "$ip" ]; then ok "DNS  $h -> $ip"
  else bad "DNS  $h does not resolve"; continue; fi
  if python3 -c "
import socket,sys
s=socket.socket(); s.settimeout(5)
sys.exit(0 if s.connect_ex(('$h',443))==0 else 1)" 2>/dev/null; then
    ok "TCP  $h:443 open"
    [ "$h" = "$VC_HOST" ] && VC_REACHABLE=1
  else
    bad "TCP  $h:443 unreachable"
  fi
done

if [ "$VC_REACHABLE" = 1 ]; then
  code=$(curl -sk -o /tmp/.pf_sess -w '%{http_code}' -m 20 \
         -u "$VC_USER:$VC_PASS" -X POST "https://$VC_HOST/api/session" 2>/dev/null)
  case "$code" in
    200|201) ok "AUTH vCenter accepted $VC_USER"
             tok=$(sed 's/"//g' /tmp/.pf_sess 2>/dev/null)
             if [ -n "$tok" ]; then
               vms=$(curl -sk -m 20 -H "vmware-api-session-id: $tok" \
                     "https://$VC_HOST/api/vcenter/vm" 2>/dev/null \
                     | jq -r '[.[]|select(.name|test("^(cp|worker|etcd)[0-9]"))]|length' 2>/dev/null)
               [ -n "$vms" ] && ok "API  $vms lab VMs visible in inventory (expect 11)"
               curl -sk -m 10 -H "vmware-api-session-id: $tok" \
                    -X DELETE "https://$VC_HOST/api/session" >/dev/null 2>&1
             fi ;;
    401)     bad "AUTH vCenter rejected credentials (401)" ;;
    000)     bad "AUTH no response from $VC_HOST" ;;
    *)       bad "AUTH unexpected HTTP $code from $VC_HOST" ;;
  esac
  rm -f /tmp/.pf_sess
else
  warn "skipping vCenter auth — host unreachable"
fi

# ── 4. terraform ──────────────────────────────────────────────────────────────
sec "4. Terraform (read-only)"
if command -v terraform >/dev/null 2>&1; then
  if [ -d terraform/.terraform ]; then ok "terraform/.terraform present (initialised)"
  else warn "not initialised — 'terraform -chdir=terraform init' needed"; fi
  log "  running: terraform -chdir=terraform plan -refresh-only -input=false"
  if terraform -chdir=terraform plan -refresh-only -input=false -no-color \
       > /tmp/.pf_plan 2>&1; then
    ok "refresh-only plan succeeded"
    log "  ── plan tail ──"
    tail -25 /tmp/.pf_plan | sed 's/^/    /' | tee -a "$REPORT" >/dev/null
    tail -25 /tmp/.pf_plan | sed 's/^/    /'
  else
    bad "refresh-only plan failed"
    log "  ── error tail ──"
    tail -30 /tmp/.pf_plan | sed 's/^/    /' | tee -a "$REPORT" >/dev/null
    tail -30 /tmp/.pf_plan | sed 's/^/    /'
  fi
  rm -f /tmp/.pf_plan
else
  bad "terraform not on PATH — skipping"
fi

# ── 5. node reachability ──────────────────────────────────────────────────────
sec "5. Nodes"
KEY_EXPANDED="${SSH_KEY/#\~/$HOME}"
[ -f "$KEY_EXPANDED" ] && ok "ssh key $SSH_KEY present" || bad "ssh key $SSH_KEY missing"

check_node() {
  local name=$1 ip=$2 port=$3
  if python3 -c "
import socket,sys
s=socket.socket(); s.settimeout(3)
sys.exit(0 if s.connect_ex(('$ip',$port))==0 else 1)" 2>/dev/null; then
    if [ "$port" = 22 ] && [ -f "$KEY_EXPANDED" ]; then
      if ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
             -i "$KEY_EXPANDED" "$SSH_USER@$ip" true 2>/dev/null; then
        ok "$(printf '%-9s %-12s' "$name" "$ip") ssh ok"
      else
        warn "$(printf '%-9s %-12s' "$name" "$ip") port 22 open, ssh auth failed"
      fi
    else
      ok "$(printf '%-9s %-12s' "$name" "$ip") port $port open"
    fi
  else
    bad "$(printf '%-9s %-12s' "$name" "$ip") port $port unreachable"
  fi
}

while read -r name ip; do
  [ -z "$name" ] && continue
  check_node "$name" "$ip" 22
done <<'NODES'
cp1 10.0.0.49
cp2 10.0.0.51
cp3 10.0.0.52
worker1 10.0.0.53
worker2 10.0.0.54
worker3 10.0.0.55
etcd1 10.0.0.56
etcd2 10.0.0.57
etcd3 10.0.0.58
etcd4 10.0.0.60
etcd5 10.0.0.61
NODES
check_node "API VIP" 10.0.0.59 6443

sec "Done"
log "Full report: results/preflight-report.txt"
