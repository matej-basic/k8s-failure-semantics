# `packer/` — the `ubuntu-24.04-template` vSphere template

This directory builds the one artifact `terraform/` cannot create for itself:
the Ubuntu 24.04 VM template that all 11 cluster VMs are cloned from.

`terraform/terraform.tfvars` sets `ubuntu_template = "ubuntu-24.04-template"`,
and `terraform/main.tf` resolves it with `data "vsphere_virtual_machine"`.
Until that template exists in the vCenter inventory, `terraform apply` fails at
plan time. Nothing in `terraform/` needs to change for this build — the whole
point of the constraints below is that the template matches what the existing
Terraform already asks for.

---

## Quick start

```bash
cd packer

packer init .                                     # fetch the vsphere plugin
packer fmt -check .
packer validate -var 'vsphere_password=dummy' .   # offline; contacts nothing

# The real build (~20-30 min: ISO download + upload + install)
read -rs PKR_VAR_vsphere_password && export PKR_VAR_vsphere_password
packer build .
```

Or with a file:

```bash
cp credentials.pkrvars.hcl.example credentials.pkrvars.hcl
$EDITOR credentials.pkrvars.hcl        # gitignored
packer build -var-file=credentials.pkrvars.hcl .
```

Then, from the repo root:

```bash
./deploy.sh vms
```

### Prerequisites

- Packer >= 1.9 with network access to fetch `github.com/hashicorp/vsphere`.
- `~/.ssh/id_rsa` / `~/.ssh/id_rsa.pub` — the same key pair
  `terraform.tfvars` hands to Ansible. The public key is baked into the
  template; Packer authenticates with the private key during the build.
- A DHCP lease and outbound internet on `Internet_10.0.0.0`, because the
  Ubuntu installer downloads packages.
- `ovftool` is **not** required. This build never leaves vSphere.

### Rebuilding

`vsphere-iso` will not overwrite an existing VM or template. Delete the old
`ubuntu-24.04-template` from the inventory first — and be aware that vCenter
refuses to delete a template while linked clones exist, so tear the cluster
down (`terraform destroy`) before rebuilding.

---

## Files

| File | Purpose |
|---|---|
| `ubuntu-24.04.pkr.hcl` | The `vsphere-iso` source and `build` block. |
| `variables.pkr.hcl` | All inputs. Every variable except `vsphere_password` has a working default. |
| `data/user-data.pkrtpl.yaml` | subiquity autoinstall seed, rendered with `templatefile()`. |
| `provision/prepare-template.sh` | Post-install sysprep: guest-customization wiring, identity reset, cleanup. |
| `credentials.pkrvars.hcl.example` | Shape of the untracked vars file. Contains a placeholder, never a real password. |

---

## What the template guarantees

These are contract points with `terraform/modules/vm/main.tf`. Each one breaks
the clone in a different, and mostly non-obvious, way if it drifts.

| Guarantee | Why Terraform needs it |
|---|---|
| Named exactly `ubuntu-24.04-template`, marked as a template, in `/Datacenter/vm/Templates` | `data "vsphere_virtual_machine"` looks it up by name. It must be an inventory template — a **content library item cannot be read by that data source**. |
| Disk **20 GB**, thin provisioned | `etcd1..5` clone with `disk_size = 40`; `cp*`/`worker*` with 60. A clone can grow a disk but never shrink one, so a template larger than 40 GB breaks all five etcd VMs. `thin_provisioned = true` on the module's `disk` block must match the template's provisioning too. |
| SCSI controller `pvscsi` | The module pins `scsi_type = "pvscsi"`. A mismatch is a permanent diff / forced replacement. |
| One **vmxnet3** NIC | The module declares both `network_interface` blocks itself, so the count does not matter, but `adapter_type = "vmxnet3"` does. |
| Firmware **BIOS**, not EFI | The module never sets `firmware`, and the `hashicorp/vsphere` provider defaults it to `"bios"`. An EFI-installed template cloned into a BIOS VM does not boot. This is the easiest way to build a template that validates perfectly and then produces 11 dead VMs. |
| `guest_os_type = "ubuntu64Guest"` | `guest_id` is read straight off the template and reused on the clone. |
| `open-vm-tools` installed and enabled | Without VMware Tools the module's `wait_for_guest_net_timeout = 10` never returns, and vCenter never delivers a customization spec. |
| Working Guest OS Customization: hostname, domain, two static IPv4 NICs, DNS | The module's `clone { customize { ... } }` block. See the next section. |
| User `ansible`, key-only, passwordless sudo | `terraform.tfvars`: `ansible_user = "ansible"`, `ansible_ssh_private_key_file = "~/.ssh/id_rsa"`. Sudo rule at `/etc/sudoers.d/ansible`, mode `0440`. |
| `/usr/bin/python3` exists | `ansible.cfg`: `interpreter_python = /usr/bin/python3`. |
| Root partition grows on first boot | The 20 GB template becomes a 40/60 GB clone. `cloud-guest-utils` (growpart) plus a `direct` — non-LVM — storage layout means cloud-init resizes the root filesystem itself. With LVM it would grow the PV and stop, leaving the filesystem at 20 GB. |

