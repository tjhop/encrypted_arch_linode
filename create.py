#!/usr/bin/env python3
"""
A python3 wrapper to create and prep a Linode for use with either the encrypted Arch or encrypted Debian scripts:
https://github.com/tjhop/encrypted_arch_linode
https://github.com/tjhop/encrypted_debian_linode
"""

from linode_api4 import LinodeClient
import yaml
import time
import calendar

# retreive api token from config file and initialize client
with open('config.yaml', 'r') as f:
    config = yaml.safe_load(f)

token = config.get('api-token')
client = LinodeClient(token)

# get necessary variables
linode_type = config.get('linode').get('type', 'g6-nanode-1')
region = config.get('linode').get('region', 'us-east')
linode_label = config.get('linode').get('label', str(calendar.timegm(time.gmtime())))
linode_group = config.get('linode').get('group')
config_label = config.get('linode').get('config_profile').get('label')

# create empty linode
print("* Creating Linode -> {}".format(linode_label))
l = client.linode.instance_create(ltype=linode_type, region=region, label=linode_label, group=linode_group)
disk_size = vars(l.specs)['disk'] - 512

print('* Making disks')
# configure disks
while l.status not in ('offline', 'running'):
    time.sleep(5)
    print("~ waiting on Linode status... ({})".format(l.status))
print('* Creating boot disk')
disk_sda = l.disk_create(size=256, label='Boot', filesystem='raw')

while disk_sda.status not in ('ready'):
    time.sleep(5)
    print("~ waiting on disk 'sda' status... ({})".format(disk_sda.status))
print('* Creating swap disk')
disk_sdb = l.disk_create(size=256, label='Swap', filesystem='raw')

while disk_sdb.status not in ('ready'):
    time.sleep(5)
    print("~ waiting on disk 'sdb' status... ({})".format(disk_sdb.status))
print('* Creating system disk')
disk_sdc = l.disk_create(size=disk_size, label='System', filesystem='raw')

# create configuration profile
while disk_sdc.status not in ('ready'):
    time.sleep(5)
    print("~ waiting on disk 'sdc' status... ({})".format(disk_sdc.status))
helpers_dict = {'updatedb_disabled': False,
                'distro': False,
                'modules_dep': False,
                'network': False,
                'devtmpfs_automount': False }
print('* Creating config profile')
l.config_create(kernel='linode/grub2',
                label=config_label,
                devices=l.disks,
                helpers=helpers_dict)

time.sleep(3)

# reboot into rescue mode
while l.status not in ('offline', 'running'):
    time.sleep(5)
    print("~ waiting on Linode status... ({})".format(l.status))

# call to `rescue` requires disk ids in form of a list, so let's make one

disks = []
for d in l.disks:
    disks.append(d.id)
print("* Rebooting into rescue mode with the following disks:\n{}".format(disks))
l.rescue(*disks)

print("Linode's IP addresses:\nIPv4 -> {}\nIPv6 -> {}".format(*l.ipv4, l.ipv6))
