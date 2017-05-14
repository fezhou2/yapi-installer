import 'setup.pp'

$use_subnets_value = hiera('CONFIG_USE_SUBNETS')
$use_subnets = $use_subnets_value ? {
  'y'     => true,
  default => false,
}

$service_workers = hiera('CONFIG_SERVICE_WORKERS')

Exec { timeout => hiera('DEFAULT_EXEC_TIMEOUT') }

$keystone_use_ssl = false
$keystone_cfg_ks_db_pw = hiera('CONFIG_KEYSTONE_DB_PW')
$keystone_cfg_mariadb_host = hiera('CONFIG_MARIADB_HOST_URL')
$keystone_token_provider_str = downcase(hiera('CONFIG_KEYSTONE_TOKEN_FORMAT'))
$keystone_url = regsubst(regsubst(hiera('CONFIG_KEYSTONE_PUBLIC_URL'),'/v2.0',''),'/v3','')
$keystone_admin_url = hiera('CONFIG_KEYSTONE_ADMIN_URL')

$bind_host = hiera('CONFIG_IP_VERSION') ? {
  'ipv6'  => '::0',
  default => '0.0.0.0',
  # TO-DO(mmagr): Add IPv6 support when hostnames are used
}

if hiera('CONFIG_KEYSTONE_SERVICE_NAME') == 'keystone' {
  $keystone_service_name = 'openstack-keystone'
} else {
  $keystone_service_name = 'httpd'
}

class { '::keystone::client': }

if hiera('CONFIG_KEYSTONE_DB_PURGE_ENABLE',false) {
  class { '::keystone::cron::token_flush':
    minute      => '*/1',
    require     => Service['crond'],
    destination => '/dev/null',
  }
  service { 'crond':
    ensure => 'running',
    enable => true,
  }
}

class { '::keystone':
  admin_token         => hiera('CONFIG_KEYSTONE_ADMIN_TOKEN'),
  database_connection => "${my_db_connector}://keystone_admin:${keystone_cfg_ks_db_pw}@${keystone_cfg_mariadb_host}/keystone",
  token_provider      => "keystone.token.providers.${keystone_token_provider_str}.Provider",
  verbose             => true,
  debug               => hiera('CONFIG_DEBUG_MODE'),
  service_name        => $keystone_service_name,
  enable_ssl          => $keystone_use_ssl,
  public_bind_host    => $bind_host,
  service_provider    => $my_service_provider,
  admin_bind_host     => $bind_host,
  default_domain      => 'Default',
}

if $keystone_service_name == 'httpd' {
  class { '::apache':
    purge_configs => false,
  }

  class { '::keystone::wsgi::apache':
    workers => $service_workers,
    ssl     => $keystone_use_ssl
  }
}

class { '::keystone::roles::admin':
  email        => hiera('CONFIG_KEYSTONE_ADMIN_EMAIL'),
  admin        => hiera('CONFIG_KEYSTONE_ADMIN_USERNAME'),
  password     => hiera('CONFIG_KEYSTONE_ADMIN_PW'),
  admin_tenant => 'admin',
}

# Ensure the default _member_ role is present
keystone_role { '_member_':
  ensure => present,
}

class { '::keystone::endpoint':
  default_domain => 'Default',
  public_url     => $keystone_url,
  internal_url   => $keystone_url,
  admin_url      => $keystone_admin_url,
  region         => hiera('CONFIG_KEYSTONE_REGION'),
  # so far enforce v2 as default endpoint
  version        => 'v2.0',
}

# default assignment driver is SQL
$assignment_driver = 'keystone.assignment.backends.sql.Assignment'

