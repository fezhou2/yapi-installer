
$use_subnets_value = hiera('CONFIG_USE_SUBNETS')
$use_subnets = $use_subnets_value ? {
  'y'     => true,
  default => false,
}

$service_workers = hiera('CONFIG_SERVICE_WORKERS')

Exec { timeout => hiera('DEFAULT_EXEC_TIMEOUT') }

include ::apache

if hiera('CONFIG_HORIZON_SSL')  == 'y' {
  package { 'mod_ssl':
    ensure => installed,
  }

  Package['mod_ssl'] -> Class['::apache']
}
