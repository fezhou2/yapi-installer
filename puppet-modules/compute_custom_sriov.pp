import 'setup.pp'

$config_sriov_enable = hiera('CONFIG_ENABLE_SRIOV', undef)

if $config_sriov_enable {
  $sriov_hardware = hiera('NODE_TYPE', undef)
  $sriov_vendor_id = hiera('SRIOV_VENDOR_ID', undef)
  $sriov_product_id = hiera('SRIOV_PRODUCT_ID', undef)
  $sriov_devname_service1 = hiera('SERVICE_IF', undef)
  $sriov_devname_service2 = hiera('SERVICE_IF_2', undef)
  $sriov_pci_addr_service1 = chomp(generate('/etc/puppet/modules/nephelo/resources/get_nic_pci_addr', $sriov_devname_service1))
  $sriov_pci_patt_service1 = chomp(generate('/etc/puppet/modules/nephelo/resources/get_nic_pci_patt', $sriov_devname_service1))
  if $sriov_devname_service2 {
    $sriov_pci_addr_service2 = chomp(generate('/etc/puppet/modules/nephelo/resources/get_nic_pci_addr', $sriov_devname_service2))
    $sriov_pci_patt_service2 = chomp(generate('/etc/puppet/modules/nephelo/resources/get_nic_pci_patt', $sriov_devname_service2))
  }

  exec { "update_grub_iommu":
    command => $grub_command,
    path    => '/usr/local/bin/:/bin:/usr/sbin:/usr/bin',
    logoutput => 'true',
    unless => 'grep intel_iommu /etc/default/grub',
  }


  if $sriov_devname_service2 {
    exec { 'update_nova_pci_whitelist2':
      command => "crudini --set /etc/nova/nova.conf DEFAULT pci_passthrough_whitelist \'[{\"vendor_id\":\"$sriov_vendor_id\",\"product_id\":\"$sriov_product_id\",\"address\":\"$sriov_pci_patt_service1\",\"physical_network\":\"physnet-service\"}, {\"vendor_id\":\"$sriov_vendor_id\",\"product_id\":\"$sriov_product_id\",\"address\":\"$sriov_pci_patt_service2\",\"physical_network\":\"physnet-service2\"}]\'",
      path    => '/usr/local/bin/:/bin:/usr/sbin:/usr/bin',
      logoutput => 'true',
      unless  => "grep physnet-service2 /etc/nova/nova.conf | grep pci_passthrough_whitelist",
    }
    exec { 'update_sriov_physnet_mapping':
      command => "crudini --set /etc/neutron/plugins/ml2/sriov_agent.ini sriov_nic physical_device_mappings physnet-service:$sriov_devname_service1,physnet-service2:$sriov_devname_service2",
      path    => '/usr/local/bin/:/bin:/usr/sbin:/usr/bin',
      logoutput => 'true',
    }
  }
  else {
    exec { 'update_nova_pci_whitelist1':
      command => "crudini --set /etc/nova/nova.conf DEFAULT pci_passthrough_whitelist \'[{\"vendor_id\":\"$sriov_vendor_id\",\"product_id\":\"$sriov_product_id\",\"address\":\"$sriov_pci_patt_service1\",\"physical_network\":\"physnet-service\"}]\'",
      path    => '/usr/local/bin/:/bin:/usr/sbin:/usr/bin',
      logoutput => 'true',
      unless  => "grep physnet-service /etc/nova/nova.conf | grep pci_passthrough_whitelist",
    }
    exec { 'update_sriov_physnet_mapping':
      command => "crudini --set /etc/neutron/plugins/ml2/sriov_agent.ini sriov_nic physical_device_mappings physnet-service:$sriov_devname_service1",
      path    => '/usr/local/bin/:/bin:/usr/sbin:/usr/bin',
      logoutput => 'true',
    }
  }
}

