#!/bin/bash
#
# Encrypted Arch Installer -- original version by Joe Korang.
# Stealing and adjusting to better fit my prefernces/uses.
#
# Author: TJ
#
# Prereqs/Assumptions:
# - Must create 3 disk:
#   - /dev/sda = 256 MB, unformatted/raw, for boot disk
#   - /dev/sdb = 256 MB, unformatted/raw, for swap disk
#   - /dev/sdc = remaining storage, unformatted/raw, for system disk
#
# install from finnix with this command to capture all output for debugging purposes:
# ./arch_install.sh 2>&1 | tee -a arch.log
# then, scp 'arch.log' off of finnix before rebooting

# gather info
# ------------

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

# prompt for static IPs for config later
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

# do work
# -------
echo "~ Alright, starting to do stuff now. Come back in 5 mins."

# make sure finnix has plenty of entropy before attempting to create encrypted disks
apt-get -o Acquire::ForceIPv4=true update
apt-get -o Acquire::ForceIPv4=true install haveged -y
service haveged stop
haveged -w 2048

# Build encrypted disks
echo "~ Making disks"
echo -n "$LUKSPASSWD" | cryptsetup -v --key-size 512 --hash sha512 --iter-time 5000 luksFormat /dev/sdc --key-file=-
echo -n "$LUKSPASSWD" | cryptsetup luksOpen /dev/sdc crypt-sdc --key-file=-
unset LUKSPASSWD
mkfs -t ext2 /dev/sda
mkfs.btrfs --label 'btrfs-root' /dev/mapper/crypt-sdc
cryptsetup -d /dev/urandom create crypt-swap /dev/sdb
mkswap /dev/mapper/crypt-swap
swapon /dev/mapper/crypt-swap

# Fetch and build arch straps
cd /tmp || exit
BOOTSTRAP_DATE=$(date +%Y.%m)
BOOTSTRAP_FILE="archlinux-bootstrap-$BOOTSTRAP_DATE.01-x86_64.tar.gz"
BOOTSTRAP_URL="https://mirrors.kernel.org/archlinux/iso/$BOOTSTRAP_DATE.01/$BOOTSTRAP_FILE"
# wget was being annoying.
echo "Downloading newest Arch bootstrap"
curl -sO --insecure "$BOOTSTRAP_URL" || { echo "couldn't download <$BOOTSTRAP_FILE>"; echo "=("; exit 1; }
tar xf $BOOTSTRAP_FILE
# use a different delimiter for sed so it doesn't get tripped up on /'s in url
sed -i 's?#Server = https://mirrors.kernel.org/archlinux/$repo/os/$arch?Server = https://mirrors.kernel.org/archlinux/$repo/os/$arch?' root.x86_64/etc/pacman.d/mirrorlist

cat << ARCH_STRAP_EOF | root.x86_64/bin/arch-chroot /tmp/root.x86_64 /bin/bash
# needed for finnix/debian weirdness where link for /dev/shm -> /run/shm which doesn't exist
mkdir /run/shm
pacman-key --init
pacman-key --populate archlinux

# prep mount directories and create btrfs system, then pacstrap
pacman -Syu --needed --noconfirm
pacman -S btrfs-progs --needed --noconfirm
mkdir -p /mnt/btrfs-root
mkdir -p /mnt/arch-root
mount -t btrfs /dev/mapper/crypt-sdc /mnt/btrfs-root
btrfs subvolume create /mnt/btrfs-root/root
btrfs subvolume create /mnt/btrfs-root/snapshots
umount /mnt/btrfs-root/
mount -o defaults,noatime,compress=lzo,subvol=root /dev/mapper/crypt-sdc /mnt/arch-root
mkdir -p /mnt/arch-root/boot
mount /dev/sda /mnt/arch-root/boot
pacstrap /mnt/arch-root base base-devel
genfstab -p /mnt/arch-root/ >> /mnt/arch-root/etc/fstab

# Some system-level config junk
cat << SYSTEM_BUILD_EOF | arch-chroot /mnt/arch-root /bin/bash
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
echo crypt-swap /dev/sdb /dev/urandom swap >> /etc/crypttab

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
cat << PKG_LIST_EOF | tr '\n' ' ' | pacman -S --noconfirm --needed -
btrfs-progs
zsh
zsh-syntax-highlighting
vim
git
openssh
archey3
sysstat
strace
nmap
wget
screen
dnsutils
tcpdump
clamav
ufw
salt
PKG_LIST_EOF

# install pacaur
# https://github.com/rmarquis/pacaur
echo "~ Setting up pacaur \$now"
pacman -S --noconfirm expac yajl
if [ ! -n "$(pacman -Qs cower)" ]; then
  echo "~ Building cower"
  curl -sL -o /tmp/PKGBUILD https://aur.archlinux.org/cgit/aur.git/plain/PKGBUILD?h=cower
  su "$USERNAME" --login -s /bin/bash -c 'cd /tmp && makepkg PKGBUILD --skippgpcheck --needed --noconfirm'
  pacman -U /tmp/cower*.pkg.tar.xz --noconfirm
fi
if [ ! -n "$(pacman -Qs pacaur)" ]; then
  echo "~ Building pacaur"
  curl -sL -o /tmp/PKGBUILD https://aur.archlinux.org/cgit/aur.git/plain/PKGBUILD?h=pacaur
  su "$USERNAME" --login -s /bin/bash -c 'cd /tmp && makepkg PKGBUILD --needed --noconfirm'
  pacman -U /tmp/pacaur*.pkg.tar.xz --noconfirm
fi

# basic SSH config/lockdown
echo "~ sshd config"
sed -i '/^#PasswordAuthentication/c\PasswordAuthentication no' /etc/ssh/sshd_config
sed -i '/^#PermitRoot/c\PermitRootLogin no' /etc/ssh/sshd_config

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

archey3

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
cat > /mnt/arch-root/etc/resolv.conf << RESOLV_EOF
# Google DNS ftw
nameserver 8.8.8.8
nameserver 8.8.4.4
nameserver 2001:4860:4860::8888
nameserver 2001:4860:4860::8844

RESOLV_EOF

exit
ARCH_STRAP_EOF

echo "~ Done"
