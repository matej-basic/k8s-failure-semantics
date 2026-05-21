terraform {
  required_providers {
    vsphere = {
      source  = "hashicorp/vsphere"
      version = "~> 2.8"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.4"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }
  required_version = ">= 1.5.0"
}

provider "vsphere" {
  vsphere_server       = var.vcenter_server
  user                 = var.vcenter_user
  password             = var.vcenter_password
  allow_unverified_ssl = true
}

# ---------------------------------------------------------------------------
# Data sources
# ---------------------------------------------------------------------------

data "vsphere_datacenter" "dc" {
  name = var.datacenter
}

data "vsphere_datastore" "ds" {
  name          = var.datastore
  datacenter_id = data.vsphere_datacenter.dc.id
}

data "vsphere_host" "host" {
  name          = var.esxi_host
  datacenter_id = data.vsphere_datacenter.dc.id
}

# Management network — Kubernetes API, SSH, node-to-node traffic.
data "vsphere_network" "mgmt" {
  name          = var.mgmt_network
  datacenter_id = data.vsphere_datacenter.dc.id
}

# Pod network — second NIC carrying the Kubernetes pod/service traffic (Calico).
data "vsphere_network" "pod" {
  name          = var.pod_network
  datacenter_id = data.vsphere_datacenter.dc.id
}

# Ubuntu 24.04 template — every cluster VM is cloned from this.
data "vsphere_virtual_machine" "ubuntu_template" {
  name          = var.ubuntu_template
  datacenter_id = data.vsphere_datacenter.dc.id
}

# ---------------------------------------------------------------------------
# VM folder — created automatically under the datacenter VM root
# ---------------------------------------------------------------------------

resource "vsphere_folder" "vms" {
  path          = var.vm_folder
  type          = "vm"
  datacenter_id = data.vsphere_datacenter.dc.id
}

# ---------------------------------------------------------------------------
# Cluster topology — single source of truth for the 11 VMs.
# The observer / Ansible-controller host is intentionally NOT created here:
# you run Ansible from your own machine against these VMs.
#
#   role           name        mgmt + pod octet   vCPU   RAM      disk
#   control_plane  cp1..cp3     50 51 52           4      8 GB     60 GB
#   workers        worker1..3   53 54 55           4      8 GB     60 GB
#   etcd           etcd1..5     56 57 58 60 61     2      4 GB     40 GB
#
# A 5-member etcd cluster (was 3): etcd4/etcd5 give S19 (split quorum) a
# meaningful 3/2 majority/minority split. octet 59 is the API VIP, so the
# two new etcd nodes take 60 and 61. The whole etcd path — inventory
# generation (outputs.tf), CA/peer cert SANs and the --initial-cluster
# systemd flag (roles/k8s-install) — already iterates groups['etcd'], so
# this map is the only place the member count is set.
#
# Each VM gets the same host octet on both the management and pod networks.
# ---------------------------------------------------------------------------

locals {
  vm_specs = {
    cp1     = { role = "control_plane", octet = 50, num_cpus = 4, memory = 8192, disk_size = 60 }
    cp2     = { role = "control_plane", octet = 51, num_cpus = 4, memory = 8192, disk_size = 60 }
    cp3     = { role = "control_plane", octet = 52, num_cpus = 4, memory = 8192, disk_size = 60 }
    worker1 = { role = "workers", octet = 53, num_cpus = 4, memory = 8192, disk_size = 60 }
    worker2 = { role = "workers", octet = 54, num_cpus = 4, memory = 8192, disk_size = 60 }
    worker3 = { role = "workers", octet = 55, num_cpus = 4, memory = 8192, disk_size = 60 }
    etcd1   = { role = "etcd", octet = 56, num_cpus = 2, memory = 4096, disk_size = 40 }
    etcd2   = { role = "etcd", octet = 57, num_cpus = 2, memory = 4096, disk_size = 40 }
    etcd3   = { role = "etcd", octet = 58, num_cpus = 2, memory = 4096, disk_size = 40 }
    etcd4   = { role = "etcd", octet = 60, num_cpus = 2, memory = 4096, disk_size = 40 }
    etcd5   = { role = "etcd", octet = 61, num_cpus = 2, memory = 4096, disk_size = 40 }
  }
}

# ---------------------------------------------------------------------------
# Deploy the 11 cluster VMs via the vm module
# ---------------------------------------------------------------------------

module "vms" {
  for_each   = local.vm_specs
  source     = "./modules/vm"
  depends_on = [vsphere_folder.vms]

  vm_name          = each.key
  template_id      = data.vsphere_virtual_machine.ubuntu_template.id
  guest_id         = data.vsphere_virtual_machine.ubuntu_template.guest_id
  resource_pool_id = data.vsphere_host.host.resource_pool_id
  datastore_id     = data.vsphere_datastore.ds.id
  vm_folder        = var.vm_folder

  num_cpus  = each.value.num_cpus
  memory    = each.value.memory
  disk_size = each.value.disk_size

  # Primary NIC — management network (carries the default gateway).
  network_id   = data.vsphere_network.mgmt.id
  ipv4_address = "${var.mgmt_ipv4_prefix}.${each.value.octet}"
  netmask      = var.mgmt_netmask
  gateway      = var.mgmt_gateway
  dns_server   = var.dns_server
  domain       = var.domain

  # Secondary NIC — pod/service network (no gateway).
  pod_network_id   = data.vsphere_network.pod.id
  pod_ipv4_address = "${var.pod_ipv4_prefix}.${each.value.octet}"
  pod_netmask      = var.pod_netmask
}
