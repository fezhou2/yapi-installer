
$use_subnets_value = hiera('CONFIG_USE_SUBNETS')
$use_subnets = $use_subnets_value ? {
  'y'     => true,
  default => false,
}

Exec { timeout => hiera('DEFAULT_EXEC_TIMEOUT') }


file { '/etc/my.cnf.d':
  ensure => 'directory',
  owner  => 'root',
  group  => 'root',
  mode   => '0755',
}

$bind_address = hiera('CONFIG_IP_VERSION') ? {
  'ipv6'  => '::0',
  default => '0.0.0.0',
  # TO-DO(mmagr): Add IPv6 support when hostnames are used
}

if $::operatingsystem == 'Ubuntu' {
    $sp  =  'upstart'
}
else {
    $sp  =  'systemd'
}

class { '::mysql::server':
#FENG:  don't use mariadb-galera-server
  package_name          => 'mariadb-server',
  restart          => true,
  root_password    => hiera('CONFIG_MARIADB_PW'),
  service_provider   => $sp,
  #require          => Package['mysql-server'],
  override_options => {
    'mysqld' => { bind_address           => $bind_address,
                  default_storage_engine => 'InnoDB',
                  max_connections        => '1024',
                  open_files_limit       => '-1',
    },
  },
}

# deleting database users for security
# this is done in mysql::server::account_security but has problems
# when there is no fqdn, so we're defining a slightly different one here
mysql_user { [ 'root@127.0.0.1', 'root@::1', '@localhost', '@%' ]:
  ensure  => 'absent',
  require => Class['mysql::server'],
}

if ($::fqdn != '' and $::fqdn != 'localhost') {
  mysql_user { [ "root@${::fqdn}", "@${::fqdn}"]:
    ensure  => 'absent',
    require => Class['mysql::server'],
  }
}
if ($::fqdn != $::hostname and $::hostname != 'localhost') {
  mysql_user { ["root@${::hostname}", "@${::hostname}"]:
    ensure  => 'absent',
    require => Class['mysql::server'],
  }
}

class { '::keystone::db::mysql':
  user          => 'keystone_admin',
  password      => hiera('CONFIG_KEYSTONE_DB_PW'),
  allowed_hosts => '%',
  charset       => 'utf8',
}

class { '::nova::db::mysql':
  password      => hiera('CONFIG_NOVA_DB_PW'),
  host          => '%',
  allowed_hosts => '%',
  charset       => 'utf8',
}

class { '::cinder::db::mysql':
  password      => hiera('CONFIG_CINDER_DB_PW'),
  host          => '%',
  allowed_hosts => '%',
  charset       => 'utf8',
}

class { '::glance::db::mysql':
  password      => hiera('CONFIG_GLANCE_DB_PW'),
  host          => '%',
  allowed_hosts => '%',
  charset       => 'utf8',
}

class { '::neutron::db::mysql':
  password      => hiera('CONFIG_NEUTRON_DB_PW'),
  host          => '%',
  allowed_hosts => '%',
  dbname        => hiera('CONFIG_NEUTRON_L2_DBNAME'),
  charset       => 'utf8',
}

class { '::heat::db::mysql':
  password      => hiera('CONFIG_HEAT_DB_PW'),
  host          => '%',
  allowed_hosts => '%',
  charset       => 'utf8',
}

create_resources(packstack::firewall, hiera('FIREWALL_MARIADB_RULES', {}))

