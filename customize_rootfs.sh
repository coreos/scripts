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
if [ "$SUITE" = "jaunty" ]
then
  # Additional driver modules needed for chromeos-wifi on jaunty.
  apt-get --yes --force-yes install linux-backports-modules-jaunty
fi

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
apt-get --yes --force-yes install "linux-image-${KERNEL_VERSION}"

# Create custom initramfs
# TODO: Remove when we switch to dhendrix kernel for good.
if [ $USE_UBUNTU_KERNEL -eq 1 ]
then
cat <<EOF >> /etc/initramfs-tools/modules
intel_agp
drm
i915 modeset=1
EOF
update-initramfs -u
fi

cat <<EOF > /etc/network/interfaces
auto lo
iface lo inet loopback
EOF

cat <<EOF > /etc/resolv.conf
# Use the connman dns proxy.
nameserver 127.0.0.1
EOF
chmod a-wx /etc/resolv.conf

# Set timezone symlink
rm -f /etc/localtime
ln -s /mnt/stateful_partition/etc/localtime /etc/localtime

# The postinst script is called after an AutoUpdate or USB install.
# the quotes around EOF mean don't evaluate anything inside this HEREDOC.
# TODO(adlr): set this file up in a package rather than here
cat <<"EOF" > /usr/sbin/chromeos-postinst
#!/bin/sh

set -e

# update /boot/extlinux.conf
INSTALL_ROOT=`dirname "$0"`
INSTALL_DEV="$1"

# set default label to chromeos-hd
sed -i 's/^DEFAULT .*/DEFAULT chromeos-hd/' "$INSTALL_ROOT"/boot/extlinux.conf
sed -i "{ s:HDROOT:$INSTALL_DEV: }" "$INSTALL_ROOT"/boot/extlinux.conf

# NOTE: The stateful partition will not be mounted when this is
# called at USB-key install time.
EOF
chmod 0755 /usr/sbin/chromeos-postinst

ln -s ./usr/sbin/chromeos-postinst /postinst


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
apt-get --yes --force-yes install bootchart

# Bootchart has been dying from a SIGHUP partway through boot. Daemonize it
# so that it won't get HUP'd
# TODO(tedbo): Remove when fixed upstream.
if [ -f /etc/init.d/bootchart ]
then
  sed -i 's^/lib/bootchart/collector \$HZ \$LOGS 2>/dev/null \&^start-stop-daemon --background --start --exec /lib/bootchart/collector -- \$HZ \$LOGS^'  \
    /etc/init.d/bootchart
fi

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
  apt-get --yes --force-yes install $COMPONENTS2
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

# -- Handle closelid/power button events to perform shutdown --
mkdir -p /etc/acpi/events
cat <<EOF > /etc/acpi/events/lidbtn
event=button[ /]lid
action=/etc/acpi/lid.sh
EOF

cat <<'EOF' > /etc/acpi/lid.sh
#!/bin/sh
# On lid close:
# - lock the screen
export HOME=/home/chronos
/usr/bin/xscreensaver-command -l

# - suspend the cryptohome device
#CRYPTOHOME=/dev/mapper/cryptohome
#/usr/bin/test -b $CRYPTOHOME && /sbin/dmsetup suspend $CRYPTOHOME

# - stop wireless if UP
wlan0isup=`/sbin/ifconfig wlan0 2>/dev/null | /bin/grep UP`
test "$wlan0isup" && /sbin/ifconfig wlan0 down

# - suspend to ram
echo -n mem > /sys/power/state

# - restore wireless state
test "$wlan0isup" && /sbin/ifconfig wlan0 up

# On lid open:
# - resume cryptohome device
#/usr/bin/test -b $CRYPTOHOME && /sbin/dmsetup resume $CRYPTOHOME
EOF
chmod 0755 /etc/acpi/lid.sh
cat <<EOF > /etc/acpi/events/powerbtn
event=button[ /]power
action=/etc/acpi/powerbtn.sh
EOF
cat <<EOF > /etc/acpi/powerbtn.sh
#!/bin/sh

# shutdown on power button

shutdown -h now
EOF
chmod 0755 /etc/acpi/powerbtn.sh

