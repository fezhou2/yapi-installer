import 'setup.pp'

$ntp_server = hiera('NTP_SERVER', undef)

#Setup Time using NTP
exec { 'update_ntp_hwclock':
    command => "ntpdate $ntp_server; hwclock --systohc --localtime",
    path    => '/usr/local/bin/:/bin:/sbin:/usr/sbin:/usr/bin',
    logoutput => 'true',
}

#Add my info into /etc/hosts
exec { 'update_etc_hosts':
    command => "echo \"$::ipaddress $::hostname\" >> /etc/hosts",
    path    => '/usr/local/bin/:/bin:/usr/sbin:/usr/bin',
    logoutput => 'true',
    unless => "grep $::ipaddress /etc/hosts | grep $::hostname",
}
$controller_ip = hiera('CONTROLLER_IP')
$controller_hostname = hiera('CONTROLLER_HOSTNAME')
#Add controller info into /etc/hosts
exec { 'update_etc_hosts_controller':
    command => "echo \"$controller_ip $controller_hostname\" >> /etc/hosts",
    path    => '/usr/local/bin/:/bin:/usr/sbin:/usr/bin',
    logoutput => 'true',
    unless => "grep $controller_ip /etc/hosts | grep $controller_hostname",
}

#prevent DHCP from overwriting DNS resolv.conf file
$nameserver = hiera('DNS_NAMESERVER', undef)
exec { 'update_dns_nameserver':
    command => "echo \"supersede domain-name-servers $nameserver;\" >> /etc/dhcp/dhclient.conf",
    path    => '/usr/local/bin/:/bin:/usr/sbin:/usr/bin',
    logoutput => 'true',
    unless => "grep supersede  /etc/hosts | grep domain-name-servers | grep $nameserver",
}

#Prevent Network Manager or DHCP overwriting resolv.conf
if $::operatingsystem == 'RedHat' {
  #disable Network Manager from overwriting DNS info
  exec { 'update_nm':
    command => 'crudini --set /etc/NetworkManager/NetworkManager.conf main dns none',
    path    => '/usr/local/bin/:/bin:/usr/sbin:/usr/bin',
    logoutput => 'true',
  }
}

file { 'rc-local-file':
   path    =>  $rc_local_file ,
   ensure  =>  present,
   mode    =>  0755,
   owner   => 'root',
   group   => 'root',
}

#Ensure the network restart properly upon reboot
#especially the openvswitch-switch gets restart and network config reloaded
file { '/etc/init.d/all_service_restart':
  ensure  => 'present',
  replace => 'no', # this is the important property
  content => 'service openvswitch-switch restart; service networking restart;  service nova-compute restart; service neutron-openvswitch-agent restart',
  mode    => '0755',
}

file_line{ 'rc.local-network-restart':
  ensure => 'present',
  path  => $rc_local_file,
  line  => "/etc/init.d/all_service_restart",
  after => '^# By default this script does nothing',
}  

#IF CONFIG CALLS FOR LARGE MTU SUPPORT in install.yaml
if hiera('CONFIG_ENABLE_JUMBO_FRAMES') {
  exec { 'update_mtu_neutron':
    command => 'crudini --set /etc/neutron/neutron.conf DEFAULT global_physnet_mtu 9000',
    path    => '/usr/local/bin/:/bin:/usr/sbin:/usr/bin',
    logoutput => 'true',
  }

  exec { 'update_ml2':
    command => 'crudini --set /etc/neutron/plugins/ml2/ml2_conf.ini  ml2 path_mtu 9000',
    path    => '/usr/local/bin/:/bin:/usr/sbin:/usr/bin',
    logoutput => 'true',
  }
}

$tenant_if = hiera('TENANT_IF', undef)
$service_if = hiera('SERVICE_IF', undef)
$service_if_2 = hiera('SERVICE_IF_2', undef)