`provision/prepare-template.sh` asserts the checkable ones (`python3`, `perl`,
`vmtoolsd`, `growpart`, enabled units) and fails the build rather than
producing a template that only misbehaves later.

### What the template deliberately does **not** contain

No Kubernetes, no containerd, no kubeadm, swap left on, no sysctl or kernel
module changes. `roles/common` does all of that — including masking the
`unattended-upgrades` and `apt-daily` timers — and `roles/k8s-install` builds
the cluster. Baking any of it into the template would duplicate that role and
split the source of truth for the pinned `k8s_version` / `etcd_version`.

---

## cloud-init vs. open-vm-tools

**Decision: cloud-init stays installed, and cloud-init is what consumes the
VMware customization spec.**

There are two mutually exclusive ways an Ubuntu guest can apply a vCenter Guest
OS Customization spec, and running both is the usual reason a hand-built
template comes up with no IP:

1. **The legacy path.** `open-vm-tools`' `deployPkg` plugin applies the spec
   itself using its bundled perl scripts. This is what
   `disable_vmware_customization: true` — Ubuntu's shipped default — selects.
   It assumes it can write the guest's network configuration directly.
2. **The cloud-init path.** `deployPkg` only unpacks the spec into
   `/var/run/vmware-imc`, and cloud-init's `OVF` datasource reads it and
   renders the network config through netplan. Selected by
   `disable_vmware_customization: false`.

Path 2 was chosen:

- On 24.04, netplan is the only supported renderer and cloud-init owns it.
  The legacy perl path predates that and does not reliably produce a correct
  netplan file for a two-NIC static configuration — which is exactly what
  `terraform/modules/vm/main.tf` asks for (`ens192` with the gateway, `ens224`
  on the pod network without one).
- Keeping cloud-init also keeps the machinery that regenerates per-instance
  identity for free: SSH host keys and the machine-id are recreated on first
  boot by modules that are already in the image, and `growpart`/`resizefs`
  handle the 20 GB -> 40/60 GB disk change. Purging cloud-init means
  hand-rolling all three.
- Purging cloud-init from a subiquity-installed image is invasive; the
  installer configures the system *through* cloud-init.

`provision/prepare-template.sh` makes that path actually work by undoing what
the installer leaves behind:

- Deletes `/etc/cloud/cloud.cfg.d/90_dpkg.cfg` and `99-installer.cfg`, which
  pin `datasource_list: [ NoCloud, None ]`. With `OVF` absent from that list
  the customization spec is never even looked for.
- Deletes `/etc/cloud/cloud.cfg.d/subiquity-disable-cloudinit-networking.cfg`,
  which contains `network: {config: disabled}` and would make cloud-init ignore
  network configuration entirely.
- Writes `/etc/cloud/cloud.cfg.d/99-vsphere-gosc.cfg` with
  `datasource_list: [ OVF, VMware, None ]` and
  `disable_vmware_customization: false`, and sets the same switch in
  `/etc/cloud/cloud.cfg` for good measure.
- **Empties `/etc/netplan/`.** Any installer-generated file there is a landmine:
  netplan merges every file in the directory, so a leftover
  `00-installer-config.yaml` can contradict or shadow the
  `50-cloud-init.yaml` that cloud-init writes from the spec. With the
  directory empty, a customized clone gets exactly the static config Terraform
  asked for, and an *un*-customized clone (a manual clone, a test) falls back
  to cloud-init's built-in DHCP-on-the-first-NIC config instead of being
  unreachable.
