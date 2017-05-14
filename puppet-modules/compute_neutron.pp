import 'setup.pp'

$use_subnets_value = hiera('CONFIG_USE_SUBNETS')
$use_subnets = $use_subnets_value ? {
  'y'     => true,
  default => false,
}

$service_workers = hiera('CONFIG_SERVICE_WORKERS')

Exec { timeout => hiera('DEFAULT_EXEC_TIMEOUT') }

$neutron_db_host         = hiera('CONFIG_MARIADB_HOST_URL')
$neutron_db_name         = hiera('CONFIG_NEUTRON_L2_DBNAME')
$neutron_db_user         = 'neutron'
$neutron_db_password     = hiera('CONFIG_NEUTRON_DB_PW')
$neutron_sql_connection  = "${my_db_connector}://${neutron_db_user}:${neutron_db_password}@${neutron_db_host}/${neutron_db_name}"
$neutron_user_password   = hiera('CONFIG_NEUTRON_KS_PW')


$bind_host = hiera('CONFIG_IP_VERSION') ? {
  'ipv6'  => '::0',
  default => '0.0.0.0',
  # TO-DO(mmagr): Add IPv6 support when hostnames are used
}

$kombu_ssl_ca_certs = hiera('CONFIG_AMQP_SSL_CACERT_FILE', undef)
$kombu_ssl_keyfile = hiera('CONFIG_NEUTRON_SSL_KEY', undef)
$kombu_ssl_certfile = hiera('CONFIG_NEUTRON_SSL_CERT', undef)

if $kombu_ssl_keyfile {
  $files_to_set_owner = [ $kombu_ssl_keyfile, $kombu_ssl_certfile ]
  file { $files_to_set_owner:
    owner   => 'neutron',
    group   => 'neutron',
    require => Class['neutron'],
  }
  File[$files_to_set_owner] ~> Service<||>
}


class { '::neutron':
  bind_host             => $bind_host,
  rabbit_host           => hiera('CONFIG_AMQP_HOST_URL'),
  rabbit_port           => hiera('CONFIG_AMQP_CLIENTS_PORT'),
  rabbit_use_ssl        => hiera('CONFIG_AMQP_SSL_ENABLED'),
  rabbit_user           => hiera('CONFIG_AMQP_AUTH_USER'),
  rabbit_password       => hiera('CONFIG_AMQP_AUTH_PASSWORD'),
  core_plugin           => hiera('CONFIG_NEUTRON_CORE_PLUGIN'),
  allow_overlapping_ips => true,
  service_plugins       => hiera_array('SERVICE_PLUGINS'),
  verbose               => true,
  debug                 => hiera('CONFIG_DEBUG_MODE'),
  kombu_ssl_ca_certs  => $kombu_ssl_ca_certs,
  kombu_ssl_keyfile   => $kombu_ssl_keyfile,
  kombu_ssl_certfile  => $kombu_ssl_certfile,
}

create_resources(packstack::firewall, hiera('FIREWALL_NEUTRON_TUNNEL_RULES', {}))

$create_bridges = true
$network_host = false

$neutron_ovs_tunnel_if = hiera('CONFIG_NEUTRON_OVS_TUNNEL_IF', undef)
if $neutron_ovs_tunnel_if {
  $ovs_agent_vxlan_cfg_neut_ovs_tun_if = force_interface($neutron_ovs_tunnel_if, $use_subnets)
} else {
  $ovs_agent_vxlan_cfg_neut_ovs_tun_if = undef
}


if $network_host {
  $bridge_ifaces_param = 'CONFIG_NEUTRON_OVS_BRIDGE_IFACES'
  $bridge_mappings_param = 'CONFIG_NEUTRON_OVS_BRIDGE_MAPPINGS'
} else {
  $bridge_ifaces_param = 'CONFIG_NEUTRON_OVS_BRIDGE_IFACES_COMPUTE'
  $bridge_mappings_param = 'CONFIG_NEUTRON_OVS_BRIDGE_MAPPINGS_COMPUTE'
}

if $create_bridges {
  $bridge_uplinks  = hiera_array($bridge_ifaces_param)
  $bridge_mappings = hiera_array($bridge_mappings_param)
} else {
  $bridge_uplinks  = []
  $bridge_mappings = []
}


class { '::neutron::plugins::ml2':
  type_drivers              => hiera_array('CONFIG_NEUTRON_ML2_TYPE_DRIVERS'),
  tenant_network_types      => hiera_array('CONFIG_NEUTRON_ML2_TENANT_NETWORK_TYPES'),
  mechanism_drivers         => hiera_array('CONFIG_NEUTRON_ML2_MECHANISM_DRIVERS'),
  flat_networks             => hiera_array('CONFIG_NEUTRON_ML2_FLAT_NETWORKS'),
  network_vlan_ranges       => hiera_array('CONFIG_NEUTRON_ML2_VLAN_RANGES'),
  tunnel_id_ranges          => hiera_array('CONFIG_NEUTRON_ML2_TUNNEL_ID_RANGES'),
  vxlan_group               => $vxlan_group_value,
  vni_ranges                => hiera_array('CONFIG_NEUTRON_ML2_VNI_RANGES'),
  enable_security_group     => true,
  firewall_driver           => hiera('FIREWALL_DRIVER'),
  supported_pci_vendor_devs => hiera_array('CONFIG_NEUTRON_ML2_SUPPORTED_PCI_VENDOR_DEVS'),
  sriov_agent_required      => hiera('CONFIG_NEUTRON_ML2_SRIOV_AGENT_REQUIRED'),
}


class { '::neutron::agents::ml2::ovs':
  bridge_uplinks   => $bridge_uplinks,
  bridge_mappings  => $bridge_mappings,
  enable_tunneling => hiera('CONFIG_NEUTRON_OVS_TUNNELING'),
  tunnel_types     => hiera_array('CONFIG_NEUTRON_OVS_TUNNEL_TYPES'),
  local_ip         => $::ipaddress,
  vxlan_udp_port   => hiera('CONFIG_NEUTRON_OVS_VXLAN_UDP_PORT',undef),
  l2_population    => hiera('CONFIG_NEUTRON_USE_L2POPULATION'),
  firewall_driver  => hiera('FIREWALL_DRIVER'),
}



class { '::packstack::neutron::bridge': }

