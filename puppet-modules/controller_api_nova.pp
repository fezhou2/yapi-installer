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
  # metadata_host has to be IP
  'DEFAULT/metadata_host':         value => force_ip(hiera('CONFIG_CONTROLLER_HOST'));
}



require 'keystone::python'
$bind_host = hiera('CONFIG_IP_VERSION') ? {
  'ipv6'  => '::0',
  default => '0.0.0.0',
  # TO-DO(mmagr): Add IPv6 support when hostnames are used
}

$config_use_neutron = hiera('CONFIG_NEUTRON_INSTALL')
if $config_use_neutron == 'y' {
    $default_floating_pool = 'public'
} else {
    $default_floating_pool = 'nova'
}

define u_db( $user, $password ) {
   exec { "create-${name}-db":
     unless => "/usr/bin/mysql -u${user} -p${password}  ${name}",
     command => "/usr/bin/mysql --defaults-file=/root/.my.cnf -uroot -e \"create database ${name}; grant all privileges on ${name}.* to '${user}'@'localhost' identified by '${password}'; grant all privileges on ${name}.* to '${user}'@'%' identified by '${password}';\"",
    path    => '/usr/local/bin/:/bin:/usr/sbin:/usr/bin',
    logoutput => 'true',
   }
}

u_db { "nova_api":
   user => "nova_api",
   password =>  hiera('CONFIG_NOVA_DB_PW')
}

class { '::nova::api':
  api_bind_address                     => $bind_host,
  metadata_listen                      => $bind_host,
  enabled                              => true,
  auth_uri                             => hiera('CONFIG_KEYSTONE_PUBLIC_URL'),
  identity_uri                         => hiera('CONFIG_KEYSTONE_ADMIN_URL'),
  admin_password                       => hiera('CONFIG_NOVA_KS_PW'),
  neutron_metadata_proxy_shared_secret => hiera('CONFIG_NEUTRON_METADATA_PW_UNQUOTED', undef),
  default_floating_pool                => $default_floating_pool,
  pci_alias                            => hiera('CONFIG_NOVA_PCI_ALIAS'),
  sync_db_api                          => true,
  osapi_compute_workers                => $service_workers,
  metadata_workers                     => $service_workers
}

Package<| title == 'nova-common' |> -> Class['nova::api']

$db_purge = hiera('CONFIG_NOVA_DB_PURGE_ENABLE')
if $db_purge {
  class { '::nova::cron::archive_deleted_rows':
    hour        => '*/12',
    destination => '/dev/null',
  }
}
create_resources(packstack::firewall, hiera('FIREWALL_NOVA_API_RULES', {}))


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
