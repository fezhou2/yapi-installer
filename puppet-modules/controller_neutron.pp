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


class { '::neutron::server':
  database_connection => $neutron_sql_connection,
  auth_password       => $neutron_user_password,
  auth_uri            => hiera('CONFIG_KEYSTONE_PUBLIC_URL'),
  identity_uri        => hiera('CONFIG_KEYSTONE_ADMIN_URL'),
  sync_db             => true,
  enabled             => true,
  api_workers         => $service_workers,
  rpc_workers         => $service_workers
}

# TODO: FIXME: remove this hack after upstream resolves https://bugs.launchpad.net/puppet-neutron/+bug/1474961
if hiera('CONFIG_NEUTRON_VPNAAS') == 'y' {
  ensure_resource( 'package', 'neutron-vpnaas-agent', {
    name   => 'openstack-neutron-vpnaas',
    tag    => ['openstack', 'neutron-package'],
  })
  Package['neutron-vpnaas-agent'] ~> Service<| tag == 'neutron-service' |>
}
if hiera('CONFIG_NEUTRON_FWAAS') == 'y' {
    ensure_resource( 'package', 'neutron-fwaas', {
      'name'   => 'openstack-neutron-fwaas',
      'tag'    => 'openstack'
    })
  Package['neutron-fwaas'] ~> Service<| tag == 'neutron-service' |>
}
if hiera('CONFIG_LBAAS_INSTALL') == 'y' {
  ensure_resource( 'package', 'neutron-lbaas-agent', {
    name   => 'openstack-neutron-lbaas',
    tag    => ['openstack', 'neutron-package'],
  })
  Package['neutron-lbaas-agent'] ~> Service<| tag == 'neutron-service' |>
}

file { '/etc/neutron/api-paste.ini':
  ensure  => file,
  mode    => '0640',
}

Class['::neutron::server'] -> File['/etc/neutron/api-paste.ini']

$neutron_notif_cfg_ctrl_host = hiera('CONFIG_KEYSTONE_HOST_URL')

# Configure nova notifications system
class { '::neutron::server::notifications':
  username    => 'nova',
  password    => hiera('CONFIG_NOVA_KS_PW'),
  tenant_name => 'services',
  nova_url    => "http://${neutron_notif_cfg_ctrl_host}:8774/v2",
  auth_url    => hiera('CONFIG_KEYSTONE_ADMIN_URL'),
  region_name => hiera('CONFIG_KEYSTONE_REGION'),
}

if hiera('CONFIG_NEUTRON_ML2_VXLAN_GROUP') == '' {
  $vxlan_group_value = undef
} else {
  $vxlan_group_value = hiera('CONFIG_NEUTRON_ML2_VXLAN_GROUP')
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

# For cases where "neutron-db-manage upgrade" command is called
# we need to fill config file first
if defined(Exec['neutron-db-manage upgrade']) {
  Neutron_plugin_ml2<||> ->
  File['/etc/neutron/plugin.ini'] ->
  Exec['neutron-db-manage upgrade']
}
create_resources(packstack::firewall, hiera('FIREWALL_NEUTRON_SERVER_RULES', {}))


create_resources(packstack::firewall, hiera('FIREWALL_NEUTRON_TUNNEL_RULES', {}))



$start_l3_agent = hiera('CONFIG_NEUTRON_VPNAAS') ? {
    'y'     => false,
    default => true
}

class { '::neutron::agents::l3':
  interface_driver        => hiera('CONFIG_NEUTRON_L3_INTERFACE_DRIVER'),
  external_network_bridge => hiera('CONFIG_NEUTRON_L3_EXT_BRIDGE'),
  manage_service          => $start_l3_agent,
  enabled                 => $start_l3_agent,
  debug                   => hiera('CONFIG_DEBUG_MODE'),
}

if defined(Class['neutron::services::fwaas']) {
  Class['neutron::services::fwaas'] -> Class['neutron::agents::l3']
}

sysctl::value { 'net.ipv4.ip_forward':
  value => '1',
}


$agent_service = 'neutron-ovs-agent-service'

$config_neutron_ovs_bridge = hiera('CONFIG_NEUTRON_OVS_BRIDGE')

vs_bridge { $config_neutron_ovs_bridge:
  ensure  => present,
  require => Service[$agent_service],
}


$cfg_neutron_ovs_host = '172.28.185.235'
$create_bridges = true
$network_host = true

$neutron_ovs_tunnel_if = hiera('CONFIG_NEUTRON_OVS_TUNNEL_IF', undef)
if $neutron_ovs_tunnel_if {
  $ovs_agent_vxlan_cfg_neut_ovs_tun_if = force_interface($neutron_ovs_tunnel_if, $use_subnets)
} else {
  $ovs_agent_vxlan_cfg_neut_ovs_tun_if = undef
}

if $ovs_agent_vxlan_cfg_neut_ovs_tun_if != '' {
  $iface = regsubst($ovs_agent_vxlan_cfg_neut_ovs_tun_if, '[\.\-\:]', '_', 'G')
  $localip = inline_template("<%= scope.lookupvar('::ipaddress_${iface}') %>")
} else {
  $localip = $cfg_neutron_ovs_host
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

class { '::neutron::agents::ml2::ovs':
  bridge_uplinks   => $bridge_uplinks,
  bridge_mappings  => $bridge_mappings,
  enable_tunneling => hiera('CONFIG_NEUTRON_OVS_TUNNELING'),
  tunnel_types     => hiera_array('CONFIG_NEUTRON_OVS_TUNNEL_TYPES'),
  local_ip         => force_ip($localip),
  vxlan_udp_port   => hiera('CONFIG_NEUTRON_OVS_VXLAN_UDP_PORT',undef),
  l2_population    => hiera('CONFIG_NEUTRON_USE_L2POPULATION'),
  firewall_driver  => hiera('FIREWALL_DRIVER'),
}



class { '::packstack::neutron::bridge': }

file { '/etc/neutron':
   ensure => 'directory',
}

group { 'neutron':
   ensure => 'present',
}

file { '/etc/neutron/dnsmasq-neutron.conf':
  content => 'dhcp-option-force=26,8900',
  owner   => 'root',
  group   => 'neutron',
  mode    => '0640',
}

class { '::neutron::agents::dhcp':
  interface_driver    => hiera('CONFIG_NEUTRON_DHCP_INTERFACE_DRIVER'),
  debug               => hiera('CONFIG_DEBUG_MODE'),
  dnsmasq_config_file => '/etc/neutron/dnsmasq-neutron.conf',
  subscribe           => File['/etc/neutron/dnsmasq-neutron.conf'],
}


create_resources(packstack::firewall, hiera('FIREWALL_NEUTRON_DHCPIN_RULES', {}))

create_resources(packstack::firewall, hiera('FIREWALL_NEUTRON_DHCPOUT_RULES', {}))



class { '::neutron::agents::metadata':
  auth_password    => hiera('CONFIG_NEUTRON_KS_PW'),
  auth_url         => hiera('CONFIG_KEYSTONE_PUBLIC_URL'),
  auth_region      => hiera('CONFIG_KEYSTONE_REGION'),
  shared_secret    => hiera('CONFIG_NEUTRON_METADATA_PW'),
  metadata_ip      => force_ip(hiera('CONFIG_KEYSTONE_HOST_URL')),
  debug            => hiera('CONFIG_DEBUG_MODE'),
  metadata_workers => $service_workers
}

