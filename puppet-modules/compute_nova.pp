import 'setup.pp'

$use_subnets_value = hiera('CONFIG_USE_SUBNETS')
$use_subnets = $use_subnets_value ? {
  'y'     => true,
  default => false,
}

$service_workers = hiera('CONFIG_SERVICE_WORKERS')

Exec { timeout => hiera('DEFAULT_EXEC_TIMEOUT') }
$nova_db_pw = hiera('CONFIG_NOVA_DB_PW')
$nova_mariadb_host = hiera('CONFIG_MARIADB_HOST_URL')

$private_key = {
  'type' => hiera('NOVA_MIGRATION_KEY_TYPE'),
  key  => hiera('NOVA_MIGRATION_KEY_SECRET'),
}
$public_key = {
  'type' => hiera('NOVA_MIGRATION_KEY_TYPE'),
  key  => hiera('NOVA_MIGRATION_KEY_PUBLIC'),
}

$kombu_ssl_ca_certs = hiera('CONFIG_AMQP_SSL_CACERT_FILE', undef)
$kombu_ssl_keyfile = hiera('CONFIG_NOVA_SSL_KEY', undef)
$kombu_ssl_certfile = hiera('CONFIG_NOVA_SSL_CERT', undef)

if $kombu_ssl_keyfile {
  $files_to_set_owner = [ $kombu_ssl_keyfile, $kombu_ssl_certfile ]
  file { $files_to_set_owner:
    owner   => 'nova',
    group   => 'nova',
    require => Package['nova-common'],
  }
  File[$files_to_set_owner] ~> Service<||>
}

$nova_common_rabbitmq_cfg_storage_host = hiera('CONFIG_STORAGE_HOST_URL')
$nova_common_notification_driver = hiera('CONFIG_CEILOMETER_INSTALL') ? {
  'y'     => [
    'nova.openstack.common.notifier.rabbit_notifier',
    'ceilometer.compute.nova_notifier'
  ],
  default => undef
}

class { '::nova':
  glance_api_servers      => "${nova_common_rabbitmq_cfg_storage_host}:9292",
  rabbit_host             => hiera('CONFIG_AMQP_HOST_URL'),
  rabbit_port             => hiera('CONFIG_AMQP_CLIENTS_PORT'),
  rabbit_use_ssl          => hiera('CONFIG_AMQP_SSL_ENABLED'),
  rabbit_userid           => hiera('CONFIG_AMQP_AUTH_USER'),
  rabbit_password         => hiera('CONFIG_AMQP_AUTH_PASSWORD'),
  verbose                 => true,
  debug                   => hiera('CONFIG_DEBUG_MODE'),
  nova_public_key         => $public_key,
  nova_private_key        => $private_key,
  kombu_ssl_ca_certs      => $kombu_ssl_ca_certs,
  kombu_ssl_keyfile       => $kombu_ssl_keyfile,
  kombu_ssl_certfile      => $kombu_ssl_certfile,
  notification_driver     => $nova_common_notification_driver,
  database_connection     => "${my_db_connector}://nova:${nova_db_pw}@${nova_mariadb_host}/nova",
  api_database_connection => "${my_db_connector}://nova_api:${nova_db_pw}@${nova_mariadb_host}/nova_api",
}
# Ensure Firewall changes happen before nova services start
# preventing a clash with rules being set by nova-compute and nova-network
Firewall <| |> -> Class['nova']

nova_config{
  'DEFAULT/metadata_host':  value => hiera('CONFIG_CONTROLLER_HOST');
}



package{ 'python-cinderclient':
  before => Class['nova'],
}

# Install the private key to be used for live migration.  This needs to be
# configured into libvirt/live_migration_uri in nova.conf.
file { '/etc/nova/ssh':
  ensure  => directory,
  owner   => root,
  group   => root,
  mode    => '0700',
  require => Package['nova-common'],
}

file { '/etc/nova/ssh/nova_migration_key':
  content => hiera('NOVA_MIGRATION_KEY_SECRET'),
  mode    => '0600',
  owner   => root,
  group   => root,
  require => File['/etc/nova/ssh'],
}

nova_config{
  'DEFAULT/volume_api_class':
    value => 'nova.volume.cinder.API';
  'libvirt/live_migration_uri':
    value => hiera('CONFIG_NOVA_COMPUTE_MIGRATE_URL');
}


class { '::nova::compute':
  enabled                       => true,
  vncproxy_host                 => hiera('CONFIG_KEYSTONE_HOST_URL'),
  vncproxy_protocol             => hiera('CONFIG_VNCPROXY_PROTOCOL'),
  vncserver_proxyclient_address => $::ipaddress,
  compute_manager               => hiera('CONFIG_NOVA_COMPUTE_MANAGER'),
  pci_passthrough               => hiera('CONFIG_NOVA_PCI_PASSTHROUGH_WHITELIST'),
}


