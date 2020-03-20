#!/bin/bash
#
# Encrypted Arch Installer -- original version by Joe Korang.
# Stealing and adjusting to better fit my prefernces/uses.
#
# Author: TJ Hoplock
#
# Prereqs/Assumptions:
# - Must create 3 disks:
#   - /dev/sda = 256 MB, unformatted/raw, for boot disk
#   - /dev/sdb = 256 MB, unformatted/raw, for swap disk
#   - /dev/sdc = remaining storage, unformatted/raw, for system disk
#
# install from finnix with this command to capture all output for debugging purposes:
# ./arch_install.sh 2>&1 | tee -a arch.log
# then, scp 'arch.log' off of finnix before rebooting

# gather info
# ------------

set -euo pipefail

echo "Pick a hostname" && read -rp '> ' HOSTNAME && echo

# get LUKS passphrase
PASS_MATCH='0'
while (( "$PASS_MATCH" == 0 )); do
  echo "Enter LUKS passphrase (this won't produce output)" && read -rsp '> ' LUKSPASSWD && echo
  echo "Confirm LUKS passphrase" && read -rsp '> ' LUKSPASSWD2 && echo

  if [[ "$LUKSPASSWD" == "$LUKSPASSWD2" ]]; then
    PASS_MATCH='1'
    unset LUKSPASSWD2
  else
    echo "LUKS passwords don't match. Try again."
    unset LUKSPASSWD
    unset LUKSPASSWD2
  fi
done

# get root password
PASS_MATCH='0'
while (( "$PASS_MATCH" == 0 )); do
  echo "Enter root password (this won't produce output)" && read -rsp '> ' ROOTPASSWD && echo
  echo "Confirm root password" && read -rsp '> ' ROOTPASSWD2 && echo

  if [[ "$ROOTPASSWD" == "$ROOTPASSWD2" ]]; then
    PASS_MATCH='1'
    unset ROOTPASSWD2
  else
    echo "Root passwords don't match. Try again."
    unset ROOTPASSWD
    unset ROOTPASSWD2
  fi
done

# get username
echo "Pick a username" && read -p '> ' USERNAME && echo

# get user password
PASS_MATCH='0'
while (( "$PASS_MATCH" == 0 )); do
  echo "Enter password for '$USERNAME' (this won't produce output)" && read -rsp '> ' USERPASSWD && echo
  echo "Confirm user password" && read -rsp '> ' USERPASSWD2 && echo

  if [[ "$USERPASSWD" == "$USERPASSWD2" ]]; then
    PASS_MATCH='1'
    unset USERPASSWD2
  else
    echo "User passwords don't match. Try again."
    unset USERPASSWD
    unset USERPASSWD2
  fi
done

# get SSH key
echo "Enter SSH key for '$USERNAME'" && read -rp '> ' SSHKEY && echo

# prompt for static IPs to configure later
# NOTE: I guess theoretically, I could start this out as DHCP, curl -4/6
# against icanhazip.com, and then setup static networking fully internally
# that way, but that's just silly amounts of extra effort.
echo "Let's set up static networking, too"
echo 'Enter IPv4' && read -rp '> ' STATIC_IPV4 && echo
echo 'Enter IPv6' && read -rp '> ' STATIC_IPV6 && echo
IPV4_GATEWAY=$(echo "$STATIC_IPV4" | cut -d '.' -f '1-3' | sed 's/$/.1/')

# offer to set up ipv4 if one is assigned already
while true; do
  echo "Setup private IP address too? (y/n): " && read -rp '> ' INPUT && echo

  if [[ "$INPUT" =~ ^[Yy]$ ]]; then
    echo "Alright, gimme a private IP" && read -rp '> ' PRIVATE_IPV4 && echo
    PRIVATE_IPV4="Address=$PRIVATE_IPV4/17"
    break
  elif [[ "$INPUT" =~ ^[Nn]$ ]]; then
    PRIVATE_IPV4=''
    break
  else
    echo 'Need a yes/no answer here'
  fi
done

