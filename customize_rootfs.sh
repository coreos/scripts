#!/bin/sh

# Copyright (c) 2009 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Sets up the chromeos distribution from inside a chroot of the root fs.
# NOTE: This script should be called by build_image.sh. Do not run this
# on your own unless you know what you are doing.

set -e

# Read options from the config file created by build_image.sh.
echo "Reading options..."
cat "$(dirname $0)/customize_opts.sh"
. "$(dirname $0)/customize_opts.sh"

PACKAGE_LIST_FILE="${SETUP_DIR}/package-list-prod.txt"
PACKAGE_LIST_FILE2="${SETUP_DIR}/package-list-2.txt"
COMPONENTS=`cat $PACKAGE_LIST_FILE | grep -v ' *#' | grep -v '^ *$' | sed '/$/{N;s/\n/ /;}'`
FULLNAME="ChromeOS User"
USERNAME="chronos"
ADMIN_GROUP="admin"
DEFGROUPS="adm,dialout,cdrom,floppy,audio,dip,video"
ADMIN_USERNAME="chronosdev"

CRYPTED_PASSWD_FILE="/trunk/src/scripts/shared_user_passwd.txt"
if [ -f $CRYPTED_PASSWD_FILE ]
then
  echo "Using password from $CRYPTED_PASSWD_FILE"
  CRYPTED_PASSWD=$(cat $CRYPTED_PASSWD_FILE)
else
  # Use a random password.  unix_md5_crypt will generate a random salt.
  echo "Using random password."
  PASSWORD="$(base64 /dev/urandom | head -1)"
  CRYPTED_PASSWD="$(echo "$PASSWORD" | openssl passwd -1 -stdin)"
  PASSWORD="gone now"
fi

# Set CHROMEOS_VERSION_DESCRIPTION here (uses vars set in chromeos_version.sh)
# Was removed from chromeos_version.sh which can also be run outside of chroot
# where CHROMEOS_REVISION is set
if [ ${CHROMEOS_OFFICIAL:-0} = 1 ]
then
   export CHROMEOS_VERSION_DESCRIPTION="${CHROMEOS_VERSION_STRING} (Official Build ${CHROMEOS_REVISION:?})"
else
   export CHROMEOS_VERSION_DESCRIPTION="${CHROMEOS_VERSION_STRING} (Developer Build - $(date)-$USER)"
fi

# Set google-specific version numbers:
# CHROMEOS_RELEASE_CODENAME is the codename of the release.
# CHROMEOS_RELEASE_DESCRIPTION is the version displayed by Chrome; see
#   chrome/browser/chromeos/chromeos_version_loader.cc.
# CHROMEOS_RELEASE_NAME is a human readable name for the build.
# CHROMEOS_RELEASE_TRACK and CHROMEOS_RELEASE_VERSION are used by the software
#   update service.
# TODO(skrul):  Remove GOOGLE_RELEASE once Chromium is updated to look at
#   CHROMEOS_RELEASE_VERSION for UserAgent data.
cat <<EOF >> /etc/lsb-release
CHROMEOS_RELEASE_CODENAME=$CHROMEOS_VERSION_CODENAME
CHROMEOS_RELEASE_DESCRIPTION=$CHROMEOS_VERSION_DESCRIPTION
CHROMEOS_RELEASE_NAME=$CHROMEOS_VERSION_NAME
CHROMEOS_RELEASE_TRACK=$CHROMEOS_VERSION_TRACK
CHROMEOS_RELEASE_VERSION=$CHROMEOS_VERSION_STRING
GOOGLE_RELEASE=$CHROMEOS_VERSION_STRING
CHROMEOS_AUSERVER=$CHROMEOS_VERSION_AUSERVER
CHROMEOS_DEVSERVER=$CHROMEOS_VERSION_DEVSERVER
EOF

# Set the default X11 cursor theme to inherit our cursors.
mkdir -p /usr/share/icons/default
cat <<EOF > /usr/share/icons/default/index.theme
[Icon Theme]
Inherits=chromeos-cursors
EOF

# Turn user metrics logging on for official builds only.
if [ ${CHROMEOS_OFFICIAL:-0} -eq 1 ]; then
  touch /etc/send_metrics