# -- Handle hotkeys --
# TODO(tedbo): This is specific to eeepc. Also, on the eee we can get all
# of the hotkeys except for the sleep one. Handle those?
cat <<EOF > /etc/acpi/events/hotkeys
event=hotkey ATKD
action=/etc/acpi/hotkeys.sh %e
EOF
cat <<EOF > /etc/acpi/hotkeys.sh
#!/bin/sh

case \$3 in
  00000013)  # Toggle sound
        amixer set LineOut toggle
        amixer set iSpeaker toggle
        ;;
  00000014)  # Decrease volume
        amixer set LineOut 5%-
        ;;
  00000015)  # Increase volume
        amixer set LineOut 5%+
        ;;
esac
EOF
chmod 0755 /etc/acpi/hotkeys.sh

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

# The udev daemon takes a long time to start up and settle. We modify the
# udev init script to settle in the backround, but in order to be able to
# mount the root file system and start X we pre-propulate some devices.
# Our rcS script copies whatever devices are in /lib/udev/devices
# to the tmpfs /dev well before we start udev, so we need to disable
# the copy step that is in the udev start script.
sed -i '{ s/# This next bit can take a while/&\n\{/ }' \
  /etc/init.d/udev   # Add '{' after the comment line.
sed -i '{ s/kill $UDEV_MONITOR_PID/&\n\} \&/ }' \
  /etc/init.d/udev   # Add '} &' after the kill line.
sed -i '{ s^cp -a -f /lib/udev/devices/\* /dev^^ }' \
  /etc/init.d/udev   # Remove step that prepopulates /dev
UDEV_DEVICES=/lib/udev/devices
mkdir "$UDEV_DEVICES"/dri
mkdir "$UDEV_DEVICES"/input
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

# TODO(tedbo): We don't rely on any upstart provided jobs. When we build
# our own upstart, stop if from installing jobs and then remove the lines
# below that remove stuff from /etc/init

# We don't need last-good-boot if it exits
rm -f /etc/init/last-good-boot.conf

# Don't create all of the virtual consoles
rm -f /etc/init/tty1.conf
rm -f /etc/init/tty[3-6].conf
sed -i '{ s:ACTIVE_CONSOLES=.*:ACTIVE_CONSOLES="/dev/tty2": }' \
  /etc/default/console-setup

# We don't use the rc.conf that triggers scripts in /etc/rc?.d/
rm -f /etc/init/rc.conf

# We don't use the rcS or rc-sysinit upstart jobs either.
rm -f /etc/init/rcS.conf
rm -f /etc/init/rc-sysinit.conf

# Start X on vt01
sed -i '{ s/xserver_arguments .*/xserver_arguments -nolisten tcp vt01/ }' \
 /etc/slim.conf

# Use our own rcS init script
mv /etc/init.d/rcS /etc/init.d/rcS.orig
ln -s /etc/init.d/chromeos_init.sh /etc/init.d/rcS

# Clean out unneeded Xsession scripts
XSESSION_D="/etc/X11/Xsession.d"
KEEPERS="20x11-common_process-args 51x11-chromeos-set-startup \
         90consolekit 99x11-common_start"
for script in ${KEEPERS}
do
  mv "$XSESSION_D"/"$script" /tmp
done
rm -rf "$XSESSION_D"/*
for script in ${KEEPERS}
do
  mv /tmp/"$script" "$XSESSION_D"
done

# By default, xkb writes computed configuration data to
# /var/lib/xkb. It can re-use this data to reduce startup
# time. In addition, if it fails to write we've observed
# keyboard issues. We add a symlink to allow these writes.
rm -rf /var/lib/xkb
ln -s /var/cache /var/lib/xkb

# Remove pam-mount's default entry in common-auth and common-session
sed -i 's/^\(.*pam_mount.so.*\)/#\1/g' /etc/pam.d/common-*

# List all packages still installed post-pruning
sudo sh -c "/trunk/src/scripts/list_installed_packages.sh \
  > /etc/package_list_pruned.txt"

# Clear network settings.  This must be done last, since it prevents
# any subseuqent steps from accessing the network.
cat <<EOF > /etc/network/interfaces
auto lo
iface lo inet loopback
EOF

cat <<EOF > /etc/resolv.conf
# Use the connman dns proxy.
nameserver 127.0.0.1
EOF
chmod a-wx /etc/resolv.conf

