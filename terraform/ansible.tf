# ---------------------------------------------------------------------------
# Terraform / Ansible hand-off.
#
# Terraform and Ansible are kept strictly separate:
#   terraform apply       -> provisions the VMs only
#   ansible-playbook ...  -> installs the cluster on those VMs
#
# Terraform's only Ansible-facing job is to write the inventory that
# describes the infrastructure it just built — that generated hosts.ini is
# the single hand-off artifact between the two tools. `../deploy.sh` runs
# the two steps in sequence.
# ---------------------------------------------------------------------------

# Write the generated inventory to the repo's inventory/ directory so the
# playbooks (and ad-hoc ansible commands) can use it directly.
resource "local_file" "ansible_inventory" {
  content         = local.ansible_inventory
  filename        = "${path.module}/../inventory/hosts.ini"
  file_permission = "0644"
}
