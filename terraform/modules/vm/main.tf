resource "vsphere_virtual_machine" "vm" {
  name             = var.vm_name
  resource_pool_id = var.resource_pool_id
  datastore_id     = var.datastore_id
  folder           = var.vm_folder

  num_cpus = var.num_cpus
  memory   = var.memory

  guest_id  = var.guest_id
  scsi_type = "pvscsi"

  # Primary NIC — management / Kubernetes API network.
  network_interface {
    network_id   = var.network_id
    adapter_type = "vmxnet3"
  }

  # Secondary NIC — Kubernetes pod/service network (Calico).
  network_interface {
    network_id   = var.pod_network_id
    adapter_type = "vmxnet3"
  }

  # Primary disk — cloned from the template and resized if needed.
  disk {
    label            = "disk0"
    size             = var.disk_size
    thin_provisioned = true
    unit_number      = 0
  }

  clone {
    template_uuid = var.template_id

    customize {
      linux_options {
        host_name = var.vm_name
        domain    = var.domain
      }

      # First NIC (ens192) — management network; carries the default gateway.
      network_interface {
        ipv4_address = var.ipv4_address
        ipv4_netmask = var.netmask
      }

      # Second NIC (ens224) — pod network; no gateway on this interface.
      network_interface {
        ipv4_address = var.pod_ipv4_address
        ipv4_netmask = var.pod_netmask
      }

      ipv4_gateway    = var.gateway
      dns_server_list = [var.dns_server]
      dns_suffix_list = [var.domain]
    }
  }

  # Wait (minutes) for VMware Tools to report a routable IP before continuing.
  wait_for_guest_net_timeout = 10
  wait_for_guest_ip_timeout  = 10

  lifecycle {
    ignore_changes = [annotation]
  }
}