if $config_sriov_enable and $sriov_hardware!="UCSB" {
  package { 'neutron-sriov-agent-pkg':
    name => $neutron_sriov_package,
    ensure => 'installed',
  } ->
  service { 'neutron-sriov-agent-service':
    name => $neutron_sriov_service,
    ensure => running,
    enable => true,
  }

  exec { 'update_sriov_firewall_driver':
    command => "crudini --set /etc/neutron/plugins/ml2/sriov_agent.ini securitygroup firewall_driver  neutron.agent.firewall.NoopFirewallDriver",
    path    => '/usr/local/bin/:/bin:/usr/sbin:/usr/bin',
    logoutput => 'true',
  }
  file_line { "rc.sriov-network":
    ensure => 'present',
    path => $rc_local_file,
    line => "sleep 15; echo 8 > /sys/bus/pci/devices/$sriov_pci_addr_service1/sriov_numvfs; systemctl restart $neutron_sriov_service",
    after => '^# By default this script does nothing',
  }

  if $sriov_devname_service2 {
    file_line { "rc.sriov-network2":
      ensure => 'present',
      path =>  $rc_local_file,
      line => "sleep 15; echo 8 > /sys/bus/pci/devices/$sriov_pci_addr_service2/sriov_numvfs",
      after => '^# By default this script does nothing',
    }
  }

  if $config_sriov_enable and $sriov_hardware=="UCSB" {
    #setup VIRTIO networks for the SRIOV NIC using the PF in case of UCS-B
    #this allows bothe VIRTIO and SRIOV to be support for the sriov interfaces

    exec {'update_sriov_interface1':
      command => "/etc/puppet/modules/nephelo/resources/convert_eth_2_ovsbr.sh $sriov_devname_service1 br-service",
      path    => '/usr/local/bin/:/bin:/usr/sbin:/usr/bin',
      logoutput => 'true',
    }

    exec { 'update_ovs_mapping1':
      command => 'crudini --set /etc/neutron/plugins/ml2/openvswitch_agent.ini ovs bridge_mappings physnet-tenant:br-tenant,physnet-service:br-service',
      path    => '/usr/local/bin/:/bin:/usr/sbin:/usr/bin',
      logoutput => 'true',
      unless  =>  'grep bridge_mappings /etc/neutron/plugins/ml2/openvswitch_agent.ini | grep physnet-service:br-service',
    }

    if $sriov_devname_service2 {
      exec {'update_sriov_interface2':
        command => "/etc/puppet/modules/nephelo/resources/convert_eth_2_ovsbr.sh $sriov_devname_service2 br-service2",
        path    => '/usr/local/bin/:/bin:/usr/sbin:/usr/bin',
        logoutput => 'true',
      }

      exec { 'update_ovs_mapping2':
        command => 'crudini --set /etc/neutron/plugins/ml2/openvswitch_agent.ini ovs bridge_mappings physnet-tenant:br-tenant,physnet-service:br-service,physnet-service2:br-service2',
        path    => '/usr/local/bin/:/bin:/usr/sbin:/usr/bin',
        logoutput => 'true',
        unless  =>  'grep bridge_mappings /etc/neutron/plugins/ml2/openvswitch_agent.ini | grep physnet-service2:br-service2| grep physnet-service:br-service',
      }
    }

    # get update UCSM on controller for host list if new host is added
    $ucsm_host_list = hiera("UCSM_HOST_LIST", undef)
    $controller_host = hiera("CONTROLLER_IP", undef)

    exec { 'update_cisco_ucsm_data':
      command => "ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no  root@$controller_host crudini --set /etc/neutron/ml2_conf_cisco.ini ml2_cisco_ucsm  ucsm_host_list $ucsm_host_list && ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no  root@$controller_host openstack-service restart neutron",
      path    => '/usr/local/bin/:/bin:/usr/sbin:/usr/bin',
      logoutput => 'true',
      unless => "ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no  root@$controller_host grep $ucsm_host_list /etc/neutron/ml2_conf_cisco.ini",
    }
  }
}
