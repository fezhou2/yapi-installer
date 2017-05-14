import 'setup.pp'

$use_subnets_value = hiera('CONFIG_USE_SUBNETS')
$use_subnets = $use_subnets_value ? {
  'y'     => true,
  default => false,
}

$service_workers = hiera('CONFIG_SERVICE_WORKERS')

Exec { timeout => hiera('DEFAULT_EXEC_TIMEOUT') }

$heat_rabbitmq_cfg_heat_db_pw = hiera('CONFIG_HEAT_DB_PW')
$heat_rabbitmq_cfg_mariadb_host = hiera('CONFIG_MARIADB_HOST_URL')

$kombu_ssl_ca_certs = hiera('CONFIG_AMQP_SSL_CACERT_FILE', $::os_service_default)
$kombu_ssl_keyfile = hiera('CONFIG_HEAT_SSL_KEY', $::os_service_default)
$kombu_ssl_certfile = hiera('CONFIG_HEAT_SSL_CERT', $::os_service_default)

if ! is_service_default($kombu_ssl_keyfile) {
  $files_to_set_owner = [ $kombu_ssl_keyfile, $kombu_ssl_certfile ]
  file { $files_to_set_owner:
    owner   => 'heat',
    group   => 'heat',
    require => Package['heat-common'],
  }
  File[$files_to_set_owner] ~> Service<||>
}

class { '::heat':
  keystone_password   => hiera('CONFIG_HEAT_KS_PW'),
  auth_uri            => hiera('CONFIG_KEYSTONE_PUBLIC_URL'),
  identity_uri        => hiera('CONFIG_KEYSTONE_ADMIN_URL'),
  keystone_ec2_uri    => hiera('CONFIG_KEYSTONE_PUBLIC_URL'),
  rpc_backend         => 'rabbit',
  rabbit_host         => hiera('CONFIG_AMQP_HOST_URL'),
  rabbit_port         => hiera('CONFIG_AMQP_CLIENTS_PORT'),
  rabbit_use_ssl      => hiera('CONFIG_AMQP_SSL_ENABLED'),
  rabbit_userid       => hiera('CONFIG_AMQP_AUTH_USER'),
  rabbit_password     => hiera('CONFIG_AMQP_AUTH_PASSWORD'),
  verbose             => true,
  debug               => hiera('CONFIG_DEBUG_MODE'),
  database_connection => "${my_db_connector}://heat:${heat_rabbitmq_cfg_heat_db_pw}@${heat_rabbitmq_cfg_mariadb_host}/heat",
  kombu_ssl_ca_certs  => $kombu_ssl_ca_certs,
  kombu_ssl_keyfile   => $kombu_ssl_keyfile,
  kombu_ssl_certfile  => $kombu_ssl_certfile,
}

class { '::heat::api': }

$keystone_admin = hiera('CONFIG_KEYSTONE_ADMIN_USERNAME')
$heat_cfg_ctrl_host = hiera('CONFIG_KEYSTONE_HOST_URL')

class { '::heat::engine':
  heat_metadata_server_url      => "http://${heat_cfg_ctrl_host}:8000",
  heat_waitcondition_server_url => "http://${heat_cfg_ctrl_host}:8000/v1/waitcondition",
  heat_watch_server_url         => "http://${heat_cfg_ctrl_host}:8003",
  auth_encryption_key           => hiera('CONFIG_HEAT_AUTH_ENC_KEY'),
}

keystone_user_role { "${keystone_admin}@admin":
  ensure  => present,
  roles   => ['admin', '_member_', 'heat_stack_owner'],
  require => Class['heat::engine'],
}

class { '::heat::keystone::domain':
  auth_url          => hiera('CONFIG_KEYSTONE_PUBLIC_URL'),
  keystone_admin    => $keystone_admin,
  keystone_password => hiera('CONFIG_KEYSTONE_ADMIN_PW'),
  keystone_tenant   => 'admin',
  domain_name       => hiera('CONFIG_HEAT_DOMAIN'),
  domain_admin      => hiera('CONFIG_HEAT_DOMAIN_ADMIN'),
  domain_password   => hiera('CONFIG_HEAT_DOMAIN_PASSWORD'),
}

$heat_protocol = 'http'
$heat_port = '8004'
$heat_api_host = hiera('CONFIG_KEYSTONE_HOST_URL')
$heat_url = "${heat_protocol}://${heat_api_host}:${heat_port}/v1/%(tenant_id)s"

# heat::keystone::auth
class { '::heat::keystone::auth':
  region                    => hiera('CONFIG_KEYSTONE_REGION'),
  password                  => hiera('CONFIG_HEAT_KS_PW'),
  public_url                => $heat_url,
  admin_url                 => $heat_url,
  internal_url              => $heat_url,
  configure_delegated_roles => true,
}

$is_heat_cfn_install = hiera('CONFIG_HEAT_CFN_INSTALL')

if $is_heat_cfn_install == 'y' {
  $heat_cfn_protocol = 'http'
  $heat_cfn_port = '8000'
  $heat_cfn_api_host = hiera('CONFIG_KEYSTONE_HOST_URL')
  $heat_cfn_url = "${heat_cfn_protocol}://${heat_cfn_api_host}:${heat_cfn_port}/v1/%(tenant_id)s"

  # heat::keystone::cfn
  class { '::heat::keystone::auth_cfn':
    password         => hiera('CONFIG_HEAT_KS_PW'),
    public_url   => $heat_cfn_url,
    admin_url    => $heat_cfn_url,
    internal_url => $heat_cfn_url,
  }
}
create_resources(packstack::firewall, hiera('FIREWALL_HEAT_RULES', {}))

