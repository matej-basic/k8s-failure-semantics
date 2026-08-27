#!/usr/bin/env bash
#
# prepare-template.sh — turn the freshly installed VM into a clonable
# vSphere template.
#
# Runs as root (Packer's execute_command wraps it in sudo) as the last step
# before shutdown + convert_to_template.
#
# The one decision this whole file turns on: cloud-init STAYS, and it is the
# component that consumes VMware Guest OS Customization. See packer/README.md
# ("cloud-init vs open-vm-tools").
#
set -euxo pipefail

# ---------------------------------------------------------------------------
# 0. Sanity checks — fail the build here rather than three Terraform applies
#    later.
# ---------------------------------------------------------------------------
test -x /usr/bin/python3          # ansible.cfg: interpreter_python=/usr/bin/python3
test -x /usr/bin/perl             # open-vm-tools deployPkg customization
test -x /usr/bin/vmtoolsd         # open-vm-tools
command -v growpart >/dev/null    # grows root when a clone gets a bigger disk

# `is-enabled` reports several flavours of "will start at boot" depending on
# how the unit is wired (Ubuntu has moved ssh between service and socket
# activation across releases), so accept all of them and fail only on
# disabled/masked.
for unit in ssh.service open-vm-tools.service; do
  state="$(systemctl is-enabled "$unit" 2>/dev/null || true)"
  case "$state" in
    enabled|enabled-runtime|alias|static|indirect|generated)
      echo "ok: $unit is $state" ;;
    *)
      echo "FATAL: $unit is '$state' — clones would boot without it" >&2
      exit 1 ;;
  esac
done

# ---------------------------------------------------------------------------
# 1. Hand VMware Guest OS Customization to cloud-init.
#
#    Ubuntu's installer leaves cloud-init wired for a one-shot install: it
#    pins the datasource list to NoCloud and disables cloud-init networking
#    outright. Both of those silently defeat the customization spec that
#    Terraform's clone{ customize{ ... } } block sends, so they go away.
# ---------------------------------------------------------------------------
rm -f /etc/cloud/cloud.cfg.d/90_dpkg.cfg \
      /etc/cloud/cloud.cfg.d/99-installer.cfg \
      /etc/cloud/cloud.cfg.d/subiquity-disable-cloudinit-networking.cfg

cat > /etc/cloud/cloud.cfg.d/99-vsphere-gosc.cfg <<'EOF'
# Written by packer/provision/prepare-template.sh.
#
# OVF is the datasource that reads the vmware-imc customization spec that
# open-vm-tools' deployPkg plugin drops in /var/run/vmware-imc when vCenter
# customizes a clone. VMware is the guestinfo-based datasource, kept as a
# fallback. NoCloud is deliberately absent: the build-time seed CD is removed
# by the builder, and we never want a stray labelled volume to re-seed a node.
datasource_list: [ OVF, VMware, None ]

# The single most important line in this image. Ubuntu ships this as `true`,
# which tells cloud-init to keep its hands off VMware customization and let
# open-vm-tools' legacy perl path do it. On 24.04 that path does not render
# netplan correctly and the clone comes up with no address at all.
disable_vmware_customization: false

# Preserve the hostname the customization spec sets; do not let a later boot
# reset it from the datasource's idea of a default.
preserve_hostname: false
manage_etc_hosts: true
EOF

# Belt and braces: the same switch inside the main config file, in case a
# future image ships it there with a different default.
if grep -q '^disable_vmware_customization:' /etc/cloud/cloud.cfg; then
  sed -i 's/^disable_vmware_customization:.*/disable_vmware_customization: false/' /etc/cloud/cloud.cfg
else
  printf '\ndisable_vmware_customization: false\n' >> /etc/cloud/cloud.cfg
fi

