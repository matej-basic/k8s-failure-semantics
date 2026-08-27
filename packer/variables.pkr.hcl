# ---------------------------------------------------------------------------
# variables.pkr.hcl — inputs for the ubuntu-24.04-template build.
#
# Every value except `vsphere_password` has a default matching the lab
# described in INFRASTRUCTURE.md, so a build is:
#
#   packer build -var "vsphere_password=..." .
#
# The password deliberately has NO default and must never be written into a
# file that git can see (see .gitignore: packer/*.pkrvars.hcl).
# ---------------------------------------------------------------------------

# ── vCenter connection ─────────────────────────────────────────────────────

variable "vsphere_server" {
  description = "vCenter server hostname or IP"
  type        = string
  default     = "vcsa.oberin.cloud"
}

variable "vsphere_user" {
  description = "vCenter username used for the build"
  type        = string
  default     = "matej@oberin.cloud"
}

variable "vsphere_password" {
  description = "vCenter password. No default on purpose — pass it with -var or an untracked *.pkrvars.hcl file."
  type        = string
  sensitive   = true
}

variable "vsphere_insecure_connection" {
  description = "Skip TLS verification. The lab vCenter uses a self-signed certificate."
  type        = bool
  default     = true
}

# ── vSphere placement ──────────────────────────────────────────────────────

variable "vsphere_datacenter" {
  description = "vSphere datacenter name"
  type        = string
  default     = "Datacenter"
}

variable "vsphere_host" {
  description = "ESXi host that runs the build VM and ends up owning the template"
  type        = string
  default     = "esxi.oberin.cloud"
}

variable "vsphere_datastore" {
  description = "Datastore the template is stored on"
  type        = string
  default     = "NVMe"
}

variable "vsphere_network" {
  description = "Portgroup the build VM uses. Must have DHCP and outbound internet so the installer can fetch packages."
  type        = string
  default     = "Internet_10.0.0.0"
}

variable "vsphere_folder" {
  description = "VM folder the finished template is placed in, relative to the datacenter VM root"
  type        = string
  default     = "Templates"
}

# ── Template identity ──────────────────────────────────────────────────────
# terraform/terraform.tfvars sets ubuntu_template = "ubuntu-24.04-template".
# data.vsphere_virtual_machine looks the template up by this exact name.

variable "template_name" {
  description = "Name of the resulting VM template. Terraform clones this exact name — do not change it casually."
  type        = string
  default     = "ubuntu-24.04-template"
}

# ── Guest OS ───────────────────────────────────────────────────────────────

variable "iso_url" {
  description = "Ubuntu 24.04 LTS live-server ISO. Packer downloads it and uploads it to the datastore."
  type        = string
  default     = "https://releases.ubuntu.com/24.04/ubuntu-24.04.4-live-server-amd64.iso"
}

variable "iso_checksum" {
  description = "SHA256 of iso_url, taken verbatim from https://releases.ubuntu.com/24.04/SHA256SUMS"
  type        = string
  default     = "sha256:e907d92eeec9df64163a7e454cbc8d7755e8ddc7ed42f99dbc80c40f1a138433"
}

variable "guest_os_type" {
  description = "vSphere guest OS identifier. Terraform reads guest_id off the template and reuses it on the clone."
  type        = string
  default     = "ubuntu64Guest"
}

# ── Build VM sizing ────────────────────────────────────────────────────────
# CPU/RAM only affect how fast the install runs; Terraform overrides both on
# every clone. disk_size is NOT overridable downwards — see README.

variable "build_cpus" {
  description = "vCPUs given to the temporary build VM"
  type        = number
  default     = 2
}

variable "build_memory" {
  description = "RAM (MB) given to the temporary build VM"
  type        = number
  default     = 4096
}

variable "template_disk_size" {
  description = "Template disk in MB. MUST stay <= the smallest disk Terraform asks for (etcd nodes: 40 GB) because a clone can grow a disk but never shrink one."
  type        = number
  default     = 20480
}

# ── Guest credentials ──────────────────────────────────────────────────────

variable "ssh_username" {
  description = "Account created in the template. terraform.tfvars sets ansible_user = \"ansible\"."
  type        = string
  default     = "ansible"
}

variable "ssh_public_key" {
  description = "Public key installed into ~ansible/.ssh/authorized_keys. Contents of ~/.ssh/id_rsa.pub — a public key is not a secret."
  type        = string
  default     = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQC46xGp3/BAV1lGjyiw9CfeUV2jIvZBanI9AjI9LRgtLTA+HKfqWz7SGGbbiJn/LSQLaVbTksH/tr+xT6s6duenE2TAwtxnnd70wXSaHg/3SEOZW80NUiDXKiVxvicxmnhRGOrdTnrSzEt/VCdPFM0zeU549HA1pVCOKaxmdlhiM3nLzYqN4loNy5cebeUehQX2zlXw1xN2PBkwbssrRkP7anp0o+IaLzG5r4+MLjUOfZqNIRtp+6ILvRg2m8CWFWL7H9Oz6BHOcA3t3ckAlDOIpWB3k7Py4TPVcAJ94M/5h3BdaqfF9uCJB7m31AIIoRq+y2mABoIortFrJWq34Xa9aIyVQ4pa06yPuewDC5NMwcurLahQhf5YYbnwDXTvKOUlaOCWKLM6LQZU64QJ5RZokgaYsqPbJL/+X1pSnBUP7+1eXgGTVq8ziFUoP1BpfuxcDew6CuzDjuW8molYnUXUe/6LzUkvTHtA5eyuwU03zg4BY9V2qHMWCXQHREA1Uyk= matej@Matejs-Mac-mini.local"
}

variable "ssh_private_key_file" {
  description = "Private key Packer authenticates with during the build. Matches terraform.tfvars ansible_ssh_private_key_file."
  type        = string
  default     = "~/.ssh/id_rsa"
}

variable "install_password_hash" {
  description = <<-EOT
    SHA-512 crypt hash handed to the Ubuntu installer, which requires a
    non-empty value for identity.password. It is the hash of a random string
    that was generated once and discarded — nobody knows the plaintext. The
    account is locked (`passwd -l`) in late-commands and sshd is configured
    with PasswordAuthentication no, so no password login exists in the
    finished template. This is NOT a credential; it is installer ballast.
  EOT
  type        = string
  default     = "$6$rHth2TgjZiOD6NWn$zcItDDrh88NkuAmTcKLcRO7APP0CtIa1exW10r/2OojanOI3Q77SlqCTvxUvn3Q0sgJv.EbFrHi45KPZ8Htwa1"
}
