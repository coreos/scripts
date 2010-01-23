#!/bin/bash

# Copyright (c) 2009 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Script to customize the root file system after packages have been installed.
#
# NOTE: This script should be called by build_image.sh. Do not run this
# on your own unless you know what you are doing.

# Load common constants.  This should be the first executable line.
# The path to common.sh should be relative to your script's location.
. "$(dirname "$0")/common.sh"

# Script must be run inside the chroot
assert_inside_chroot

# Flags
DEFINE_string arch "x86" \
  "The target architecture to build for. One of { x86, arm }."
DEFINE_string root ""      \
  "The root file system to customize."

# Parse command line
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

# Die on any errors.
set -e

ROOT_FS_DIR="$FLAGS_root"
if [[ -z "$ROOT_FS_DIR" ]]; then
  echo "Error: --root is required."
  exit 1
fi
if [[ ! -d "$ROOT_FS_DIR" ]]; then
  echo "Error: Root FS does not exist? ($ROOT_FS_DIR)"
  exit 1
fi

# Determine default user full username.
if [ ${CHROMEOS_OFFICIAL:-0} = 1 ]; then
  FULLNAME="Google Chrome OS User"
else
  FULLNAME="Chromium OS User"
fi

# Determine what password to use for the default user.
CRYPTED_PASSWD_FILE="${SCRIPTS_DIR}/shared_user_passwd.txt"
if [ -f $CRYPTED_PASSWD_FILE ]; then
  echo "Using password from $CRYPTED_PASSWD_FILE"
  CRYPTED_PASSWD=$(cat $CRYPTED_PASSWD_FILE)
else
  # Use a random password.  unix_md5_crypt will generate a random salt.
  echo "Using random password."
  PASSWORD="$(base64 /dev/urandom | head -1)"
  CRYPTED_PASSWD="$(echo "$PASSWORD" | openssl passwd -1 -stdin)"
  PASSWORD="gone now"
fi

# Set up a default user and add to sudo and the required groups.
ADD_USER="chronos"
ADD_GROUPS="audio video"
SHELL="/bin/sh"
if [[ -x "${ROOT_FS_DIR}/bin/bash" ]] ; then
  SHELL="/bin/bash"
fi
echo "${ADD_USER}:x:1000:1000:${FULLNAME}:/home/${ADD_USER}/:${SHELL}" | \
  sudo dd of="${ROOT_FS_DIR}/etc/passwd" conv=notrunc oflag=append
echo "${ADD_USER}:${CRYPTED_PASSWD}:14500:0:99999::::" | \
  sudo dd of="${ROOT_FS_DIR}/etc/shadow" conv=notrunc oflag=append
echo "${ADD_USER}:x:1000:" | \
  sudo dd of="${ROOT_FS_DIR}/etc/group" conv=notrunc oflag=append
for i in $ADD_GROUPS; do
  sudo sed -i "s/^\($i:x:[0-9]*:.*\)/\1,${ADD_USER}/g" \
    "${ROOT_FS_DIR}"/etc/group
done

sudo mkdir -p "${ROOT_FS_DIR}/home/${ADD_USER}"
sudo chown 1000.1000 "${ROOT_FS_DIR}/home/${ADD_USER}"
cat <<EOF | sudo dd of="${ROOT_FS_DIR}/etc/sudoers" conv=notrunc oflag=append
%adm ALL=(ALL) ALL
$ADD_USER ALL=(ALL) ALL
EOF
sudo chmod 0440 "${ROOT_FS_DIR}/etc/sudoers"
echo "# Allow chronos user to renice processes so that chrome will adjust tab priorities" | \
  sudo dd of="${ROOT_FS_DIR}/etc/security/limits.conf" conv=notrunc oflag=append
echo "chronos hard nice 0" | \
  sudo dd of="${ROOT_FS_DIR}/etc/security/limits.conf" conv=notrunc oflag=append

# Set CHROMEOS_VERSION_DESCRIPTION here (uses vars set in chromeos_version.sh)
# Was removed from chromeos_version.sh which can also be run outside of chroot
# where CHROMEOS_REVISION is set
# We have to set (in build_image.sh) and use REAL_USER due to many nested
# chroots which lose $USER state.
. "${SCRIPTS_DIR}/chromeos_version.sh"
if [ ${CHROMEOS_OFFICIAL:-0} = 1 ]; then
  export CHROMEOS_VERSION_DESCRIPTION="${CHROMEOS_VERSION_STRING} (Official Build ${CHROMEOS_REVISION:?})"
elif [ "$REAL_USER" = "chrome-bot" ]
then
  export CHROMEOS_VERSION_DESCRIPTION="${CHROMEOS_VERSION_STRING} (Continuous Build ${CHROMEOS_REVISION:?} - Builder: ${BUILDBOT_BUILD:-"N/A"})"
