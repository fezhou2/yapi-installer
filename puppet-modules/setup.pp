# OS dependent variables

if $::operatingsystem == 'Ubuntu' {
  $my_service_provider =  'upstart'
  $rc_local_file = "/etc/rc.local"
  $all_service_restart_text = 'service openvswitch-switch restart; service networking restart; service apache2 restart; service memcached restart; service mysql restart; service rabbitmq-server restart; service nova-api restart; service nova-cert restart; service nova-compute restart; service nova-conductor restart; service nova-consoleauth restart; service nova-novncproxy restart; service nova-scheduler restart; service neutron-dhcp-agent restart; service neutron-l3-agent restart; service neutron-metadata-agent restart; service neutron-ovs-cleanup restart; service neutron-openvswitch-agent restart; service neutron-server restart'
  $neutron_sriov_package =  'neutron-plugin-sriov-agent'
  $neutron_sriov_service =  'neutron-sriov-agent'
  $grub_command = 'crudini --set /etc/default/grub "" GRUB_CMDLINE_LINUX_DEFAULT \'"text intel_iommu=on"\' && update-grub'

}
else {
  $my_service_provider =  'systemd'
  $rc_local_file = "/etc/rc.d/rc.local"
  $all_service_restart_text = 'systemctl restart openvswitch; systemctl restart network; systemctl restart httpd; systemctl restart memcached ; systemctl restart mariadb; systemctl restart rabbitmq-server; openstack-service restart'
  $neutron_sriov_package =  'openstack-neutron-sriov-nic-agent'
  $neutron_sriov_service =  'neutron-sriov-nic-agent'
  $grub_command = 'sed -i "s/crashkernel=auto/crashkernel=auto intel_iommu=on/" /etc/default/grub && grub2-mkconfig -o /boot/grub2/grub.cfg'

}


# mysql connection - depends on openstack version
$profile= hiera("PLATFORM_PROFILE", undef)

if $profile =~ /KILO/ {
  $my_db_connector = 'mysql'
}
else {
  $my_db_connector = 'mysql+pymysql'
}
