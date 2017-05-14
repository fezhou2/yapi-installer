import 'setup.pp'

$use_subnets_value = hiera('CONFIG_USE_SUBNETS')
$use_subnets = $use_subnets_value ? {
  'y'     => true,
  default => false,
}

$service_workers = hiera('CONFIG_SERVICE_WORKERS')

Exec { timeout => hiera('DEFAULT_EXEC_TIMEOUT') }

$glance_ks_pw = hiera('CONFIG_GLANCE_DB_PW')
$glance_mariadb_host = hiera('CONFIG_MARIADB_HOST_URL')
$glance_cfg_ctrl_host = hiera('CONFIG_KEYSTONE_HOST_URL')

# glance option bind_host requires address without brackets
$bind_host = hiera('CONFIG_IP_VERSION') ? {
  'ipv6'  => '::0',
  default => '0.0.0.0',
  # TO-DO(mmagr): Add IPv6 support when hostnames are used
}
# magical hack for magical config - glance option registry_host requires brackets
$registry_host = hiera('CONFIG_IP_VERSION') ? {
  'ipv6'  => '[::0]',
  default => '0.0.0.0',
  # TO-DO(mmagr): Add IPv6 support when hostnames are used
}

class { '::glance::api':
  bind_host           => $bind_host,
  registry_host       => $registry_host,
  auth_uri            => hiera('CONFIG_KEYSTONE_PUBLIC_URL'),
  identity_uri        => hiera('CONFIG_KEYSTONE_ADMIN_URL'),
  keystone_tenant     => 'services',
  keystone_user       => 'glance',
  keystone_password   => hiera('CONFIG_GLANCE_KS_PW'),
  pipeline            => 'keystone',
  database_connection => "${my_db_connector}://glance:${glance_ks_pw}@${glance_mariadb_host}/glance",
  verbose             => true,
  debug               => hiera('CONFIG_DEBUG_MODE'),
  os_region_name      => hiera('CONFIG_KEYSTONE_REGION'),
  workers             => $service_workers,
  known_stores        => ['file', 'http', 'swift']
}

class { '::glance::registry':
  auth_uri            => hiera('CONFIG_KEYSTONE_PUBLIC_URL'),
  identity_uri        => hiera('CONFIG_KEYSTONE_ADMIN_URL'),
  bind_host           => $bind_host,
  keystone_tenant     => 'services',
  keystone_user       => 'glance',
  keystone_password   => hiera('CONFIG_GLANCE_KS_PW'),
  database_connection => "${my_db_connector}://glance:${glance_ks_pw}@${glance_mariadb_host}/glance",
  verbose             => true,
  debug               => hiera('CONFIG_DEBUG_MODE'),
  workers             => $service_workers
}
$kombu_ssl_ca_certs = hiera('CONFIG_AMQP_SSL_CACERT_FILE', undef)
$kombu_ssl_keyfile = hiera('CONFIG_GLANCE_SSL_KEY', undef)
$kombu_ssl_certfile = hiera('CONFIG_GLANCE_SSL_CERT', undef)

if $kombu_ssl_keyfile {
  $files_to_set_owner = [ $kombu_ssl_keyfile, $kombu_ssl_certfile ]
  file { $files_to_set_owner:
    owner   => 'glance',
    group   => 'glance',
    require => Class['::glance::notify::rabbitmq'],
    notify  => Service['glance-api'],
  }
}
class { '::glance::notify::rabbitmq':
  rabbit_host        => hiera('CONFIG_AMQP_HOST_URL'),
  rabbit_port        => hiera('CONFIG_AMQP_CLIENTS_PORT'),
  rabbit_use_ssl     => hiera('CONFIG_AMQP_SSL_ENABLED'),
  rabbit_userid      => hiera('CONFIG_AMQP_AUTH_USER'),
  rabbit_password    => hiera('CONFIG_AMQP_AUTH_PASSWORD'),
  kombu_ssl_ca_certs => $kombu_ssl_ca_certs,
  kombu_ssl_keyfile  => $kombu_ssl_keyfile,
  kombu_ssl_certfile => $kombu_ssl_certfile,
}

# TO-DO: Make this configurable
class { '::glance::backend::file':
  filesystem_store_datadir => '/var/lib/glance/images/',
}
create_resources(packstack::firewall, hiera('FIREWALL_GLANCE_RULES', {}))

