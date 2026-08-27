# ---------------------------------------------------------------------------
# ubuntu-24.04.pkr.hcl — builds the `ubuntu-24.04-template` vSphere template
# that terraform/ clones for all 11 cluster VMs.
#
# Read packer/README.md before changing anything here: several settings
# (template name, disk size, pvscsi, BIOS firmware, vmxnet3) are load-bearing
# for terraform/modules/vm/main.tf and silently break the clone if altered.
# ---------------------------------------------------------------------------

packer {
  required_version = ">= 1.9.0"

  required_plugins {
    vsphere = {
      source  = "github.com/hashicorp/vsphere"
      version = ">= 1.2.0"
    }
  }
}

locals {
  # Ubuntu's autoinstall seed, delivered on a second CD-ROM labelled `cidata`
  # rather than over Packer's built-in HTTP server. See README ("Why a seed
  # ISO and not http_directory").
  cd_content = {
    "meta-data" = "instance-id: ubuntu-24-04-template\nlocal-hostname: ubuntu-template\n"
    "user-data" = templatefile("${path.root}/data/user-data.pkrtpl.yaml", {
      username       = var.ssh_username
      password_hash  = var.install_password_hash
      ssh_public_key = var.ssh_public_key
    })
  }

  build_timestamp = formatdate("YYYY-MM-DD hh:mm ZZZ", timestamp())
}

source "vsphere-iso" "ubuntu" {
  # ── vCenter ──────────────────────────────────────────────────────────────
  vcenter_server      = var.vsphere_server
  username            = var.vsphere_user
  password            = var.vsphere_password
  insecure_connection = var.vsphere_insecure_connection

  datacenter = var.vsphere_datacenter
  host       = var.vsphere_host
  datastore  = var.vsphere_datastore
  folder     = var.vsphere_folder

  # ── Identity ─────────────────────────────────────────────────────────────
  # Must match terraform.tfvars `ubuntu_template`; Terraform's
  # data.vsphere_virtual_machine resolves the template by this name, and it
  # has to be a real inventory template (not a content-library item).
  vm_name             = var.template_name
  convert_to_template = true
  notes               = "Ubuntu 24.04 LTS base template for k8s-failure-semantics. Built by packer/ on ${local.build_timestamp}. Minimal: open-vm-tools + cloud-init GOSC + ansible user. No Kubernetes — roles/common and roles/k8s-install do that."

  # ── Virtual hardware ─────────────────────────────────────────────────────
  guest_os_type   = var.guest_os_type
  CPUs            = var.build_cpus
  RAM             = var.build_memory
  RAM_reserve_all = false

  # BIOS, NOT EFI. terraform/modules/vm/main.tf never sets `firmware`, and the
  # hashicorp/vsphere provider defaults that attribute to "bios". An EFI
  # template would be cloned into a BIOS VM and never boot.
  firmware = "bios"

  # terraform/modules/vm/main.tf pins scsi_type = "pvscsi"; a mismatch here
  # produces a permanent diff / forced replacement on every plan.
  disk_controller_type = ["pvscsi"]

  storage {
    disk_size             = var.template_disk_size
    disk_thin_provisioned = true
    disk_controller_index = 0
  }

  # One vmxnet3 NIC is enough: Terraform declares both network_interface
  # blocks itself on the clone. The adapter *type* must be vmxnet3 to match.
  network_adapters {
    network      = var.vsphere_network
    network_card = "vmxnet3"
  }

  # ── Installation media ───────────────────────────────────────────────────
  iso_url      = var.iso_url
  iso_checksum = var.iso_checksum

  cd_content = local.cd_content
  cd_label   = "cidata"

  # Drop every CD-ROM before converting to a template, so no clone ever
  # re-reads the autoinstall seed as a NoCloud datasource.
  remove_cdrom = true

  # ── Boot ─────────────────────────────────────────────────────────────────
  # `c` drops into the GRUB shell; loading the kernel by hand is far more
  # robust than editing the menu entry with cursor keys. `ds=nocloud` with no
  # seed path makes cloud-init probe block devices for a filesystem labelled
  # `cidata`, which is exactly what cd_label produces.
  boot_wait = "5s"
  boot_command = [
    "<wait5s>c<wait5s>",
    "linux /casper/vmlinuz autoinstall ds=nocloud ---<enter><wait5s>",
    "initrd /casper/initrd<enter><wait5s>",
    "boot<enter>"
  ]

  # ── Connection ───────────────────────────────────────────────────────────
  ip_wait_timeout        = "30m"
  ssh_username           = var.ssh_username
  ssh_private_key_file   = pathexpand(var.ssh_private_key_file)
  ssh_timeout            = "60m"
  ssh_handshake_attempts = 100

  shutdown_command = "sudo /usr/sbin/shutdown -P now"
  shutdown_timeout = "15m"
}

build {
  name    = "ubuntu-24.04-template"
  sources = ["source.vsphere-iso.ubuntu"]

  # Wait for cloud-init's first (install-time) run to settle before touching
  # any of its state, otherwise `cloud-init clean` races the running unit.
  provisioner "shell" {
    inline = [
      "echo 'Waiting for cloud-init to finish the post-install run...'",
      "cloud-init status --wait || true",
    ]
  }

  provisioner "shell" {
    script          = "${path.root}/provision/prepare-template.sh"
    execute_command = "sudo -E bash '{{ .Path }}'"
  }

  post-processor "manifest" {
    output     = "${path.root}/packer-manifest.json"
    strip_path = true
  }
}
