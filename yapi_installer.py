#!/usr/bin/env python
import argparse
import csv
import pprint
import re
import sys
import time
import threading
import yaml
from subprocess import *
from ucsc_utils import *
from ucsb_utils import *


def parse_config_data(filename):
    ''' this reads yaml input and parses node data '''
    with open(filename) as f:
        data = yaml.load(f)

    print "Setting up platform {0} using profile {1}...".format(data['PLATFORM_NAME'], data['PLATFORM_PROFILE'])
    data['NODES'] = []

    ''' Get install infor for nodes '''
    for d in data['NODE_INSTALL_INFO']:
        fields = d.split(":")
        rec = {'IPADDRESS': fields[0], 'HOSTNAME': fields[1], 'ROLE': fields[2], 'INSTALL': fields[3]}
        data['NODES'].append(rec)

    ''' Get MGMT info for nodes '''
    i=0
  
    if data['NODE_TYPE'] == 'UCSC':
        ''' We got UCS-C so get CIMC info '''
        print "Reading MGMT info for UCSC nodes..."
        for d in data['NODE_MGMT_INFO']:
            fields = d.split(":")
            rec = {'CIMC_IP': fields[0], 'CIMC_USER': fields[1], 'CIMC_PASSWORD': fields[2]}
            data['NODES'][i].update(rec)
            i += 1

    elif data['NODE_TYPE'] == 'UCSB':
        ''' We got UCS-B so get UCSM info '''
        print "Reading MGMT info for UCSB nodes..."
        for d in data['NODE_MGMT_INFO']:
            fields = d.split(":")
            rec = {'UCSM_IP': fields[0], 'UCSM_USER': fields[1], 'UCSM_PASSWORD': fields[2], 'UCSM_SERVICE_PROFILE': fields[3]}
            data['NODES'][i].update(rec)
            data['UCSM_IP'] = fields[0]
            data['UCSM_USER'] = fields[1]
            data['UCSM_PASSWORD'] = fields[2]
            i += 1
        data['UCSM_HOST_LIST'] = ",".join( [ d['HOSTNAME']+":"+d['UCSM_SERVICE_PROFILE'] for d in  data['NODES'] ] )

    ''' Get SRIOV hardware info '''
    if data['CONFIG_ENABLE_SRIOV']:
       get_sriov_info(data)

    dump_cfg_files(data)
    return data


def dump_cfg_files(data):
    ''' Dump YAML data into /var/www/html/nursery folder'''
    print "copying config files to install config web folder..."
    for node in data['NODES']:
        filename = '/var/www/html/nursery/cfgs/' + node['HOSTNAME']
        with open(filename, 'w') as outfile:
            yaml.dump(data, outfile, default_flow_style=False)


def get_sriov_info(data):
    ''' get hardware specific info for SRIOV vendor/product ID'''
    if data['NODE_TYPE'] == 'UCSB':
        data['SRIOV_VENDOR_ID'] = '1137'
        data['SRIOV_PRODUCT_ID'] = '0071'
    else:
        data['SRIOV_VENDOR_ID'] = '8086'
        data['SRIOV_PRODUCT_ID'] = '10ed'


def provision_nodes(data):
    ''' this SSH into each CIMC and obtain Mac for pxeboot interfaces
        then sets pxeboot from that interface as default boot option
        then registers the node in cobbler database
    '''
    print "\nStarting node provision..."

    threads = []
    for node in data['NODES']:
        if node['INSTALL']=='Y':
            t = threading.Thread(target=provision_a_node, args=(data, node))
            threads.append(t)
            t.start()
            time.sleep(2)

    for t in threads:
        t.join()


def provision_a_node(data, n):
    print "  -- node {0}".format(n['HOSTNAME'])

    '''  Get mac address for pxeboot '''
    if data['NODE_TYPE']=="UCSC":
        if not get_pxe_mac_ucsc(data, n):
            raise Exception("Can't find pxeboot interface MAC address for node {0}".format(n['HOSTNAME']))

        '''  Set pxeboot as default boot device '''
        set_boot_order_ucsc(data, n)

    elif data['NODE_TYPE']=="UCSB":
        if not get_pxe_mac_ucsb(data, n):
            raise Exception("Can't find pxeboot interface MAC address for node {0}".format(n['HOSTNAME']))

        set_boot_order_ucsb(data, n)

    '''  Register node in cobbler database '''
    if set_cobbler_record(data, n) > 0 :
        raise Exception("Can't set cobbler record for node {0}".format(n['HOSTNAME']))

    return 1


def set_cobbler_record(data, n):
    ''' adds/replaces cobbler info on all nodes '''
    cmd = "cobbler system remove --name="+ n['HOSTNAME']
    cmd += "; cobbler system add --name=" + n['HOSTNAME'] + \
          " --profile=" + data['PLATFORM_PROFILE']  + \
          " --interface=" + n['PXE_IF_NAME'] + \
          " --hostname=" + n['HOSTNAME']  + \
          " --mac=" + n['PXE_IF_MAC'] + \
          " --management=1 --netboot-enabled=Y"
    cmd += "; cobbler system edit --name=" + n['HOSTNAME'] + \
          " --interface=" + data['MGMT_IF'] + \
          " --static=1 --ip-address=" + n['IPADDRESS'] + \
          " --if-gateway=" + data['MGMT_GATEWAY'] + \
          " --netmask=" + data['MGMT_NETMASK'] + \
          " --name-servers=" + data['DNS_NAMESERVER']

    p = Popen(cmd, stdout=PIPE, shell=True)
    # sys.stdout.write(cmd)
    return p.returncode


def pxeboot_nodes(data):
    ''' Pxeboots all nodes in the list '''
    print "\nStarting node installation..."

    for n in data['NODES']:
        if n['INSTALL']=='Y':
            if data['NODE_TYPE']=="UCSC":
                pxeboot_a_node_ucsc(n)
            elif data['NODE_TYPE']=="UCSB":
                pxeboot_a_node_ucsb(n)
            else:
                raise Exception("Can't determine hardware typr for %s" % n['HOSTNAME'])
                

def track_install_status(data):
    ''' polling node install status and provide regular update '''


def main():
    """
    Read yaml config for your environment and assign data to nodes
    An example of the input yaml is found in my_setup.yaml
    Data has two components:  1) used for describing physical nodes   2) data needed to configure openstack setup
    We will read everything, but mostly the node info is used by YAPI to launch platform install
    """

    parser = argparse.ArgumentParser()
    parser.add_argument("-c", "--config", type=str, required=True,
                    help="config yaml file name(required)")
    args = parser.parse_args()

    """ parse input data"""
    data = parse_config_data(args.config)

    """ get pxeboot interface MAC info """
    provision_nodes(data)

    """ pxeboot each node """
    pxeboot_nodes(data)

    """ report install status on all nodes """
    track_install_status(data)

    
if __name__ == '__main__':
    main()