- Removes persistent net naming rules, truncates `/etc/machine-id` (empty file,
  not deleted — systemd regenerates it at boot; deleting it can leave a
  read-only bind mount), removes `/etc/ssh/ssh_host_*`, and runs
  `cloud-init clean --logs --seed` so the clone is treated as a new instance
  rather than a resumed one.

A small `regenerate-ssh-host-keys.service` oneshot is installed as a safety
net so sshd can never start without host keys, even in a derived image where
cloud-init has been disabled. It is conditional on the keys being absent, so
it is a no-op on every boot after the first.

`perl` is installed regardless: `deployPkg` still runs (it is what unpacks the
spec), and the legacy scripts are its fallback.

---

## Why a seed ISO and not `http_directory`

Packer's built-in HTTP server serves the autoinstall `user-data` from the
machine running Packer. The build VM lives on `Internet_10.0.0.0` (10.0.0.0/24)
and there is no verified route from the operator's workstation back into that
network, so an HTTP-served seed is liable to hang the installer at its first
prompt with no useful error.

Instead the build attaches a second CD-ROM built from `cd_content`, labelled
`cidata`. The boot command passes `autoinstall ds=nocloud` with **no** `s=`
seed path, which makes cloud-init probe attached block devices for a
filesystem labelled `cidata` — a purely local lookup with no network involved.

Note that a seed path of `s=/cdrom/` would point at the *installation* ISO,
which does not carry `user-data`; the label probe is the correct mechanism for
a separate seed disc. `remove_cdrom = true` drops both drives before the VM is
converted to a template, so no clone can ever re-read the autoinstall seed.

The boot command itself types `c` to enter the GRUB shell and loads
`/casper/vmlinuz` and `/casper/initrd` explicitly, rather than editing the
menu entry with cursor keys — far less sensitive to menu layout changes
between point releases.

---

## ISO and checksum

- **Point release:** Ubuntu 24.04.4 LTS,
  `https://releases.ubuntu.com/24.04/ubuntu-24.04.4-live-server-amd64.iso`
- **Checksum:** `sha256:e907d92eeec9df64163a7e454cbc8d7755e8ddc7ed42f99dbc80c40f1a138433`,
  copied verbatim from `https://releases.ubuntu.com/24.04/SHA256SUMS`.

Packer downloads the ISO (cached under `packer_cache/`, gitignored) and
uploads it to the `NVMe` datastore itself.

When Canonical publishes 24.04.5, `releases.ubuntu.com` keeps only the newest
point release, so `iso_url` will 404. Bump both `iso_url` and `iso_checksum`
together from the current `SHA256SUMS`, or switch to the checksum-file form
and only bump the URL:

```hcl
iso_checksum = "file:https://releases.ubuntu.com/24.04/SHA256SUMS"
```

Never hand-edit the hash.

---

## Credentials

The vCenter password is the only secret here and it has **no default**. Pass it
with `-var`, `PKR_VAR_vsphere_password`, or an untracked
`credentials.pkrvars.hcl`. The repo's `.gitignore` covers
`packer/*.pkrvars.hcl`, `packer/packer_cache/` and `packer/packer-manifest.json`.

`variables.pkr.hcl` does contain two things that look like secrets and are not:

- `ssh_public_key` — a public key, by definition not secret. It is a variable
  so it can be overridden, with the lab's actual key as the default.
- `install_password_hash` — the Ubuntu installer refuses an empty
  `identity.password`, so it is given the SHA-512 hash of a random string that
  was generated once and discarded. The account is locked with `passwd -l` in
  `late-commands` and sshd is configured `PasswordAuthentication no`, so the
  finished template has no password login at all. Access is key-only.

---

## Known caveats

- The lab key is RSA. Ubuntu 24.04's OpenSSH rejects the old `ssh-rsa`
  (SHA-1) signature algorithm but accepts `rsa-sha2-256/512`, which both
  Packer's and Ansible's clients negotiate automatically. An `ed25519` key
  would sidestep the question entirely if the key pair is ever rotated.
- The build takes 20-30 minutes, most of it ISO download and datastore upload.
  The upload is skipped on rebuilds if the ISO is already in the datastore's
  `packer_cache` directory.
- `packer build` is intentionally not run by tooling or by `deploy.sh`. The
  template is built once, by hand, and then cloned hundreds of times.
