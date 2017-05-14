import 'setup.pp'

$config_sriov_enable = hiera('CONFIG_ENABLE_SRIOV', undef)

if $config_sriov_enable {
  $sriov_hardware = hiera('NODE_TYPE', undef)
  $sriov_vendor_id = hiera('SRIOV_VENDOR_ID', undef)
  $sriov_product_id = hiera('SRIOV_PRODUCT_ID', undef)
  $sriov_devname_service1 = hiera('SERVICE_IF', undef)
  $sriov_devname_service2 = hiera('SERVICE_IF_2', undef)
}


if $config_sriov_enable {
  # Add VLAN net ranges for sriov networks

  $default_tenant_vlan_range = hiera('DEFAULT_TENANT_VLAN_RANGE')

  if $sriov_devname_service2 {
    exec { 'update_ml2_vlan_net':
      command => "crudini --set /etc/neutron/plugins/ml2/ml2_conf.ini ml2_type_vlan network_vlan_ranges physnet-tenant:$default_tenant_vlan_range,physnet-service,physnet-service2",
      path    => '/usr/local/bin/:/bin:/usr/sbin:/usr/bin',
      logoutput => 'true',
    }
  }
  else {
    exec { 'update_ml2_vlan_net':
      command => "crudini --set /etc/neutron/plugins/ml2/ml2_conf.ini ml2_type_vlan network_vlan_ranges physnet-tenant:$default_tenant_vlan_range,physnet-service",
      path    => '/usr/local/bin/:/bin:/usr/sbin:/usr/bin',
      logoutput => 'true',
    }
  }
}

# Handle specific requirements for USC-C
if $config_sriov_enable and $sriov_hardware=="UCSC" {

  exec { 'update_ml2_conf_sriov':
    command => "crudini --set /etc/neutron/plugins/ml2/ml2_conf.ini ml2_sriov agent_required True;    crudini --set /etc/neutron/plugins/ml2/ml2_conf.ini ml2_sriov  supported_pci_vendor_devs $sriov_vendor_id:$sriov_product_id",
    path    => '/usr/local/bin/:/bin:/usr/sbin:/usr/bin',
    logoutput => 'true',
  }

  exec { 'update_ml2_sriovnicswitch':
    command => 'crudini --set /etc/neutron/plugins/ml2/ml2_conf.ini ml2 mechanism_drivers "openvswitch,sriovnicswitch"',
    path    => '/usr/local/bin/:/bin:/usr/sbin:/usr/bin',
    logoutput => 'true',
  }

}

# Handle specific requirements for USC-B
if $config_sriov_enable and $sriov_hardware=="UCSB" {
  package{ 'python-networking-cisco.noarch':
    ensure => present,
  }

  exec { 'update_ml2_ucsm':
    command => 'crudini --set /etc/neutron/plugins/ml2/ml2_conf.ini ml2 mechanism_drivers "openvswitch,cisco_ucsm"',
    path    => '/usr/local/bin/:/bin:/usr/sbin:/usr/bin',
    logoutput => 'true',
  }

  exec { "update_ml2_conf_cisco_service":
    command => "sed -i 's%--config-file /etc/neutron/plugin.ini%--config-file /etc/neutron/plugin.ini --config-file /etc/neutron/ml2_conf_cisco.ini%' /usr/lib/systemd/system/neutron-server.service",
    path    => '/usr/local/bin/:/bin:/usr/sbin:/usr/bin',
    logoutput => 'true',
    unless => 'grep ml2_conf_cisco /usr/lib/systemd/system/neutron-server.service',
  }

  # get UCSM plugin data from install input and update ml2_conf_cisco.ini file
  $ucsm_ip = hiera("UCSM_IP", undef)
  $ucsm_username = hiera("UCSM_USERNAME", undef)
  $ucsm_password = hiera("UCSM_PASSWORD", undef)
  $ucsm_host_list = hiera("UCSM_HOST_LIST", undef)

  exec { 'update_cisco_ucsm_data':
    command => "crudini --set /etc/neutron/ml2_conf_cisco.ini ml2_cisco_ucsm  ucsm_ip $ucsm_ip  && crudini --set /etc/neutron/ml2_conf_cisco.ini ml2_cisco_ucsm ucsm_username $ucsm_username && crudini --set /etc/neutron/ml2_conf_cisco.ini ml2_cisco_ucsm ucsm_password  $ucsm_password &&  crudini --set /etc/neutron/ml2_conf_cisco.ini ml2_cisco_ucsm  ucsm_host_list $ucsm_host_list",
    path    => '/usr/local/bin/:/bin:/usr/sbin:/usr/bin',
    logoutput => 'true',
  }

  #setup VIRTIO networks for the SRIOV NIC using the PF in case of UCS-B
  #this allows bothe VIRTIO and SRIOV to be support for the sriov interfaces

  exec {'update_sriov_interface1':
    command => "/etc/puppet/modules/nephelo/resources/convert_eth_2_ovsbr.sh $sriov_devname_service1 br-service;",
    path    => '/usr/local/bin/:/bin:/usr/sbin:/usr/bin',
    logoutput => 'true',
  }

  exec { 'update_ovs_mapping1':
    command => 'crudini --set /etc/neutron/plugins/ml2/openvswitch_agent.ini ovs bridge_mappings physnet-public:br-ex,physnet-tenant:br-tenant,physnet-service:br-service',
    path    => '/usr/local/bin/:/bin:/usr/sbin:/usr/bin',
    logoutput => 'true',
    unless  =>  'grep bridge_mappings /etc/neutron/plugins/ml2/openvswitch_agent.ini | grep physnet-service:br-service',
  }

  if $sriov_devname_service2 {
    exec {'update_sriov_interface2':
      command => "/etc/puppet/modules/nephelo/resources/convert_eth_2_ovsbr.sh $sriov_devname_service2 br-service2;",
      path    => '/usr/local/bin/:/bin:/usr/sbin:/usr/bin',
      logoutput => 'true',
    }

    exec { 'update_ovs_mapping2':
      command => 'crudini --set /etc/neutron/plugins/ml2/openvswitch_agent.ini ovs bridge_mappings physnet-public:br-ex,physnet-tenant:br-tenant,physnet-service:br-service,physnet-service2:br-service2',
      path    => '/usr/local/bin/:/bin:/usr/sbin:/usr/bin',
      logoutput => 'true',
      unless  =>  'grep bridge_mappings /etc/neutron/plugins/ml2/openvswitch_agent.ini | grep physnet-service2:br-service2 | grep physnet-service:br-service',
    }
  }
}