if hiera('CONFIG_KEYSTONE_IDENTITY_BACKEND') == 'ldap' {

  if hiera_undef('CONFIG_KEYSTONE_LDAP_USER_ENABLED_EMULATION_DN', undef) {
    $user_enabled_emulation = true
  } else {
    $user_enabled_emulation = false
  }

  class { '::keystone::ldap':
    url                                => hiera_undef('CONFIG_KEYSTONE_LDAP_URL', undef),
    user                               => hiera_undef('CONFIG_KEYSTONE_LDAP_USER_DN', undef),
    password                           => hiera_undef('CONFIG_KEYSTONE_LDAP_USER_PASSWORD', undef),
    suffix                             => hiera_undef('CONFIG_KEYSTONE_LDAP_SUFFIX', undef),
    query_scope                        => hiera_undef('CONFIG_KEYSTONE_LDAP_QUERY_SCOPE', undef),
    page_size                          => hiera_undef('CONFIG_KEYSTONE_LDAP_PAGE_SIZE', undef),
    user_tree_dn                       => hiera_undef('CONFIG_KEYSTONE_LDAP_USER_SUBTREE', undef),
    user_filter                        => hiera_undef('CONFIG_KEYSTONE_LDAP_USER_FILTER', undef),
    user_objectclass                   => hiera_undef('CONFIG_KEYSTONE_LDAP_USER_OBJECTCLASS', undef),
    user_id_attribute                  => hiera_undef('CONFIG_KEYSTONE_LDAP_USER_ID_ATTRIBUTE', undef),
    user_name_attribute                => hiera_undef('CONFIG_KEYSTONE_LDAP_USER_NAME_ATTRIBUTE', undef),
    user_mail_attribute                => hiera_undef('CONFIG_KEYSTONE_LDAP_USER_MAIL_ATTRIBUTE', undef),
    user_enabled_attribute             => hiera_undef('CONFIG_KEYSTONE_LDAP_USER_ENABLED_ATTRIBUTE', undef),
    user_enabled_mask                  => hiera_undef('CONFIG_KEYSTONE_LDAP_USER_ENABLED_MASK', undef),
    user_enabled_default               => hiera_undef('CONFIG_KEYSTONE_LDAP_USER_ENABLED_DEFAULT', undef),
    user_enabled_invert                => hiera_undef('CONFIG_KEYSTONE_LDAP_USER_ENABLED_INVERT', undef),
    user_attribute_ignore              => hiera_undef('CONFIG_KEYSTONE_LDAP_USER_ATTRIBUTE_IGNORE', undef),
    user_default_project_id_attribute  => hiera_undef('CONFIG_KEYSTONE_LDAP_USER_DEFAULT_PROJECT_ID_ATTRIBUTE', undef),
    user_allow_create                  => hiera_undef('CONFIG_KEYSTONE_LDAP_USER_ALLOW_CREATE', undef),
    user_allow_update                  => hiera_undef('CONFIG_KEYSTONE_LDAP_USER_ALLOW_UPDATE', undef),
    user_allow_delete                  => hiera_undef('CONFIG_KEYSTONE_LDAP_USER_ALLOW_DELETE', undef),
    user_pass_attribute                => hiera_undef('CONFIG_KEYSTONE_LDAP_USER_PASS_ATTRIBUTE', undef),
    user_enabled_emulation             => $user_enabled_emulation,
    user_enabled_emulation_dn          => hiera_undef('CONFIG_KEYSTONE_LDAP_USER_ENABLED_EMULATION_DN', undef),
    user_additional_attribute_mapping  => hiera_undef('CONFIG_KEYSTONE_LDAP_USER_ADDITIONAL_ATTRIBUTE_MAPPING', undef),
    group_tree_dn                      => hiera_undef('CONFIG_KEYSTONE_LDAP_GROUP_SUBTREE', undef),
    group_filter                       => hiera_undef('CONFIG_KEYSTONE_LDAP_GROUP_FILTER', undef),
    group_objectclass                  => hiera_undef('CONFIG_KEYSTONE_LDAP_GROUP_OBJECTCLASS', undef),
    group_id_attribute                 => hiera_undef('CONFIG_KEYSTONE_LDAP_GROUP_ID_ATTRIBUTE', undef),
    group_name_attribute               => hiera_undef('CONFIG_KEYSTONE_LDAP_GROUP_NAME_ATTRIBUTE', undef),
    group_member_attribute             => hiera_undef('CONFIG_KEYSTONE_LDAP_GROUP_MEMBER_ATTRIBUTE', undef),
    group_desc_attribute               => hiera_undef('CONFIG_KEYSTONE_LDAP_GROUP_DESC_ATTRIBUTE', undef),
    group_attribute_ignore             => hiera_undef('CONFIG_KEYSTONE_LDAP_GROUP_ATTRIBUTE_IGNORE', undef),
    group_allow_create                 => hiera_undef('CONFIG_KEYSTONE_LDAP_GROUP_ALLOW_CREATE', undef),
    group_allow_update                 => hiera_undef('CONFIG_KEYSTONE_LDAP_GROUP_ALLOW_UPDATE', undef),
    group_allow_delete                 => hiera_undef('CONFIG_KEYSTONE_LDAP_GROUP_ALLOW_DELETE', undef),
    group_additional_attribute_mapping => hiera_undef('CONFIG_KEYSTONE_LDAP_GROUP_ADDITIONAL_ATTRIBUTE_MAPPING', undef),
    use_tls                            => hiera_undef('CONFIG_KEYSTONE_LDAP_USE_TLS', undef),
    tls_cacertdir                      => hiera_undef('CONFIG_KEYSTONE_LDAP_TLS_CACERTDIR', undef),
    tls_cacertfile                     => hiera_undef('CONFIG_KEYSTONE_LDAP_TLS_CACERTFILE', undef),
    tls_req_cert                       => hiera_undef('CONFIG_KEYSTONE_LDAP_TLS_REQ_CERT', undef),
    identity_driver                    => 'keystone.identity.backends.ldap.Identity',
    assignment_driver                  => $assignment_driver,
  }
}
if hiera('CONFIG_HORIZON_SSL')  == 'y' {
  apache::listen { '443': }
}

