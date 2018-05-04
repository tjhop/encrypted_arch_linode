# Encrypted Arch Bootstrap script

## Description
Build ArchLinux using BTRFS on encrypted disks on a [Linode server](https://www.linode.com/).

## Status
It works and does everything I want right now:
- Builds Arch on encrypted disks
- Uses BTRFS by default with simple subvolume setup in line with the [snapper suggested subvol layout](https://wiki.archlinux.org/index.php/Snapper#Suggested_filesystem_layout)
- Tries to follow Arch philosophy (minimal system config, only installs a few extra packages I use frequently, don't enable extra services by default, etc)
- Provides a (IMO) good base/clean slate to work from. The remainder of the system configuration is purposefully left for other config scripts or system configuration services (I'm using salt now).

## Using the script/Installing
This requires some manual prep because it builds the encrypted disks from rescue mode. There's a script included in this repo called `create.py` that will create a Linode based on the options specified in `config.yaml` using the new Linode API v4 and boot it into rescue mode for you.

Here's an example `config.yaml`:
```
# overall api config values
api-token: 'secretapitoken'

# linode object config values
linode:
  type: 'g5-nanode-1'
  region: 'us-central' # Dallas DC
  label: 'example linode label'
  group: 'example linode group'
  config_profile:
    label: 'example config profile label'
```

The script will create a Linode with following disk arrangement and configuration profile:
```
- Disks:
  - /dev/sda
    - label: Boot
    - type: unformatted/RAW
    - size: 256 MB
  - /dev/sdb
    - label: Swap
    - type: unformatted/RAW
    - size: 256 MB
  - /dev/sdc
    - label: System
    - type: unformatted/RAW
    - size: <remaining disk space>
- Configuration Profile:
  - Kernel: GRUB2
  - Disks: /dev/sda, /dev/sdb, and /dev/sdc as specified above ^
  - All boot helpers disabled
```
The Linode will also be rebooted into rescue mode automatically.

## Once the Linode is in rescue mode:
- Connect to the Linode with Lish and set password and enable SSH:

  ```
  passwd
  service ssh start
  ```
- Get the `arch_install.sh` script onto the rescue system and executable somehow. `Git clone`, `scp, vim`, etc.
- Run the `arch_install.sh` script:

  `./arch_install 2>&1 | tee arch.log`

  This will allow you to capture all output from the script into a log file that can be `scp`'d off if something breaks catastrophically.

Once in the script and running:
- The script is interactive and will prompt for various settings, including:
  - encryption passwords for LUKS
  - username/passwords/SSH key
  - IPv4/IPv6 addresses for the newly created Linode to set static networking
  - Optional private IP config (*note* this needs a private IP address already assigned to the Linode)
- You'll get to a point where it'll say:
  > ~ Alright, starting to do stuff now. Come back in 5 mins.

  Follow it.
- When the script is done, it'll say so. `scp` the log file to your local computer just in case.

**Note**: There are a few *expected* errors/messages that this script will post when running, such as failing to generate the initial initramfs/kernel. These are expected, so don't stress.

At this point, you're clear to reboot back into the system.

## Using the system
In order to enter your LUKS password to decrypt the disks, you'll need to connect with Lish first. After it's successfully unlocked, the system will finish booting and you can access the system with SSH

## What if I break something and need to use rescue mode?
Connect to the Linode with Lish and then reboot it into rescue mode. When Finnix first starts, it'll try to mount the disk (and therefore prompt for your LUKS password).

If you miss this prompt, you can still mount it manually like so:

```shell
# *Note*: Entering your password directly on the Lish console can log it in
# the Linode's console log on the host. If you're security conscious, this is
# bad. Do this to enter password without visible console output.
read -rsp '> ' LUKSPASSWD
echo -n "$LUKSPASSWD" | cryptsetup luksOpen /dev/sdc crypt-sdc --key-file=-
mount -o compress=lzo,subvol=@ /dev/mapper/crypt-sdc /mnt
mount -o compress=lzo,subvol=@home /dev/mapper/crypt-sdc /mnt/home
```

## License
This project is sarcastically licensed under the [WTFPL](http://www.wtfpl.net/). Go nuts.

Full license can be found in 'LICENSE.md' file.