#WE ARE USING DPDK FOR NEUTRON NETWORK
if hiera('CONFIG_ENABLE_DPDK') {

  if $::operatingsystem == 'RedHat' {
    #Redhat release to be tested
    #Ensure dpdk software is installed
    #Redhat release to be tested

    #Install needed packages for openvswitch_dpdk
    exec { "install_openvswitch_dpdk":
      command => 'yum -y swap -- remove openvswitch -- install openvswitch-dpdk',
      path    => '/usr/local/bin/:/bin:/usr/sbin:/usr/bin',
      logoutput => 'true',
    } ->
    service { 'openvswitch':
      ensure => running,
      enable => true,
    }

    package { 'dpdk':
      ensure  => 'present',
    }

    package { 'dpdk-tools':
      ensure  => 'present',
    }

    #Install driverctl package
    exec { "install_driverctl":
      command => 'yum -d 0 -e 0 -y install /etc/puppet/modules/nephelo/resources/driverctl-0.59-3.el7.noarch.rpm',
      path    => '/usr/local/bin/:/bin:/usr/sbin:/usr/bin',
      logoutput => 'true',
    }

    #Set GRUB options for dpdk support
    exec { "update_grub_iommu":
      command => 'crudini --set /etc/default/grub "" GRUB_CMDLINE_LINUX \'"crashkernel=auto rhgb quiet iommu=pt intel_iommu=on default_hugepagesz=1G hugepagesz=1G hugepages=108"\' && grub2-mkconfig -o /boot/grub2/grub.cfg',
      path    => '/usr/local/bin/:/bin:/usr/sbin:/usr/bin',
      logoutput => 'true',
      unless => 'grep intel_iommu /etc/default/grub| grep hugepage',
    }

    #Set openvswitch config to use DPDK
    exec { "update_sysconfig_openvswitch_cfg":
      command => 'echo "DPDK_OPTIONS=\'-l 1,2,3 -n 1 --socket-mem 2048,0\'" >> /etc/sysconfig/openvswitch && ovs-vsctl set Open_vSwitch . other_config:pmd-cpu-mask=0xE',
      path    => '/usr/local/bin/:/bin:/usr/sbin:/usr/bin',
      logoutput => 'true',
      unless => 'grep socket-mem /etc/sysconfig/openvswitch | grep vhost-owner'
    }
  }

  elsif $::operatingsystem == 'Ubuntu' {
    #Ensure dpdk software is installed
    package { 'dpdk':
      ensure  => 'present',
    }

    package { 'openvswitch-switch-dpdk':
      ensure  => 'present',
    }

    #Ensure dpdk software is selected
    exec { 'update_alternatives_dpdk':
      command => 'update-alternatives --set ovs-vswitchd /usr/lib/openvswitch-switch-dpdk/ovs-vswitchd-dpdk',
      path    => '/usr/local/bin/:/bin:/usr/sbin:/usr/bin',
      logoutput => 'true',
    }

    #Set GRUB options for dpdk support
    exec { "update_grub_iommu":
      command => 'crudini --set /etc/default/grub "" GRUB_CMDLINE_LINUX_DEFAULT \'"iommu=pt intel_iommu=on default_hugepagesz=1G hugepagesz=1G hugepages=108"\' && update-grub',
      path    => '/usr/local/bin/:/bin:/usr/sbin:/usr/bin',
      logoutput => 'true',
      unless => 'grep intel_iommu /etc/default/grub| grep hugepage',
    }

    #Ensure patch in /usr/share/openvswitch/scripts/ovs-ctl file
    file_line{ 'ovs-ctl-cfg-setup':
      ensure => 'present',
      path  => '/usr/share/openvswitch/scripts/ovs-ctl',
      line  => 'test -e /etc/default/openvswitch-switch && . /etc/default/openvswitch-switch',
      after => '^# limitations under the License',
    }

    #Set openvswitch config to use DPDK
    exec { "update_default_openvswitch_cfg":
      command => 'echo "DPDK_OPTS=\'--dpdk -c 0x7 -n 4 --socket-mem 2048,0 --vhost-owner libvirt-qemu:kvm --vhost-perm 0664\'" >> /etc/default/openvswitch-switch && ovs-vsctl set Open_vSwitch . other_config:pmd-cpu-mask=0xE',
      path    => '/usr/local/bin/:/bin:/usr/sbin:/usr/bin',
      logoutput => 'true',
      unless => 'grep socket-mem /etc/default/openvswitch-switch | grep vhost-owner'
    }
  }

  #Set openvswitch_agent.ini to use netdev datapath type
  exec { "update_openvswitch_netdev":
    command => 'crudini --set /etc/neutron/plugins/ml2/openvswitch_agent.ini ovs datapath_type netdev && crudini --set /etc/neutron/plugins/ml2/openvswitch_agent.ini securitygroup enable_ipset true',
    path    => '/usr/local/bin/:/bin:/usr/sbin:/usr/bin',
    logoutput => 'true',
  }

  #Set qemu-kvm config to use huge pages - this is only required on compute hosts
  exec { "update_qemu_kvm_cfg":
    command => 'crudini --set /etc/default/qemu-kvm "" KVM_HUGEPAGES 1',
    path    => '/usr/local/bin/:/bin:/usr/sbin:/usr/bin',
    logoutput => 'true',
    unless => 'grep ^KVM_HUGEPAGES=1 /etc/default/qemu-kvm'
  }

  #Setup openswitch bridge & port for tenant interface
  if $tenant_if {
    exec {'update_tenant_interface_dpdk':
      command => "/etc/puppet/modules/nephelo/resources/convert_eth_2_ovsbr_dpdk.sh $tenant_if br-tenant dpdk0",
      path    => '/usr/local/bin/:/bin:/usr/sbin:/usr/bin',
      logoutput => 'true',
    }
  }

  if $service_if {
    exec {'update_service_interface_dpdk':
      command => "/etc/puppet/modules/nephelo/resources/convert_eth_2_ovsbr_dpdk.sh $service_if br-service dpdk1",
      path    => '/usr/local/bin/:/bin:/usr/sbin:/usr/bin',
      logoutput => 'true',
    }
  }

  if $service_if_2 {
    exec {'update_service_interface_dpdk_2':
      command => "/etc/puppet/modules/nephelo/resources/convert_eth_2_ovsbr_dpdk.sh $service_if_2 br-service2 dpdk2",
      path    => '/usr/local/bin/:/bin:/usr/sbin:/usr/bin',
      logoutput => 'true',
    }
  }
} 
 
