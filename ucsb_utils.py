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

def ssh_cimc_cmd(ip, user, password, command):
    ''' run a command using CIMC cli using ssh '''
    sshcmd = "sshpass -p "+password+" ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no "+user+"@"+ip +" 2>/dev/null"
    output = check_output(sshcmd+' << %%'+command+'\n%%', shell=True)
    return output

def get_pxe_mac_ucsb(data, n):
    ''' actually get the mac on adapter L slot by doing a SSH connection to CIMC'''
    cmd = """
scope org /
scope service-profile """ + n['UCSM_SERVICE_PROFILE'] + """ 
show vnic
top
exit"""

    output = ssh_cimc_cmd(n['UCSM_IP'], n['UCSM_USER'], n['UCSM_PASSWORD'], cmd)

    linedata = []
    i=0
    for line in output.splitlines():
        linedata = line.split()
        #capture MAC for slot number - make sure it is a MAC
        if len(linedata)>2 and re.match("[0-9a-f]{2}([-:])[0-9a-f]{2}(\\1[0-9a-f]{2}){4}$", linedata[2].lower()):
            i+=1
            if i==int(data['NODE_PXE_IF_SLOT']):
                n['PXE_IF_DEVICE'] = linedata[0]
                n['PXE_IF_MAC'] = linedata[2]
                if int(data['NODE_PXE_IF_SLOT'])==1:
                    n['PXE_IF_NAME'] = 'enp6s0'
                else:
                    n['PXE_IF_NAME'] = 'enp7s0'
                return 1

    return 0


def set_boot_order_ucsb(data, n):
    ''' set the boot order for node so pxeboot comes first '''
    cmd = """
scope org /
scope service-profile """ + n['UCSM_SERVICE_PROFILE'] + """
delete boot-definition
commit-buffer
create boot-definition
create lan
set order 1
create path primary
set vnic """ + str(n['PXE_IF_DEVICE']) + """
exit
commit-buffer
top
exit"""

    output = ssh_cimc_cmd(n['UCSM_IP'], n['UCSM_USER'], n['UCSM_PASSWORD'], cmd)

    return "Enabled" in output


def pxeboot_a_node_ucsb(n):
    ''' starts pxeboot on all nodes using CIMC '''
    print "  -- node {0}".format(n['HOSTNAME'])
    cmd = """
scope org /
scope service-profile """ + n['UCSM_SERVICE_PROFILE'] + """
cycle cycle-immediate 
commit-buffer
top
exit"""

    output = ssh_cimc_cmd(n['UCSM_IP'], n['UCSM_USER'], n['UCSM_PASSWORD'], cmd)

