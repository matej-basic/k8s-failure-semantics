# ---------------------------------------------------------------------------
# Derived views of the cluster topology, used to build the Ansible inventory
# ---------------------------------------------------------------------------

locals {
  mgmt_ip = { for k, v in local.vm_specs : k => "${var.mgmt_ipv4_prefix}.${v.octet}" }

  cp_names     = sort([for k, v in local.vm_specs : k if v.role == "control_plane"])
  worker_names = sort([for k, v in local.vm_specs : k if v.role == "workers"])
  etcd_names   = sort([for k, v in local.vm_specs : k if v.role == "etcd"])

  cp_lines     = join("\n", [for k in local.cp_names : "${k} ansible_host=${local.mgmt_ip[k]}"])
  worker_lines = join("\n", [for k in local.worker_names : "${k} ansible_host=${local.mgmt_ip[k]}"])
  etcd_lines   = join("\n", [for k in local.etcd_names : "${k} ansible_host=${local.mgmt_ip[k]}"])

  etcd_endpoints = join(",", [for k in local.etcd_names : "https://${local.mgmt_ip[k]}:2379"])

  # The full inventory — consumed both by the ansible_inventory output and by
  # the local_file written for the Terraform-driven cluster install.
  ansible_inventory = <<-INI
    [control_plane]
    ${local.cp_lines}

    [workers]
    ${local.worker_lines}

    [etcd]
    ${local.etcd_lines}

    # No observer VM is provisioned. The observer is the machine running
    # Ansible; localhost is used so the kubeconfig-copy play has a target.
    [observer]
    localhost ansible_connection=local

    [k8s_cluster:children]
    control_plane
    workers

    [all:vars]
    ansible_user=${var.ansible_user}
    ansible_ssh_private_key_file=${var.ansible_ssh_private_key_file}
    ansible_python_interpreter=/usr/bin/python3
    ansible_become=true

    # Kubernetes config
    k8s_version=${var.k8s_version}
    pod_network_cidr=${var.pod_network_cidr}
    service_cidr=${var.service_cidr}
    api_vip=${var.api_vip}

    # etcd config
    etcd_version=${var.etcd_version}
    etcd_data_dir=/var/lib/etcd
    etcd_endpoints=${local.etcd_endpoints}

    # Toxiproxy config (runs on each etcd host, fronts etcd port)
    toxiproxy_etcd_port=22379

    # Observation window defaults (seconds) — override per scenario
    fault_duration=60
    observation_window=120
    convergence_timeout=300

    # Results output on observer
    results_dir=/opt/k8s-results
  INI
}

# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------

output "vm_mgmt_ips" {
  description = "Map of VM name → management network IP"
  value       = { for k, v in module.vms : k => v.ip_address }
}

output "vm_pod_ips" {
  description = "Map of VM name → pod network IP"
  value       = { for k, v in module.vms : k => v.pod_ip_address }
}

output "vm_ids" {
  description = "Map of VM name → vSphere managed object ID"
  value       = { for k, v in module.vms : k => v.vm_id }
}

output "ansible_inventory" {
  description = "Generated inventory (also written to ../inventory/hosts.ini on apply)"
  value       = local.ansible_inventory
}