#WE ARE USING REGULAR VIRTIO NETWORK
else {
  if $tenant_if {
    exec {'update_tenant_interface':
      command => "/etc/puppet/modules/nephelo/resources/convert_eth_2_ovsbr.sh $tenant_if br-tenant",
      path    => '/usr/local/bin/:/bin:/usr/sbin:/usr/bin',
      logoutput => 'true',
    }
    #Ensure the tenant_if link is up when boot 
    file_line{ 'rc.local-tenant-inf-up':
      ensure => 'present',
      path  => $rc_local_file,
      line  => "ip link set dev $tenant_if up;  ip link set dev $tenant_if mtu 9000",
      after => '^# By default this script does nothing',
    }
  }

  if $service_if {
    exec {'update_service_interface':
      command => "/etc/puppet/modules/nephelo/resources/convert_eth_2_ovsbr.sh $service_if br-service",
      path    => '/usr/local/bin/:/bin:/usr/sbin:/usr/bin',
      logoutput => 'true',
    }
    #Ensure the service_if link is up when boot 
    file_line{ 'rc.local-service-inf-up':
      ensure => 'present',
      path  => $rc_local_file,
      line  => "ip link set dev $service_if up;  ip link set dev $service_if mtu 9000",
      after => '^# By default this script does nothing',
    }
  }

  if $service_if_2 {
    exec {'update_service_interface_2':
      command => "/etc/puppet/modules/nephelo/resources/convert_eth_2_ovsbr.sh $service_if_2 br-service2",
      path    => '/usr/local/bin/:/bin:/usr/sbin:/usr/bin',
      logoutput => 'true',
    }
    #Ensure the service_if link is up when boot 
    file_line{ 'rc.local-service-inf-up-2':
      ensure => 'present',
      path  => $rc_local_file,
      line  => "ip link set dev $service_if_2 up;  ip link set dev $service_if_2 mtu 9000",
      after => '^# By default this script does nothing',
    }
  }
}


if $service_if_2 {
  exec { 'update_ovs_mapping2':
    command => 'crudini --set /etc/neutron/plugins/ml2/openvswitch_agent.ini ovs bridge_mappings physnet-tenant:br-tenant,physnet-service:br-service,physnet-service2:br-service2',
    path    => '/usr/local/bin/:/bin:/usr/sbin:/usr/bin',
    logoutput => 'true',
    unless  =>  'grep bridge_mappings /etc/neutron/plugins/ml2/openvswitch_agent.ini | grep physnet-service2:br-service2| grep physnet-service:br-service',
  }
}
 
else {  
  exec { 'update_ovs_mapping':
    command => 'crudini --set /etc/neutron/plugins/ml2/openvswitch_agent.ini ovs bridge_mappings physnet-tenant:br-tenant,physnet-service:br-service',
    path    => '/usr/local/bin/:/bin:/usr/sbin:/usr/bin',
    logoutput => 'true',
    unless  =>  'grep bridge_mappings /etc/neutron/plugins/ml2/openvswitch_agent.ini | grep physnet-service:br-service',
  }
}