else
  # Use the $USER passthru via $CHROMEOS_RELEASE_CODENAME
  export CHROMEOS_VERSION_DESCRIPTION="${CHROMEOS_VERSION_STRING} (Developer Build ${CHROMEOS_REVISION:?} - $(date) - $CHROMEOS_RELEASE_CODENAME)"
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
cat <<EOF | sudo dd of="${ROOT_FS_DIR}/etc/lsb-release"
CHROMEOS_RELEASE_CODENAME=$CHROMEOS_VERSION_CODENAME
CHROMEOS_RELEASE_DESCRIPTION=$CHROMEOS_VERSION_DESCRIPTION
CHROMEOS_RELEASE_NAME=$CHROMEOS_VERSION_NAME
CHROMEOS_RELEASE_TRACK=$CHROMEOS_VERSION_TRACK
CHROMEOS_RELEASE_VERSION=$CHROMEOS_VERSION_STRING
GOOGLE_RELEASE=$CHROMEOS_VERSION_STRING
CHROMEOS_AUSERVER=$CHROMEOS_VERSION_AUSERVER
CHROMEOS_DEVSERVER=$CHROMEOS_VERSION_DEVSERVER
EOF

# Turn user metrics logging on for official builds only.
if [ ${CHROMEOS_OFFICIAL:-0} -eq 1 ]; then
  sudo touch "${ROOT_FS_DIR}/etc/send_metrics"
fi

# Set timezone symlink
sudo rm -f "${ROOT_FS_DIR}/etc/localtime"
sudo ln -s /mnt/stateful_partition/etc/localtime "${ROOT_FS_DIR}/etc/localtime"

# make a mountpoint for stateful partition
sudo mkdir -p "$ROOT_FS_DIR"/mnt/stateful_partition
sudo chmod 0755 "$ROOT_FS_DIR"/mnt
sudo chmod 0755 "$ROOT_FS_DIR"/mnt/stateful_partition

# Copy everything from the rootfs_static_data directory to the corresponding
# place on the filesystem. Note that this step has to occur after we've
# installed all of the packages.
TMP_STATIC=$(mktemp -d)
sudo cp -r "${SRC_ROOT}/rootfs_static_data/common/." "$TMP_STATIC"
# TODO: Copy additional arch-platform-specific subdirectories.
sudo chmod -R a+rX "$TMP_STATIC/."
sudo cp -r "$TMP_STATIC/." "$ROOT_FS_DIR"
sudo rm -rf "$TMP_STATIC"

# Fix issue where alsa-base (dependency of alsa-utils) is messing up our sound
# drivers. The stock modprobe settings worked fine.
# TODO: Revisit when we have decided on how sound will work on chromeos.
! sudo rm "${ROOT_FS_DIR}/etc/modprobe.d/alsa-base.conf"

# Remove unneeded fonts.
sudo rm -rf "${ROOT_FS_DIR}/usr/share/fonts/X11"

