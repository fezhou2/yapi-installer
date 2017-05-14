
$use_subnets_value = hiera('CONFIG_USE_SUBNETS')
$use_subnets = $use_subnets_value ? {
  'y'     => true,
  default => false,
}

Exec { timeout => hiera('DEFAULT_EXEC_TIMEOUT') }

include ::firewall

package{ 'ntpdate':
  ensure => present,
}

# We don't have openstack-selinux package for Fedora
if $::operatingsystem == 'RedHat' {
  package{ 'openstack-selinux':
    ensure => present,
  }

  package { 'sos':
    ensure => present,
  }
  
  package { 'audit':
    ensure => present,
  } ->
  service { 'auditd':
    ensure => running,
    enable => true,
  }
}
else {
  package { 'sosreport':
    ensure => present,
  }
}

package { 'crudini':
  ensure => present,
}

package { 'ethtool':
  ensure => present,
}

file { '/etc/sysconfig':
  ensure => 'directory',
  owner  => 'root',
  group  => 'root',
  mode   => '0755',
}

file { '/etc/sysconfig/modules':
  ensure => 'directory',
  owner  => 'root',
  group  => 'root',
  mode   => '0755',
}

# The following kernel parameters help alleviate some RabbitMQ
# connection issues

sysctl::value { 'net.ipv4.tcp_keepalive_intvl':
  value => '1',
}

sysctl::value { 'net.ipv4.tcp_keepalive_probes':
  value => '5',
}

sysctl::value { 'net.ipv4.tcp_keepalive_time':
  value => '5',
}
