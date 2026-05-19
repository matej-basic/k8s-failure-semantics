# ── vCenter / vSphere connection ───────────────────────────────────────────

variable "vcenter_server" {
  description = "vCenter server hostname or IP"
  type        = string
  default     = "vcsa.oberin.cloud"
}

variable "vcenter_user" {
  description = "vCenter username"
  type        = string
  default     = "matej@oberin.cloud"
}

variable "vcenter_password" {
  description = "vCenter password"
  type        = string
  sensitive   = true
}

variable "datacenter" {
  description = "vSphere datacenter name"
  type        = string
  default     = "Datacenter"
}

variable "datastore" {
  description = "vSphere datastore name"
  type        = string
  default     = "Datastore"
}

variable "esxi_host" {
  description = "ESXi host whose root resource pool the VMs are placed in"
  type        = string
  default     = "esxi.oberin.cloud"
}

variable "vm_folder" {
  description = "vSphere VM folder all cluster VMs are placed in, created automatically under the datacenter VM root"
  type        = string
  default     = "k8s-failure-semantics"
}

variable "ubuntu_template" {
  description = "Name of the Ubuntu 24.04 VM template to clone"
  type        = string
  default     = "ubuntu-24.04-template"
}

# ── Management network (primary NIC) ───────────────────────────────────────

variable "mgmt_network" {
  description = "vSphere portgroup for the management / Kubernetes API network"
  type        = string
  default     = "Internet_10.0.0.0"
}

variable "mgmt_ipv4_prefix" {
  description = "First three octets of the management network; the per-VM host octet is appended"
  type        = string
  default     = "10.0.0"
}

variable "mgmt_netmask" {
  description = "Management network prefix length (CIDR)"
  type        = number
  default     = 24
}

variable "mgmt_gateway" {
  description = "Default gateway on the management network"
  type        = string
  default     = "10.0.0.1"
}

# ── Pod network (secondary NIC) ────────────────────────────────────────────
# A dedicated portgroup is ideal, but pointing this at the same portgroup as
# the management network also works — the two NICs just live on different
# IP subnets. Override pod_network if you have a separate VLAN/portgroup.

variable "pod_network" {
  description = "vSphere portgroup for the Kubernetes pod/service network (Calico)"
  type        = string
  default     = "BasoNET"
}

variable "pod_ipv4_prefix" {
  description = "First three octets of the pod network; the per-VM host octet is appended"
  type        = string
  default     = "192.168.200"
}

variable "pod_netmask" {
  description = "Pod network prefix length (CIDR)"
  type        = number
  default     = 24
}

variable "dns_server" {
  description = "Primary DNS server for the VMs"
  type        = string
  default     = "10.0.0.1"
}

variable "domain" {
  description = "DNS domain / search suffix for the VMs"
  type        = string
  default     = "k8s.local"
}

# ── Ansible / Kubernetes inventory settings ────────────────────────────────
# These do not affect VM provisioning; they are written into the generated
# inventory (terraform output -raw ansible_inventory) consumed by the playbooks.

variable "ansible_user" {
  description = "SSH user baked into the Ubuntu template"
  type        = string
  default     = "ansible"
}

variable "ansible_ssh_private_key_file" {
  description = "Path to the SSH private key Ansible uses to reach the VMs"
  type        = string
  default     = "~/.ssh/id_rsa"
}

variable "k8s_version" {
  description = "Kubernetes version installed by the Ansible playbooks"
  type        = string
  default     = "1.36.1"
}

variable "etcd_version" {
  description = "etcd version installed on the dedicated etcd nodes (kubeadm 1.36 requires >= 3.5.24)"
  type        = string
  default     = "3.5.30"
}

variable "pod_network_cidr" {
  description = "Kubernetes pod network CIDR (Calico overlay)"
  type        = string
  default     = "10.244.0.0/16"
}

variable "service_cidr" {
  description = "Kubernetes service network CIDR"
  type        = string
  default     = "10.96.0.0/12"
}

variable "api_vip" {
  description = "Virtual IP for the HA Kubernetes API server (must be free on the management network)"
  type        = string
  default     = "10.0.0.59"
}
