variable "vm_name" {
  description = "Name (and guest hostname) of the virtual machine"
  type        = string
}

variable "template_id" {
  description = "Managed object ID of the Ubuntu source template"
  type        = string
}

variable "guest_id" {
  description = "Guest OS identifier inherited from the template"
  type        = string
}

variable "resource_pool_id" {
  description = "Managed object ID of the resource pool (or host root pool)"
  type        = string
}

variable "datastore_id" {
  description = "Managed object ID of the target datastore"
  type        = string
}

variable "vm_folder" {
  description = "vSphere folder path for the VM"
  type        = string
}

variable "num_cpus" {
  description = "Number of vCPUs"
  type        = number
}

variable "memory" {
  description = "Memory in MB"
  type        = number
}

variable "disk_size" {
  description = "Primary disk size in GB (cloned from template)"
  type        = number
}

# ── Primary NIC — management network ───────────────────────────────────────

variable "network_id" {
  description = "Managed object ID of the management network portgroup"
  type        = string
}

variable "ipv4_address" {
  description = "Static IPv4 address on the management network"
  type        = string
}

variable "netmask" {
  description = "Management network prefix length (CIDR)"
  type        = number
}

variable "gateway" {
  description = "Default gateway (management network)"
  type        = string
}

variable "dns_server" {
  description = "Primary DNS server IP"
  type        = string
}

variable "domain" {
  description = "DNS domain / search suffix"
  type        = string
}

# ── Secondary NIC — pod network ────────────────────────────────────────────

variable "pod_network_id" {
  description = "Managed object ID of the pod network portgroup"
  type        = string
}

variable "pod_ipv4_address" {
  description = "Static IPv4 address on the pod network"
  type        = string
}

variable "pod_netmask" {
  description = "Pod network prefix length (CIDR)"
  type        = number
}
