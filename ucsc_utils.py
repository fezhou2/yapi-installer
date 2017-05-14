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

def get_pxe_mac_ucsc(data, n):
    ''' actually get the mac on adapter L slot by doing a SSH connection to CIMC'''
    cmd = """
scope chassis
scope network-adapter L
show mac-list
top
exit"""

    output = ssh_cimc_cmd(n['CIMC_IP'], n['CIMC_USER'], n['CIMC_PASSWORD'], cmd)

    linedata = []
    for line in output.splitlines():
        linedata = line.split() 
        #capture MAC for slot number - make sure it is a MAC
        if linedata[0] == str(data['NODE_PXE_IF_SLOT']) and  \
            re.match("[0-9a-f]{2}([-:])[0-9a-f]{2}(\\1[0-9a-f]{2}){4}$", linedata[1].lower()):
            n['PXE_IF_MAC'] = linedata[1]
            if int(data['NODE_PXE_IF_SLOT'])==1:
                n['PXE_IF_NAME'] = 'enp1s0f0'
            else:
                n['PXE_IF_NAME'] = 'enp1s0f1'
            return 1

    return 0


def set_boot_order_ucsc(data, n):
    ''' set the boot order for node so pxeboot comes first '''
    cmd = """
scope bios
remove-boot-device pxe-boot
create-boot-device pxe-boot PXE
scope boot-device pxe-boot
set state Enabled
set slot L
set port """ + str(data['NODE_PXE_IF_SLOT']-1) + """
set order 1
commit
show detail
top
exit"""

    output = ssh_cimc_cmd(n['CIMC_IP'], n['CIMC_USER'], n['CIMC_PASSWORD'], cmd)

    return "Enabled" in output
   

def pxeboot_a_node_ucsc(n):
    ''' starts pxeboot on all nodes using CIMC '''
    print "  -- node {0}".format(n['HOSTNAME'])
    cmd = """
scope chassis
power on
y
top
exit"""

    output = ssh_cimc_cmd(n['CIMC_IP'], n['CIMC_USER'], n['CIMC_PASSWORD'], cmd)

    cmd = """
             scope chassis
             power cycle
y
             top
             exit"""

    output = ssh_cimc_cmd(n['CIMC_IP'], n['CIMC_USER'], n['CIMC_PASSWORD'], cmd)