# offer to pre-format system disk with random data
while true; do
  echo "Pre-format system disk with random data?"
  echo "Increases theoretical security by making statistical analysis harder, but also takes longer to setup."
  echo "Want to do it? (y/n): " && read -rp '> ' INPUT && echo

  if [[ "$INPUT" =~ ^[Yy]$ ]]; then
    RANDOM_WRITE="yes"
    break
  elif [[ "$INPUT" =~ ^[Nn]$ ]]; then
    RANDOM_WRITE="no"
    break
  else
    echo 'Need a yes/no answer here'
  fi
done

# offer to encrypt swap disk
while true; do
  echo "Encrypt swap disk too? (y/n): " && read -rp '> ' INPUT && echo

  if [[ "$INPUT" =~ ^[Yy]$ ]]; then
    ENCRYPT_SWAP="yes"
    break
  elif [[ "$INPUT" =~ ^[Nn]$ ]]; then
    ENCRYPT_SWAP="no"
    break
  else
    echo 'Need a yes/no answer here'
  fi
done

# do work
# -------
echo "~ Alright, starting to do stuff now. Come back in a little while."

# make sure finnix has plenty of entropy before attempting to create encrypted disks
apt-get -o Acquire::ForceIPv4=true update
apt-get -o Acquire::ForceIPv4=true install haveged -y
service haveged stop
haveged -w 2048

# Build encrypted disks
echo "~ Making disks"
if [[ "$RANDOM_WRITE" == 'yes' ]]; then
    echo "~ Filling system disk with random data"
    # Turns out that it's faster to write from /dev/zero to an encrypted device
    # to generate random data than it is to use /dev/urandom. Inspired by:
    # https://www.linuxglobal.com/quickly-fill-a-disk-with-random-bits-without-dev-urandom/
    TEMPLUKSPASSWD=$(head -c 64 /dev/urandom | base64)
    echo -n "$TEMPLUKSPASSWD" | cryptsetup -v --key-size 512 --hash sha512 luksFormat /dev/sdc --key-file=-
    echo -n "$TEMPLUKSPASSWD" | cryptsetup luksOpen /dev/sdc fake-device --key-file=-
    dd if=/dev/zero bs=1M | pv -pt | dd of=/dev/mapper/fake-device bs=1M || /bin/true
    cryptsetup luksClose fake-device
    unset TEMPLUKSPASSWD
    # overwrite old LUKS header
    dd if=/dev/urandom bs=512 count=$(cryptsetup luksDump /dev/sdc | grep -i 'payload' | awk '{print $3}') of=/dev/sdc
fi

echo "~ Creating LUKS container"
echo -n "$LUKSPASSWD" | cryptsetup -v --key-size 512 --hash sha512 --iter-time 5000 luksFormat /dev/sdc --key-file=-
echo -n "$LUKSPASSWD" | cryptsetup luksOpen /dev/sdc crypt-sdc --key-file=-
unset LUKSPASSWD
mkfs -t ext2 /dev/sda
mkfs.btrfs --label 'btrfs-root' /dev/mapper/crypt-sdc

if [[ "$ENCRYPT_SWAP" == 'yes' ]]; then
    cryptsetup -d /dev/urandom create crypt-swap /dev/sdb
    mkswap /dev/mapper/crypt-swap
    swapon /dev/mapper/crypt-swap
else
    mkswap /dev/sdb
    swapon /dev/sdb
fi

# Fetch and build arch straps
cd /tmp || exit
BOOTSTRAP_DATE=$(date +%Y.%m)
BOOTSTRAP_FILE="archlinux-bootstrap-$BOOTSTRAP_DATE.01-x86_64.tar.gz"
BOOTSTRAP_URL="https://mirrors.kernel.org/archlinux/iso/$BOOTSTRAP_DATE.01/$BOOTSTRAP_FILE"
echo "Downloading newest Arch bootstrap"
wget -4 --quiet --no-check-certificate "$BOOTSTRAP_URL" || { echo "couldn't download <$BOOTSTRAP_FILE>"; echo "=("; exit 1; }
tar xf $BOOTSTRAP_FILE
# use a different delimiter for sed so it doesn't get tripped up on /'s in url
sed -i 's?#Server = https://mirrors.kernel.org/archlinux/$repo/os/$arch?Server = https://mirrors.kernel.org/archlinux/$repo/os/$arch?' root.x86_64/etc/pacman.d/mirrorlist

