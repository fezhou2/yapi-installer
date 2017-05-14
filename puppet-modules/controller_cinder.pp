import 'setup.pp'

$use_subnets_value = hiera('CONFIG_USE_SUBNETS')
$use_subnets = $use_subnets_value ? {
  'y'     => true,
  default => false,
}

$service_workers = hiera('CONFIG_SERVICE_WORKERS')

Exec { timeout => hiera('DEFAULT_EXEC_TIMEOUT') }

$cinder_rab_cfg_cinder_db_pw = hiera('CONFIG_CINDER_DB_PW')
$cinder_rab_cfg_mariadb_host = hiera('CONFIG_MARIADB_HOST_URL')

$kombu_ssl_ca_certs = hiera('CONFIG_AMQP_SSL_CACERT_FILE', undef)
$kombu_ssl_keyfile = hiera('CONFIG_CINDER_SSL_KEY', undef)
$kombu_ssl_certfile = hiera('CONFIG_CINDER_SSL_CERT', undef)

if $kombu_ssl_keyfile {
  $files_to_set_owner = [ $kombu_ssl_keyfile, $kombu_ssl_certfile ]
  file { $files_to_set_owner:
    owner   => 'cinder',
    group   => 'cinder',
    require => Class['cinder'],
    notify  => Service['cinder-api'],
  }
}

class { '::cinder':
  rabbit_host         => hiera('CONFIG_AMQP_HOST_URL'),
  rabbit_port         => hiera('CONFIG_AMQP_CLIENTS_PORT'),
  rabbit_use_ssl      => hiera('CONFIG_AMQP_SSL_ENABLED'),
  rabbit_userid       => hiera('CONFIG_AMQP_AUTH_USER'),
  rabbit_password     => hiera('CONFIG_AMQP_AUTH_PASSWORD'),
  database_connection => "${my_db_connector}://cinder:${cinder_rab_cfg_cinder_db_pw}@${cinder_rab_cfg_mariadb_host}/cinder",
  verbose             => true,
  debug               => hiera('CONFIG_DEBUG_MODE'),
  kombu_ssl_ca_certs  => $kombu_ssl_ca_certs,
  kombu_ssl_keyfile   => $kombu_ssl_keyfile,
  kombu_ssl_certfile  => $kombu_ssl_certfile,
}
cinder_config {
  'DEFAULT/glance_host': value => hiera('CONFIG_STORAGE_HOST_URL');
}

$bind_host = hiera('CONFIG_IP_VERSION') ? {
  'ipv6'  => '::0',
  default => '0.0.0.0',
  # TO-DO(mmagr): Add IPv6 support when hostnames are used
}

class { '::cinder::api':
  bind_host               => $bind_host,
  keystone_password       => hiera('CONFIG_CINDER_KS_PW'),
  keystone_tenant         => 'services',
  keystone_user           => 'cinder',
  auth_uri                => hiera('CONFIG_KEYSTONE_PUBLIC_URL'),
  identity_uri            => hiera('CONFIG_KEYSTONE_ADMIN_URL'),
  nova_catalog_info       => 'compute:nova:publicURL',
  nova_catalog_admin_info => 'compute:nova:adminURL',
  service_workers         => $service_workers
}

class { '::cinder::scheduler': }

class { '::cinder::volume': }

class { '::cinder::client': }

$cinder_keystone_admin_username = hiera('CONFIG_KEYSTONE_ADMIN_USERNAME')
$cinder_keystone_admin_password = hiera('CONFIG_KEYSTONE_ADMIN_PW')
$cinder_keystone_auth_url = hiera('CONFIG_KEYSTONE_PUBLIC_URL')
$cinder_keystone_api = hiera('CONFIG_KEYSTONE_API_VERSION')

# Cinder::Type requires keystone credentials
Cinder::Type {
  os_password    => hiera('CONFIG_CINDER_KS_PW'),
  os_tenant_name => 'services',
  os_username    => 'cinder',
  os_auth_url    => hiera('CONFIG_KEYSTONE_PUBLIC_URL'),
}

class { '::cinder::backends':
  enabled_backends => hiera_array('CONFIG_CINDER_BACKEND'),
}

$db_purge = hiera('CONFIG_CINDER_DB_PURGE_ENABLE')
if $db_purge {
  class { '::cinder::cron::db_purge':
    hour        => '*/24',
    destination => '/dev/null',
    age         => 1
  }
}
$create_cinder_volume = hiera('CONFIG_CINDER_VOLUMES_CREATE')

