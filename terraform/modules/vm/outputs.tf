output "vm_name" {
  description = "Name of the deployed virtual machine"
  value       = vsphere_virtual_machine.vm.name
}

output "ip_address" {
  description = "Management network IPv4 address"
  value       = var.ipv4_address
}

output "pod_ip_address" {
  description = "Pod network IPv4 address"
  value       = var.pod_ipv4_address
}

output "vm_id" {
  description = "vSphere managed object ID of the VM"
  value       = vsphere_virtual_machine.vm.id
}