if hiera('CONFIG_KEYSTONE_SERVICE_NAME') == 'httpd' {
  apache::listen { '5000': }
  apache::listen { '35357': }
}

if hiera('CONFIG_CEILOMETER_INSTALL') == 'y' {
  if hiera('CONFIG_CEILOMETER_SERVICE_NAME') == 'httpd' {
    apache::listen { '8777': }
  }
}

if hiera('CONFIG_AODH_INSTALL') == 'y' {
  apache::listen { '8042': }
}

if hiera('CONFIG_GNOCCHI_INSTALL') == 'y' {
  apache::listen { '8041': }
}

create_resources(packstack::firewall, hiera('FIREWALL_KEYSTONE_RULES', {}))


$glance_protocol = 'http'
$glance_port = '9292'
$glance_api_host = hiera('CONFIG_STORAGE_HOST_URL')
$glance_url = "${glance_protocol}://${glance_api_host}:${glance_port}"

class { '::glance::keystone::auth':
  region       => hiera('CONFIG_KEYSTONE_REGION'),
  password     => hiera('CONFIG_GLANCE_KS_PW'),
  public_url   => $glance_url,
  admin_url    => $glance_url,
  internal_url => $glance_url,
}

$cinder_protocol = 'http'
$cinder_host = hiera('CONFIG_STORAGE_HOST_URL')
$cinder_port = '8776'
$cinder_url = "${cinder_protocol}://${cinder_host}:$cinder_port"

class { '::cinder::keystone::auth':
  region          => hiera('CONFIG_KEYSTONE_REGION'),
  password        => hiera('CONFIG_CINDER_KS_PW'),
  public_url      => "${cinder_url}/v1/%(tenant_id)s",
  internal_url    => "${cinder_url}/v1/%(tenant_id)s",
  admin_url       => "${cinder_url}/v1/%(tenant_id)s",
  public_url_v2   => "${cinder_url}/v2/%(tenant_id)s",
  internal_url_v2 => "${cinder_url}/v2/%(tenant_id)s",
  admin_url_v2    => "${cinder_url}/v2/%(tenant_id)s",
}


$nova_protocol = 'http'
$nova_host = hiera('CONFIG_KEYSTONE_HOST_URL')
$nova_port = '8774'
$nova_url = "${nova_protocol}://${nova_host}:$nova_port/v2/%(tenant_id)s"
$nova_v3_url = "${nova_protocol}://${nova_host}:$nova_port/v3"

class { '::nova::keystone::auth':
  region          => hiera('CONFIG_KEYSTONE_REGION'),
  password        => hiera('CONFIG_NOVA_KS_PW'),
  public_url      => $nova_url,
  admin_url       => $nova_url,
  internal_url    => $nova_url,
  public_url_v3   => $nova_v3_url,
  admin_url_v3    => $nova_v3_url,
  internal_url_v3 => $nova_v3_url,
}

$neutron_protocol = 'http'
$neutron_host = hiera('CONFIG_KEYSTONE_HOST_URL')
$neutron_port = '9696'
$neutron_url = "${neutron_protocol}://${neutron_host}:$neutron_port"

class { '::neutron::keystone::auth':
  region       => hiera('CONFIG_KEYSTONE_REGION'),
  password     => hiera('CONFIG_NEUTRON_KS_PW'),
  public_url   => $neutron_url,
  admin_url    => $neutron_url,
  internal_url => $neutron_url,
}