if $create_cinder_volume == 'y' {
    class { '::cinder::setup_test_volume':
      size            => hiera('CONFIG_CINDER_VOLUMES_SIZE'),
      loopback_device => '/dev/loop2',
      volume_path     => '/var/lib/cinder',
      volume_name     => 'cinder-volumes',
    } ->

    file {'/var/lib/cinder':
      ensure  => directory,
      mode    => "0600",
      recurse => true,
    }

    # Add loop device on boot
    $el_releases = ['RedHat', 'CentOS', 'Scientific']
    if $::operatingsystem in $el_releases and (versioncmp($::operatingsystemmajrelease, '7') < 0) {

      file_line{ 'rc.local_losetup_cinder_volume':
        path  => '/etc/rc.d/rc.local',
        match => '^.*/var/lib/cinder/cinder-volumes.*$',
        line  => 'losetup -f /var/lib/cinder/cinder-volumes && service openstack-cinder-volume restart',
      }

      file { '/etc/rc.d/rc.local':
        mode  => '0755',
      }

    } 
    elsif $::operatingsystem == 'Ubuntu'  {

      file_line{ 'rc.local_losetup_cinder_volume':
        path  => '/etc/rc.local',
        match => 'exit 0$',
        line  => 'losetup -f /var/lib/cinder/cinder-volumes && service cinder-volume restart && exit 0',
      }

      file { '/etc/rc.local':
        mode  => '0755',
      }

    } else {

      file { 'openstack-losetup':
        path    => '/usr/lib/systemd/system/openstack-losetup.service',
        before  => Service['openstack-losetup'],
        notify  => Exec['/usr/bin/systemctl daemon-reload'],
        content => '[Unit]
Description=Setup cinder-volume loop device
DefaultDependencies=false
Before=openstack-cinder-volume.service
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/bin/sh -c \'/usr/sbin/losetup -j /var/lib/cinder/cinder-volumes | /usr/bin/grep /var/lib/cinder/cinder-volumes || /usr/sbin/losetup -f /var/lib/cinder/cinder-volumes\'
ExecStop=/usr/bin/sh -c \'/usr/sbin/losetup -j /var/lib/cinder/cinder-volumes | /usr/bin/cut -d : -f 1 | /usr/bin/xargs /usr/sbin/losetup -d\'
TimeoutSec=60
RemainAfterExit=yes

[Install]
RequiredBy=openstack-cinder-volume.service',
      }

      exec { '/usr/bin/systemctl daemon-reload':
        refreshonly => true,
        before      => Service['openstack-losetup'],
      }

      service { 'openstack-losetup':
        ensure  => running,
        enable  => true,
        require => Class['cinder::setup_test_volume'],
      }

    }
}
else {
    package {'lvm2':
      ensure => 'present',
    }
}


file_line { 'snapshot_autoextend_threshold':
  path    => '/etc/lvm/lvm.conf',
  match   => '^\s*snapshot_autoextend_threshold +=.*',
  line    => '   snapshot_autoextend_threshold = 80',
  require => Package['lvm2'],
}

file_line { 'snapshot_autoextend_percent':
  path    => '/etc/lvm/lvm.conf',
  match   => '^\s*snapshot_autoextend_percent +=.*',
  line    => '   snapshot_autoextend_percent = 20',
  require => Package['lvm2'],
}

cinder::backend::iscsi { 'lvm':
  iscsi_ip_address => hiera('CONFIG_STORAGE_HOST_URL'),
  require          => Package['lvm2'],
}


# TO-DO: Remove this workaround as soon as bz#1239040 will be resolved
if $cinder_keystone_api == 'v3' {
  Exec <| title == 'cinder type-create iscsi' or title == 'cinder type-key iscsi set volume_backend_name=lvm' |> {
    environment => [
      "OS_USERNAME=${cinder_keystone_admin_username}",
      "OS_PASSWORD=${cinder_keystone_admin_password}",
      "OS_AUTH_URL=${cinder_keystone_auth_url}",
      "OS_IDENTITY_API_VERSION=${cinder_keystone_api}",
      "OS_PROJECT_NAME=admin",
      "OS_USER_DOMAIN_NAME=Default",
      "OS_PROJECT_DOMAIN_NAME=Default",
    ],
  }
}

cinder::type { 'iscsi':
  set_key   => 'volume_backend_name',
  set_value => 'lvm',
  require   => Class['cinder::api'],
}


create_resources(packstack::firewall, hiera('FIREWALL_CINDER_RULES', {}))

create_resources(packstack::firewall, hiera('FIREWALL_CINDER_API_RULES', {}))