# create subvolumes in Snapper's recommended subvolume layout
mount -o compress=lzo /dev/mapper/crypt-sdc /mnt
# top level subvols
btrfs subvolume create /mnt/@               # will mount at /
btrfs subvolume create /mnt/@home           # will mount at /home
umount /mnt

cat << ARCH_STRAP_EOF | root.x86_64/bin/arch-chroot /tmp/root.x86_64 /bin/bash
# needed for finnix/debian weirdness where link for /dev/shm -> /run/shm which doesn't exist
mkdir /run/shm

# mount root subvolume, top level subvolumes, and any other top level partitions
mount -o compress=lzo,subvol=@ /dev/mapper/crypt-sdc /mnt
mkdir -p /mnt/home
mount -o compress=lzo,subvol=@home /dev/mapper/crypt-sdc /mnt/home
mkdir -p /mnt/boot
mount /dev/sda /mnt/boot
# nested subvolumes can be created here, as well

pacman-key --init
pacman-key --populate archlinux
pacstrap /mnt base base-devel btrfs-progs
genfstab -p /mnt/ >> /mnt/etc/fstab

# Some system-level config junk
cat << SYSTEM_BUILD_EOF | arch-chroot /mnt /bin/bash
# general system config
echo "~ Some system config stuff"
sed -i 's/#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
sed -i 's/#en_US ISO-8859-1/en_US ISO-8859-1/' /etc/locale.gen
locale-gen
echo 'LANG=en_US.UTF-8' > /etc/locale.conf
export 'LANG=en_US.UTF-8'
ln -sf /usr/share/zoneinfo/America/New_York /etc/localtime
echo "$HOSTNAME" > /etc/hostname

# Networking!
echo "~ Setting up networking"
# stop systemd predictable network interface names
ln -s /dev/null /etc/udev/rules.d/80-net-setup-link.rules
# static network config using systemd-networkd
cat > /etc/systemd/network/05-eth0.network << STATIC_IP_EOF
# static configuration for both IPv4/IPv6
#
[Match]
Name=eth0

[Network]
# ipv4
Gateway=$IPV4_GATEWAY
Address=$STATIC_IPV4/24
$PRIVATE_IPV4

# ipv6
Gateway=fe80::1
Address=$STATIC_IPV6/64

STATIC_IP_EOF

# enable systemd-networkd
systemctl enable systemd-networkd

# force install and enable ssh
pacman -S openssh --noconfirm --needed
systemctl enable sshd

# fixes to build kernel for encrypted disks
echo "~ Building kernel"
sed -i '/^HOOKS/s/filesystems/encrypt filesystems/' /etc/mkinitcpio.conf
# btrfs doesn't really have a fsck function. exclude it to stop build errors.
sed -i '/^HOOKS/s/ fsck//' /etc/mkinitcpio.conf
mkinitcpio -p linux
if [[ "$ENCRYPT_SWAP" == 'yes' ]]; then
echo crypt-swap /dev/sdb /dev/urandom swap >> /etc/crypttab
fi

# Build users
echo "~ Setting up users"
echo "root:$ROOTPASSWD" | chpasswd
unset ROOTPASSWD
useradd -m -g users -G wheel -s /bin/zsh "$USERNAME"
echo "$USERNAME:$USERPASSWD" | chpasswd
unset USERPASSWD
sed -i 's/# %wheel ALL=(ALL) ALL/%wheel ALL=(ALL) ALL/' /etc/sudoers

