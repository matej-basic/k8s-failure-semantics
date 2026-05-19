# ---------------------------------------------------------------------------
# Ansible integration — drive the Kubernetes install from `terraform apply`.
#
# With run_ansible = true (the default), a single `terraform apply`:
#   1. provisions the 9 VMs (vsphere_virtual_machine resources)
#   2. writes the generated inventory to ../inventory/hosts.ini
#   3. waits for SSH on every node, then runs playbooks/setup-cluster.yml
#
# Set run_ansible = false to provision the VMs only and run Ansible by hand.
# Requires the `ansible` CLI to be installed on the machine running Terraform.
# ---------------------------------------------------------------------------

variable "run_ansible" {
  description = "Run the Ansible cluster install automatically during terraform apply"
  type        = bool
  default     = true
}

# Write the generated inventory to the repo's inventory/ directory so the
# playbooks (and ad-hoc ansible commands) can use it directly.
resource "local_file" "ansible_inventory" {
  content         = local.ansible_inventory
  filename        = "${path.module}/../inventory/hosts.ini"
  file_permission = "0644"
}

resource "null_resource" "k8s_install" {
  count = var.run_ansible ? 1 : 0

  # Re-run the install whenever the set of VMs changes (e.g. a destroy/recreate).
  triggers = {
    vm_ids    = join(",", sort([for k, v in module.vms : v.vm_id]))
    inventory = local_file.ansible_inventory.content
  }

  depends_on = [module.vms, local_file.ansible_inventory]

  # Wait until SSH is reachable on every cluster + etcd node, then install.
  # The observer play is skipped (--limit) — no observer VM is provisioned;
  # the admin kubeconfig is left on cp1 at /tmp/admin.conf.
  provisioner "local-exec" {
    working_dir = "${path.module}/.."
    command     = <<-EOT
      ansible -i inventory/hosts.ini k8s_cluster:etcd \
        -m wait_for_connection -a 'timeout=600' && \
      ansible-playbook -i inventory/hosts.ini playbooks/setup-cluster.yml \
        --limit 'k8s_cluster:etcd'
    EOT
  }
}