if $::operatingsystem == 'RedHat' {

# Tune the host with a virtual hosts profile
package { 'tuned':
  ensure => present,
}

service { 'tuned':
  ensure  => running,
  require => Package['tuned'],
}

# tries/try_sleep to try and circumvent rhbz1320744
exec { 'tuned-virtual-host':
  unless    => '/usr/sbin/tuned-adm active | /bin/grep virtual-host',
  command   => '/usr/sbin/tuned-adm profile virtual-host',
  require   => Service['tuned'],
  tries     => 3,
  try_sleep => 5
}

# We need to preferably install qemu-kvm-rhev
exec { 'qemu-kvm':
  path    => '/usr/bin',
  command => 'yum install -y -d 0 -e 0 qemu-kvm',
  onlyif  => 'yum install -y -d 0 -e 0 qemu-kvm-rhev &> /dev/null && exit 1 || exit 0',
  before  => Class['nova::compute::libvirt'],
} ->
# chmod is workaround for https://bugzilla.redhat.com/show_bug.cgi?id=950436
file { '/dev/kvm':
  owner  => 'root',
  group  => 'kvm',
  mode   => '666',
  before => Class['nova::compute::libvirt'],
}

file_line { 'libvirt-guests':
  path    => '/etc/sysconfig/libvirt-guests',
  line    => 'ON_BOOT=ignore',
  match   => '^[\s#]*ON_BOOT=.*',
  require => Class['nova::compute::libvirt'],
}

}
elsif $::operatingsystem == 'Ubuntu' {
  package{ 'qemu-kvm':
    ensure => present,
  }
  file_line { 'libvirt-guests':
    path    => '/etc/default/libvirt-guests',
    line    => 'ON_BOOT=ignore',
    match   => '^[\s#]*ON_BOOT=.*',
    require => Class['nova::compute::libvirt'],
  }
}


create_resources(packstack::firewall, hiera('FIREWALL_NOVA_QEMU_MIG_RULES', {}))

Firewall <| |> -> Class['nova::compute::libvirt']

# Ensure Firewall changes happen before libvirt service start
# preventing a clash with rules being set by libvirt

if str2bool($::is_virtual) {
  $libvirt_virt_type = 'qemu'
  $libvirt_cpu_mode = 'none'
} else {
  $libvirt_virt_type = 'kvm'
}



$libvirt_vnc_bind_host = hiera('CONFIG_IP_VERSION') ? {
  'ipv6'  => '::0',
  default => '0.0.0.0',
  # TO-DO(mmagr): Add IPv6 support when hostnames are used
}

class { '::nova::compute::libvirt':
  libvirt_virt_type        => $libvirt_virt_type,
  libvirt_cpu_mode         => $libvirt_cpu_mode,
  vncserver_listen         => $libvirt_vnc_bind_host,
  migration_support        => true,
  libvirt_inject_partition => '-1',
}


# Remove libvirt's default network (usually virbr0) as it's unnecessary and
# can be confusing
exec {'virsh-net-destroy-default':
  onlyif  => '/usr/bin/virsh net-list | grep default',
  command => '/usr/bin/virsh net-destroy default',
  require => Service['libvirt'],
}

exec {'virsh-net-undefine-default':
  onlyif  => '/usr/bin/virsh net-list --inactive | grep default',
  command => '/usr/bin/virsh net-undefine default',
  require => Exec['virsh-net-destroy-default'],
}

$libvirt_debug = hiera('CONFIG_DEBUG_MODE')
if $libvirt_debug {

  file_line { '/etc/libvirt/libvirt.conf log_filters':
    path   => '/etc/libvirt/libvirtd.conf',
    line   => 'log_filters = "1:libvirt 1:qemu 1:conf 1:security 3:event 3:json 3:file 1:util"',
    match  => 'log_filters =',
    notify => Service['libvirt'],
  }

  file_line { '/etc/libvirt/libvirt.conf log_outputs':
    path   => '/etc/libvirt/libvirtd.conf',
    line   => 'log_outputs = "1:file:/var/log/libvirt/libvirtd.log"',
    match  => 'log_outputs =',
    notify => Service['libvirt'],
  }

}

create_resources(packstack::firewall, hiera('FIREWALL_NOVA_COMPUTE_RULES', {}))



create_resources(sshkey, hiera('SSH_KEYS', {}))

$nova_neutron_cfg_ctrl_host = hiera('CONFIG_KEYSTONE_HOST_URL')
$neutron_auth_url = hiera('CONFIG_KEYSTONE_ADMIN_URL')

class { '::nova::network::neutron':
  neutron_password    => hiera('CONFIG_NEUTRON_KS_PW'),
  neutron_auth_plugin => 'v3password',
  neutron_url         => "http://${nova_neutron_cfg_ctrl_host}:9696",
  neutron_project_name => 'services',
  neutron_auth_url    => "${neutron_auth_url}/v3",
  neutron_region_name => hiera('CONFIG_KEYSTONE_REGION'),
}

class { '::nova::compute::neutron':
  libvirt_vif_driver => hiera('CONFIG_NOVA_LIBVIRT_VIF_DRIVER'),
}