# ---------------------------------------------------------------------------
# 2. Remove every trace of the build-time network configuration.
#
#    Leaving the installer's /etc/netplan/*.yaml in place is the classic way
#    to get a cloned VM that ignores its static address: netplan merges files
#    by name and an installer file can outrank, duplicate or contradict the
#    50-cloud-init.yaml that cloud-init writes from the customization spec.
#
#    With the directory empty, exactly one of two things happens on a clone:
#      * customization spec present -> cloud-init writes the static config;
#      * no spec (manual clone)     -> cloud-init's fallback config gives the
#                                      first NIC DHCP, so the VM is reachable.
# ---------------------------------------------------------------------------
rm -f /etc/netplan/*.yaml /etc/netplan/*.yml
rm -f /etc/udev/rules.d/70-persistent-net.rules \
      /etc/udev/rules.d/80-net-setup-link.rules
rm -f /etc/NetworkManager/system-connections/* 2>/dev/null || true

# ---------------------------------------------------------------------------
# 3. Identity that must NOT be shared between clones.
# ---------------------------------------------------------------------------

# systemd regenerates a machine-id at boot when the file exists but is empty.
# Deleting the file instead can leave a read-only /etc/machine-id bind mount.
truncate -s 0 /etc/machine-id
rm -f /var/lib/dbus/machine-id
ln -s /etc/machine-id /var/lib/dbus/machine-id

# cloud-init's `ssh` module regenerates any missing host key on first boot.
rm -f /etc/ssh/ssh_host_*

# Host keys MUST exist before anything can start sshd. cloud-init's `ssh`
# module also generates them, but it runs far too late to be relied on: on
# the first fleet built from this template cloud-init wrote the keys at
# 18:13:41.136 and sshd began listening at 18:13:41.626 — a 490 ms margin.
# Four of eleven clones lost that race, came up with
# "sshd: no hostkeys available -- exiting", hit the systemd start limit and
# never retried, leaving connection-refused on port 22.
#
# The wiring below is load-bearing and easy to get wrong. An earlier version
# of this unit used `Before=ssh.service ssh.socket` with
# `WantedBy=multi-user.target`. That is an ordering CYCLE — multi-user.target
# is ordered after sockets.target, which is ordered after ssh.socket — and
# systemd resolves it by deleting the job outright:
#
#   ssh.socket: Found ordering cycle on regenerate-ssh-host-keys.service/start
#   ssh.socket: Job regenerate-ssh-host-keys.service/start deleted to break
#               ordering cycle starting with ssh.socket/start
#
# so the unit silently never ran on any node. DefaultDependencies=no plus
# WantedBy=sysinit.target puts key generation before sockets.target is even
# reached, which is early enough to close the race and cycle-free.
#
# Do not "simplify" this back to multi-user.target.
cat > /etc/systemd/system/regenerate-ssh-host-keys.service <<'EOF'
[Unit]
Description=Regenerate missing SSH host keys on first boot
DefaultDependencies=no
After=systemd-remount-fs.service local-fs.target
Before=sysinit.target shutdown.target sockets.target ssh.socket ssh.service
Conflicts=shutdown.target
ConditionPathExists=!/etc/ssh/ssh_host_ed25519_key

[Service]
Type=oneshot
ExecStart=/usr/bin/ssh-keygen -A
RemainAfterExit=yes

[Install]
WantedBy=sysinit.target
EOF
systemctl enable regenerate-ssh-host-keys.service

# Belt and braces, independent of the unit above: generate the keys from
# sshd's own units too, so a missing key can never keep sshd down even if
# the ordering is defeated again. ExecStartPre is a no-op once keys exist.
# NB: the section differs per unit type — a .socket unit has no [Service]
# section, and systemd rejects one with "Unknown section".
mkdir -p /etc/systemd/system/ssh.service.d /etc/systemd/system/ssh.socket.d
cat > /etc/systemd/system/ssh.service.d/10-hostkeys.conf <<'EOF'
[Service]
ExecStartPre=/usr/bin/ssh-keygen -A
EOF
cat > /etc/systemd/system/ssh.socket.d/10-hostkeys.conf <<'EOF'
[Socket]
ExecStartPre=/usr/bin/ssh-keygen -A
EOF

# If sshd does fail, do not let it stay down permanently.
mkdir -p /etc/systemd/system/ssh.service.d
cat > /etc/systemd/system/ssh.service.d/20-restart.conf <<'EOF'
[Service]
Restart=on-failure
RestartSec=5s
EOF

# ---------------------------------------------------------------------------
# 4. Reset cloud-init so the clone is treated as a brand-new instance.
#    Without this the cached instance-id makes cloud-init skip per-instance
#    modules and the customization spec is never applied.
# ---------------------------------------------------------------------------
cloud-init clean --logs --seed || true
rm -rf /var/lib/cloud/instance /var/lib/cloud/instances /var/lib/cloud/data /var/lib/cloud/sem

# ---------------------------------------------------------------------------
# 5. General sysprep.
# ---------------------------------------------------------------------------
apt-get -y autoremove --purge
apt-get -y clean
rm -rf /var/lib/apt/lists/*

find /var/log -type f -exec truncate -s 0 {} \; || true
: > /var/log/wtmp  || true
: > /var/log/btmp  || true
: > /var/log/lastlog || true

rm -rf /tmp/* /var/tmp/*
rm -f /root/.bash_history /home/*/.bash_history
rm -rf /root/.cache /home/*/.cache

# Zero the free space so the thin-provisioned template stays small.
dd if=/dev/zero of=/EMPTY bs=1M 2>/dev/null || true
rm -f /EMPTY
sync

echo "Template prepared. cloud-init will handle VMware guest customization on clone."