# The udev daemon takes a long time to start up and settle so we defer it until
# after X11 has been started. In order to be able to mount the root file system
# and start X we pre-populate some devices. These are copied into /dev by the
# chromeos_startup script.
# TODO: Hopefully some of this can be taken care of by devtmpfs.
DEVICES_DIR="${ROOT_FS_DIR}/lib/chromiumos/devices"
sudo mkdir -p "$DEVICES_DIR"/dri
sudo mkdir -p "$DEVICES_DIR"/input
sudo mkdir -p "$DEVICES_DIR"/pts
sudo mkdir -p "$DEVICES_DIR"/shm
sudo ln -sf /proc/self/fd "$DEVICES_DIR"/fd
sudo ln -sf /proc/self/fd/0 "$DEVICES_DIR"/stdin
sudo ln -sf /proc/self/fd/1 "$DEVICES_DIR"/stdout
sudo ln -sf /proc/self/fd/2 "$DEVICES_DIR"/stderr
sudo mknod --mode=0600 "$DEVICES_DIR"/initctl p
sudo mknod --mode=0640 "$DEVICES_DIR"/mem  c 1 1
sudo mknod --mode=0666 "$DEVICES_DIR"/null c 1 3
sudo mknod --mode=0666 "$DEVICES_DIR"/zero c 1 5
sudo mknod --mode=0666 "$DEVICES_DIR"/random c 1 8
sudo mknod --mode=0666 "$DEVICES_DIR"/urandom c 1 9
sudo mknod --mode=0660 "$DEVICES_DIR"/tty0 c 4 0
sudo mknod --mode=0660 "$DEVICES_DIR"/tty1 c 4 1
sudo mknod --mode=0660 "$DEVICES_DIR"/tty2 c 4 2
sudo mknod --mode=0666 "$DEVICES_DIR"/tty  c 5 0
sudo mknod --mode=0660 "$DEVICES_DIR"/ttyMSM2 c 252 2
sudo mknod --mode=0600 "$DEVICES_DIR"/console c 5 1
sudo mknod --mode=0666 "$DEVICES_DIR"/ptmx c 5 2
sudo mknod --mode=0666 "$DEVICES_DIR"/loop0 b 7 0
sudo mknod --mode=0660 "$DEVICES_DIR"/sda  b 8 0
sudo mknod --mode=0660 "$DEVICES_DIR"/sda1 b 8 1
sudo mknod --mode=0660 "$DEVICES_DIR"/sda2 b 8 2
sudo mknod --mode=0660 "$DEVICES_DIR"/sda3 b 8 3
sudo mknod --mode=0660 "$DEVICES_DIR"/sda4 b 8 4
sudo mknod --mode=0660 "$DEVICES_DIR"/sdb  b 8 16
sudo mknod --mode=0660 "$DEVICES_DIR"/sdb1 b 8 17
sudo mknod --mode=0660 "$DEVICES_DIR"/sdb2 b 8 18
sudo mknod --mode=0660 "$DEVICES_DIR"/sdb3 b 8 19
sudo mknod --mode=0660 "$DEVICES_DIR"/sdb4 b 8 20
sudo mknod --mode=0640 "$DEVICES_DIR"/input/mouse0 c 13 32
sudo mknod --mode=0640 "$DEVICES_DIR"/input/mice   c 13 63
sudo mknod --mode=0640 "$DEVICES_DIR"/input/event0 c 13 64
sudo mknod --mode=0640 "$DEVICES_DIR"/input/event1 c 13 65
sudo mknod --mode=0640 "$DEVICES_DIR"/input/event2 c 13 66
sudo mknod --mode=0640 "$DEVICES_DIR"/input/event3 c 13 67
sudo mknod --mode=0640 "$DEVICES_DIR"/input/event4 c 13 68
sudo mknod --mode=0640 "$DEVICES_DIR"/input/event5 c 13 69
sudo mknod --mode=0640 "$DEVICES_DIR"/input/event6 c 13 70
sudo mknod --mode=0640 "$DEVICES_DIR"/input/event7 c 13 71
sudo mknod --mode=0640 "$DEVICES_DIR"/input/event8 c 13 72
sudo mknod --mode=0660 "$DEVICES_DIR"/fb0 c 29 0
sudo mknod --mode=0660 "$DEVICES_DIR"/dri/card0 c 226 0
sudo chown root.tty "$DEVICES_DIR"/tty*
sudo chown root.kmem "$DEVICES_DIR"/mem
sudo chown root.disk "$DEVICES_DIR"/sda*
sudo chown root.video "$DEVICES_DIR"/fb0
sudo chown root.video "$DEVICES_DIR"/dri/card0

# Since we may mount read-only, our mtab should symlink to /proc
sudo ln -sf /proc/mounts "${ROOT_FS_DIR}/etc/mtab"

# For the most part, we use our own set of Upstart jobs that were installed
# in /etc/init.chromeos so as not to mingle with jobs installed by various
# packages. We fix that up now.
sudo cp "${ROOT_FS_DIR}/etc/init/tty2.conf" "${ROOT_FS_DIR}/etc/init.chromeos"
sudo rm -rf "${ROOT_FS_DIR}/etc/init"
sudo mv "${ROOT_FS_DIR}/etc/init.chromeos" "${ROOT_FS_DIR}/etc/init"

# By default, xkb writes computed configuration data to
# /var/lib/xkb. It can re-use this data to reduce startup
# time. In addition, if it fails to write we've observed
# keyboard issues. We add a symlink to allow these writes.
sudo rm -rf "${ROOT_FS_DIR}/var/lib/xkb"
sudo ln -s /var/cache "${ROOT_FS_DIR}/var/lib/xkb"

# This is needed so that devicekit-disks has a place to
# put its sql lite database. Since we do not need to
# retain this information across boots, we are just
# putting it in /var/tmp
sudo rm -rf "${ROOT_FS_DIR}/var/lib/DeviceKit-disks"
sudo ln -s /var/tmp "${ROOT_FS_DIR}/var/lib/DeviceKit-disks"

# dbus-uuidgen writes machine-id to /var/lib/dbus.
sudo rm -f "${ROOT_FS_DIR}/var/lib/dbus/machine-id"
sudo ln -s /var/cache/machine-id "${ROOT_FS_DIR}/var/lib/dbus/machine-id"

# Remove pam-mount's default entry in common-auth and common-session
sudo sed -i 's/^\(.*pam_mount.so.*\)/#\1/g' "${ROOT_FS_DIR}"/etc/pam.d/common-*

# A nice fake hostname to keep things happy.
echo "localhost" | sudo dd of="${ROOT_FS_DIR}/etc/hostname"

# Clear the network settings.  This must be done last, since it prevents
# any subsequent steps from accessing the network.
cat <<EOF | sudo dd of="${ROOT_FS_DIR}/etc/network/interfaces"
auto lo
iface lo inet loopback
EOF

cat <<EOF | sudo dd of="${ROOT_FS_DIR}/etc/resolv.conf"
# Use the connman dns proxy.
nameserver 127.0.0.1
EOF
sudo chmod a-wx "${ROOT_FS_DIR}/etc/resolv.conf"