fi

# Create the admin group and a chronos user that can act as admin.
groupadd ${ADMIN_GROUP}
echo "%admin ALL=(ALL) ALL" >> /etc/sudoers
useradd -G "${ADMIN_GROUP},${DEFGROUPS}" -g ${ADMIN_GROUP} -s /bin/bash -m \
  -c "${FULLNAME}" -p ${CRYPTED_PASSWD} ${USERNAME}

# Create apt source.list
cat <<EOF > /etc/apt/sources.list
deb file:"$SETUP_DIR" local_packages/
deb $SERVER $SUITE main restricted multiverse universe
EOF

# Install prod packages
apt-get update
apt-get --yes --force-yes install $COMPONENTS

# Create kernel installation configuration to suppress warnings,
# install the kernel in /boot, and manage symlinks.
cat <<EOF > /etc/kernel-img.conf
link_in_boot = yes
do_symlinks = yes
minimal_swap = yes
clobber_modules = yes
warn_reboot = no
do_bootloader = no
do_initrd = yes
warn_initrd = no
EOF

# NB: KERNEL_VERSION comes from customize_opts.sh
apt-get --yes --force-yes --no-install-recommends \
  install "linux-image-${KERNEL_VERSION}"

# Set timezone symlink
rm -f /etc/localtime
ln -s /mnt/stateful_partition/etc/localtime /etc/localtime

# make a mountpoint for stateful partition
sudo mkdir -p "$ROOTFS_DIR"/mnt/stateful_partition
sudo chmod 0755 "$ROOTFS_DIR"/mnt
sudo chmod 0755 "$ROOTFS_DIR"/mnt/stateful_partition

# If we don't create generic udev rules, then udev will try to save the
# history of various devices (i.e. always associate a given device and MAC
# address with the same wlan number). As we use a keyfob across different
# machines the ethN and wlanN keep changing.
cat <<EOF >> /etc/udev/rules.d/70-persistent-net.rules
SUBSYSTEM=="net", ACTION=="add", DRIVERS=="?*", ATTR{type}=="1", KERNEL=="eth*", NAME="eth0"
SUBSYSTEM=="net", ACTION=="add", DRIVERS=="?*", ATTR{type}=="1", KERNEL=="wlan*", NAME="wlan0"
EOF

# Setup bootchart. Due to dependencies, this adds about 180MB!
apt-get --yes --force-yes --no-install-recommends install bootchart
# TODO: Replace this with pybootchartgui, or remove it entirely.
apt-get --yes --force-yes --no-install-recommends install bootchart-java

# Install additional packages from a second mirror, if necessary.  This must
# be done after all packages from the first repository are installed; after
# the apt-get update, apt-get and debootstrap will prefer the newest package
# versions (which are probably on this second mirror).
if [ -f "$PACKAGE_LIST_FILE2" ]
then
  COMPONENTS2=`cat $PACKAGE_LIST_FILE2 | grep -v ' *#' | grep -v '^ *$' | sed '/$/{N;s/\n/ /;}'`

  echo "deb $SERVER2 $SUITE2 main restricted multiverse universe" \
    >> /etc/apt/sources.list
  apt-get update
  apt-get --yes --force-yes --no-install-recommends \
    install $COMPONENTS2
fi

# List all packages installed so far, since these are what the local
# repository needs to contain.
# TODO: better place to put the list.  Must still exist after the chroot
# is dismounted, so build_image.sh can get it.  That rules out /tmp and
# $SETUP_DIR (which is under /tmp).
sudo sh -c "/trunk/src/scripts/list_installed_packages.sh \
  > /etc/package_list_installed.txt"

# Remove unused packages.
# TODO: How are these getting on our image, anyway?
set +e
dpkg -l | grep pulseaudio | awk '{ print $2 }' | xargs dpkg --purge
dpkg -l | grep conkeror | awk '{ print $2 }' | xargs dpkg --purge
# TODO(rspangler): fix uninstall steps which fail at tip
#dpkg -l | grep xulrunner | awk '{ print $2 }' | xargs dpkg --purge
set -e