# Get grub setup
echo "~ Installing GRUB"
pacman -S grub --noconfirm
sed -i '/^GRUB_TIMEOUT/c\GRUB_TIMEOUT=3' /etc/default/grub
sed -i '/^GRUB_CMDLINE_LINUX=/c\GRUB_CMDLINE_LINUX=\"console=ttyS0,19200n8 cryptdevice=/dev/sdc:crypt-sdc\"' /etc/default/grub
sed -i '/^#GRUB_DISABLE_LINUX_UUID=true/c\GRUB_DISABLE_LINUX_UUID=true' /etc/default/grub
echo 'GRUB_SERIAL_COMMAND="serial --speed=19200 --unit=0 --word=8 --parity=no --stop=1"' >> /etc/default/grub
echo 'GRUB_TERMINAL=serial' >> /etc/default/grub
echo 'GRUB_ENABLE_CRYPTODISK=y' >> /etc/default/grub
grub-install --recheck /dev/sda
grub-mkconfig --output /boot/grub/grub.cfg
mkdir -p /boot/boot
cd /boot/boot
ln -s ../grub .
# ln -s /boot/grub/ /boot/boot/

# Silly stuff
sed -i '/\# Misc options/a ILoveCandy' /etc/pacman.conf

# make sure there are at least some default packages
echo "~ Updating system and installing some default packages"
pacman -Syyu --noconfirm
pacman -S --needed --noconfirm btrfs-progs clamav dnsutils git haveged nmap openssh salt snapper strace sysstat tcpdump tmux ufw vim wget zsh zsh-syntax-highlighting

# install aurman
# https://github.com/polygamma/aurman
# https://aur.archlinux.org/packages/aurman/
echo "~ Setting up aurman \$now"
if [ ! -n "$(pacman -Qs aurman)" ]; then
  echo "~ Building aurman"

  # temporarily allow user to run pacman as root without password for automated `makepkg` install
  echo "$USERNAME ALL=(ALL) NOPASSWD: /usr/bin/pacman" > /etc/sudoers.d/aurman

  # Not super happy about skipping the import/check of the PGP keys in the PKGBUILD since Jonni is
  # kind enough to provide them, but an automated install to auto-process it is arguably just as bad
  # as skipping the check here. Maybe one of these days I'll look into rolling an ISO and embedding
  # aurman in so stuff like this isn't necessary.
  su "$USERNAME" --login -s /bin/bash << AURMAN_BUILD_EOF
    # clone aurman from aur into /tmp/aurman
    cd /tmp
    git clone https://aur.archlinux.org/aurman.git
    cd /tmp/aurman
    makepkg --syncdeps --rmdeps --clean --install --skippgpcheck --needed --noconfirm PKGBUILD
AURMAN_BUILD_EOF

  rm /etc/sudoers.d/aurman
fi

# basic SSH config/lockdown
echo "~ sshd config"
sed -E -i '/^#?PasswordAuthentication/c\PasswordAuthentication no' /etc/ssh/sshd_config
sed -E -i '/^#?PermitRoot/c\PermitRootLogin no' /etc/ssh/sshd_config

# user account config
echo "~ Configuring SSH keys and user stuff"
cat << USER_CONFIG_EOF | su "$USERNAME" -s /bin/bash -c '/bin/bash'
# SSH config
mkdir "/home/$USERNAME/.ssh"
echo "$SSHKEY" >> "/home/$USERNAME/.ssh/authorized_keys"
chmod -R 700 "/home/$USERNAME/.ssh"
chmod 600 "/home/$USERNAME/.ssh/authorized_keys"

cat > "/home/$USERNAME/.zshrc" << ZSH_CONFIG_EOF
autoload -Uz promptinit
promptinit
source /usr/share/zsh/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
autoload predict-on

# build prompt
PROMPT="%F{magenta}%n@%m%f:%F{cyan}%~%f %F{green}%(!.=>.->)%f "

ZSH_CONFIG_EOF

USER_CONFIG_EOF

exit
SYSTEM_BUILD_EOF

# populate resolv.conf
echo "~ Populate /etc/resolv.conf"
# NOTE: this needs to be done *outside* of the arch-root where the system is built
# because the arch-root script binds the host resolv.conf to the chrooted system
# if this is done *inside* the chroot, it sets the resolv.conf for the host system
# (ie, finnix)
cat > /mnt/etc/resolv.conf << RESOLV_EOF
# CloudFlare DNS
nameserver 1.1.1.1
nameserver 1.0.0.1

RESOLV_EOF

# unmount all subvolumes
umount --recursive /mnt

exit
ARCH_STRAP_EOF

echo "~ Done"