# Clean up other useless stuff created as part of the install process.
rm -f /var/cache/apt/archives/*.deb
rm -rf "$SETUP_DIR"

# Fix issue where alsa-base (dependency of alsa-utils) is messing up our sound
# drivers. The stock modprobe settings worked fine.
# TODO: Revisit when we have decided on how sound will work on chromeos.
rm /etc/modprobe.d/alsa-base.conf

# -- Remove unneeded fonts and set default gtk font --
UNNEEDED_FONTS_TYPES=$(ls -d /usr/share/fonts/* | grep -v truetype)
UNNEEDED_TRUETYPE_FONTS=$(ls -d /usr/share/fonts/truetype/* | grep -v ttf-droid)
for i in $UNNEEDED_FONTS_TYPES $UNNEEDED_TRUETYPE_FONTS
do
  rm -rf "$i"
done
# set default gtk font:
cat <<EOF > /etc/gtk-2.0/gtkrc
gtk-font-name="DroidSans 8"
EOF

# -- Some boot performance customizations --

# Setup our xorg.conf. This allows us to avoid HAL overhead.
# TODO: Per-device xorg.conf rather than in this script.
cat <<EOF > /etc/X11/xorg.conf
Section "ServerFlags"
    Option "AutoAddDevices" "false"
    Option "DontZap" "false"
EndSection

Section "InputDevice"
    Identifier "Keyboard1"
    Driver     "kbd"
    Option     "AutoRepeat" "250 30"
    Option     "XkbRules"   "xorg"
    Option     "XkbModel"   "pc104"
    Option     "CoreKeyboard"
EndSection

Section "InputDevice"
    Identifier "Mouse1"
    Driver     "synaptics"
    Option     "SendCoreEvents" "true"
    Option     "Protocol" "auto-dev"
    Option     "SHMConfig" "on"
    Option     "CorePointer"
    Option     "MinSpeed" "0.2"
    Option     "MaxSpeed" "0.5"
    Option     "AccelFactor" "0.002"
    Option     "HorizScrollDelta" "100"
    Option     "VertScrollDelta" "100"
    Option     "HorizEdgeScroll" "0"
    Option     "VertEdgeScroll" "1"
    Option     "TapButton1" "1"
    Option     "TapButton2" "2"
    Option     "MaxTapTime" "180"
    Option     "FingerLow" "24"
    Option     "FingerHigh" "50"
EndSection

# Everything after this point was added to include support for USB as a
# secondary mouse device.
Section "InputDevice"
  Identifier "USBMouse"
  Driver "mouse"
  Option "Device" "/dev/input/mice" # multiplexed HID mouse input device
  Option "Protocol" "IMPS/2"
  Option "ZAxisMapping" "4 5" # support a wheel as buttons 4 and 5
  Option "Emulate3Buttons" "true"  # just in case it is a 2 button
EndSection

# Defines a non-default server layout which pulls in the USB Mouse as a
# secondary input device.
Section "ServerLayout"
  Identifier "DefaultLayout"
  # Screen "DefaultScreen"
  InputDevice "Mouse1" "CorePointer"
  InputDevice "USBMouse" "AlwaysCore"
  InputDevice "Keyboard1" "CoreKeyboard"
EndSection
EOF

# The udev daemon takes a long time to start up and settle so we defer it until
# after X11 has been started. In order to be able to mount the root file system
# and start X we pre-propulate some devices. These are copied into /dev by the
# chromeos_startup script.
UDEV_DEVICES=/lib/udev/devices
mkdir "$UDEV_DEVICES"/dri
mkdir "$UDEV_DEVICES"/input
mknod --mode=0600 "$UDEV_DEVICES"/initctl p
mknod --mode=0660 "$UDEV_DEVICES"/tty0 c 4 0
mknod --mode=0660 "$UDEV_DEVICES"/tty1 c 4 1
mknod --mode=0660 "$UDEV_DEVICES"/tty2 c 4 2
mknod --mode=0666 "$UDEV_DEVICES"/tty  c 5 0
mknod --mode=0666 "$UDEV_DEVICES"/ptmx c 5 2
mknod --mode=0640 "$UDEV_DEVICES"/mem  c 1 1
mknod --mode=0666 "$UDEV_DEVICES"/zero c 1 5
mknod --mode=0666 "$UDEV_DEVICES"/random c 1 8
mknod --mode=0666 "$UDEV_DEVICES"/urandom c 1 9
mknod --mode=0660 "$UDEV_DEVICES"/sda  b 8 0
mknod --mode=0660 "$UDEV_DEVICES"/sda1 b 8 1
mknod --mode=0660 "$UDEV_DEVICES"/sda2 b 8 2
mknod --mode=0660 "$UDEV_DEVICES"/sda3 b 8 3
mknod --mode=0660 "$UDEV_DEVICES"/sda4 b 8 4
mknod --mode=0660 "$UDEV_DEVICES"/sdb  b 8 16
mknod --mode=0660 "$UDEV_DEVICES"/sdb1 b 8 17
mknod --mode=0660 "$UDEV_DEVICES"/sdb2 b 8 18
mknod --mode=0660 "$UDEV_DEVICES"/sdb3 b 8 19
mknod --mode=0660 "$UDEV_DEVICES"/sdb4 b 8 20
mknod --mode=0660 "$UDEV_DEVICES"/fb0 c 29 0
mknod --mode=0660 "$UDEV_DEVICES"/dri/card0 c 226 0
mknod --mode=0640 "$UDEV_DEVICES"/input/mouse0 c 13 32
mknod --mode=0640 "$UDEV_DEVICES"/input/mice   c 13 63
mknod --mode=0640 "$UDEV_DEVICES"/input/event0 c 13 64
mknod --mode=0640 "$UDEV_DEVICES"/input/event1 c 13 65
mknod --mode=0640 "$UDEV_DEVICES"/input/event2 c 13 66
mknod --mode=0640 "$UDEV_DEVICES"/input/event3 c 13 67
mknod --mode=0640 "$UDEV_DEVICES"/input/event4 c 13 68
mknod --mode=0640 "$UDEV_DEVICES"/input/event5 c 13 69
mknod --mode=0640 "$UDEV_DEVICES"/input/event6 c 13 70
mknod --mode=0640 "$UDEV_DEVICES"/input/event7 c 13 71
mknod --mode=0640 "$UDEV_DEVICES"/input/event8 c 13 72
chown root.tty "$UDEV_DEVICES"/tty*
chown root.kmem "$UDEV_DEVICES"/mem
chown root.disk "$UDEV_DEVICES"/sda*
chown root.video "$UDEV_DEVICES"/fb0
chown root.video "$UDEV_DEVICES"/dri/card0
chmod 0666 "$UDEV_DEVICES"/null  # Fix misconfiguration of /dev/null

# Since we may mount read-only, our mtab should symlink to /proc
ln -sf /proc/mounts /etc/mtab

# For the most part, we use our own set of Upstart jobs that were installed
# in /etc/init.chromeos so as not to mingle with jobs installed by various
# packages. We fix that up now.
cp /etc/init/tty2.conf /etc/init.chromeos
rm -rf /etc/init
mv /etc/init.chromeos /etc/init

# By default, xkb writes computed configuration data to
# /var/lib/xkb. It can re-use this data to reduce startup
# time. In addition, if it fails to write we've observed
# keyboard issues. We add a symlink to allow these writes.
rm -rf /var/lib/xkb
ln -s /var/cache /var/lib/xkb

# This is needed so that devicekit-disks has a place to
# put its sql lite database. Since we do not need to
# retain this information across boots, we are just
# putting it in /var/tmp
rm -rf /var/lib/DeviceKit-disks
ln -s /var/tmp /var/lib/DeviceKit-disks

# Remove pam-mount's default entry in common-auth and common-session
sed -i 's/^\(.*pam_mount.so.*\)/#\1/g' /etc/pam.d/common-*

# List all packages still installed post-pruning
sudo sh -c "/trunk/src/scripts/list_installed_packages.sh \
  > /etc/package_list_pruned.txt"

# Clear the network settings.  This must be done last, since it prevents
# any subsequent steps from accessing the network.
cat <<EOF > /etc/network/interfaces
auto lo
iface lo inet loopback
EOF

cat <<EOF > /etc/resolv.conf
# Use the connman dns proxy.
nameserver 127.0.0.1
EOF
chmod a-wx /etc/resolv.conf
