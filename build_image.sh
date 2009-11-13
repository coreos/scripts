#!/bin/bash

# Copyright (c) 2009 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Script to build a bootable keyfob-based chromeos system image.
# It uses debootstrap (see https://wiki.ubuntu.com/DebootstrapChroot) to
# create a base file system. It then cusotmizes the file system and adds
# Ubuntu and chromeos specific packages. Finally, it creates a bootable USB
# image from the root fs.
#
# NOTE: This script must be run from the chromeos build chroot environment.
#

# Load common constants.  This should be the first executable line.
# The path to common.sh should be relative to your script's location.
. "$(dirname "$0")/common.sh"

# Script must be run inside the chroot
assert_inside_chroot

DEFAULT_PKGLIST="${SRC_ROOT}/package_repo/package-list-prod.txt"

# Flags
DEFINE_integer build_attempt 1                                \
  "The build attempt for this image build."
DEFINE_string output_root "${DEFAULT_BUILD_ROOT}/images"      \
  "Directory in which to place image result directories (named by version)"
DEFINE_string build_root "$DEFAULT_BUILD_ROOT"                \
  "Root of build output"
DEFINE_boolean replace $FLAGS_FALSE "Overwrite existing output, if any."
DEFINE_boolean increment $FLAGS_FALSE \
  "Picks the latest build and increments the minor version by one."

DEFINE_string mirror "$DEFAULT_IMG_MIRROR" "Repository mirror to use."
DEFINE_string suite "$DEFAULT_IMG_SUITE" "Repository suite to base image on."
DEFINE_string pkglist "$DEFAULT_PKGLIST" \
  "Name of file listing packages to install from repository."

DEFINE_string mirror2 "$DEFAULT_EXT_MIRROR" "Additional mirror to use."
DEFINE_string suite2 "$DEFAULT_EXT_SUITE" "Suite to use in additional mirror."
DEFINE_string pkglist2 "" \
  "Name of file listing packages to install from additional mirror."

KERNEL_DEB_PATH=$(find "${FLAGS_build_root}/x86/local_packages" -name "linux-image-*.deb")
KERNEL_DEB=$(basename "${KERNEL_DEB_PATH}" .deb | sed -e 's/linux-image-//' -e 's/_.*//')
KERNEL_VERSION=${KERNEL_VERSION:-${KERNEL_DEB}}

# Parse command line
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

# Die on any errors.
set -e

# Determine build version
. "${SCRIPTS_DIR}/chromeos_version.sh"

# Use canonical path since some tools (e.g. mount) do not like symlinks
# Append build attempt to output directory
IMAGE_SUBDIR="${CHROMEOS_VERSION_STRING}-a${FLAGS_build_attempt}"
OUTPUT_DIR="${FLAGS_output_root}/${IMAGE_SUBDIR}"
ROOT_FS_DIR="${OUTPUT_DIR}/rootfs"
ROOT_FS_IMG="${OUTPUT_DIR}/rootfs.image"
MBR_IMG="${OUTPUT_DIR}/mbr.image"
OUTPUT_IMG="${OUTPUT_DIR}/usb.img"

ROOTFS_CUSTOMIZE_SCRIPT="customize_rootfs.sh"
ROOTFS_SETUP_DIR="/tmp/chromeos_setup"
SETUP_DIR="${ROOT_FS_DIR}/${ROOTFS_SETUP_DIR}"

LOOP_DEV=

# Handle existing directory
if [ -e "$OUTPUT_DIR" ]
then
  if [ $FLAGS_replace -eq $FLAGS_TRUE ]
  then
    sudo rm -rf "$OUTPUT_DIR"
  else
    echo "Directory $OUTPUT_DIR already exists."
    echo "Use --build_attempt option to specify an unused attempt."
    echo "Or use --replace if you want to overwrite this directory."
    exit 1
  fi
fi

# create the output directory
mkdir -p "$OUTPUT_DIR"

# Make sure anything mounted in the rootfs is cleaned up ok on exit.
cleanup_rootfs_mounts() {
  # Occasionally there are some daemons left hanging around that have our
  # root image file system open. We do a best effort attempt to kill them.
  PIDS=`sudo lsof -t "$ROOT_FS_DIR" | sort | uniq`
  for pid in $PIDS
  do
    local cmdline=`cat /proc/$pid/cmdline`
    echo "Killing process that has open file on our rootfs: $cmdline"
    ! sudo kill $pid  # Preceded by ! to disable ERR trap.
  done

  # Sometimes the volatile directory is left mounted and sometimes it is not,
  # so we precede by '!' to disable the ERR trap.
  ! sudo umount "$ROOT_FS_DIR"/lib/modules/2.6.*/volatile/

  sudo umount "${ROOT_FS_DIR}/proc"
  sudo umount "${ROOT_FS_DIR}/sys"
  sudo umount "${ROOT_FS_DIR}/trunk"
}

cleanup_rootfs_loop() {
  sudo umount "$LOOP_DEV"
  sleep 1  # in case $LOOP_DEV is in use
  sudo losetup -d "$LOOP_DEV"
}

cleanup() {
  # Disable die on error.
  set +e

  cleanup_rootfs_mounts
  if [ -n "$LOOP_DEV" ]
  then
    cleanup_rootfs_loop
  fi

  # Turn die on error back on.
  set -e
}
trap cleanup EXIT

mkdir -p "$ROOT_FS_DIR"

# Create root file system disk image to fit on a 1GB memory stick.
# 1 GB in hard-drive-manufacturer-speak is 10^9, not 2^30.  950MB < 10^9 bytes.
ROOT_SIZE_BYTES=$((1024 * 1024 * 950))
dd if=/dev/zero of="$ROOT_FS_IMG" bs=1 count=1 seek=$((ROOT_SIZE_BYTES - 1))

# Format, tune, and mount the rootfs.
# Make sure we have a mtab to keep mkfs happy.
if [ ! -e /etc/mtab ]; then
  sudo touch /etc/mtab
fi
UUID=`uuidgen`
DISK_LABEL=C-ROOT
LOOP_DEV=`sudo losetup -f`
sudo losetup "$LOOP_DEV" "$ROOT_FS_IMG"
sudo mkfs.ext3 "$LOOP_DEV"
sudo tune2fs -L "$DISK_LABEL" -U "$UUID" -c 0 -i 0 "$LOOP_DEV"
sudo mount "$LOOP_DEV" "$ROOT_FS_DIR"

# Add debootstrap link for the suite, if it doesn't exist.
if [ ! -e "/usr/share/debootstrap/scripts/$FLAGS_suite" ]
then
  sudo ln -s /usr/share/debootstrap/scripts/jaunty \
    "/usr/share/debootstrap/scripts/$FLAGS_suite"
fi

# Bootstrap the base debian file system
sudo debootstrap --arch=i386 $FLAGS_suite "$ROOT_FS_DIR" "${FLAGS_mirror}"

# -- Customize the root file system --

# Set up mounts for working within the chroot. We copy some basic
# network information from the host so that the chroot can access
# repositories on the network as needed.
sudo mount -t proc proc "${ROOT_FS_DIR}/proc"
sudo mount -t sysfs sysfs "${ROOT_FS_DIR}/sys" # TODO: Do we need sysfs?
sudo cp /etc/hosts "${ROOT_FS_DIR}/etc"

# Set up bind mount for trunk, so we can get to package repository
# TODO: also use this instead of SETUP_DIR for other things below?
sudo mkdir -p "$ROOT_FS_DIR/trunk"
sudo mount --bind "$GCLIENT_ROOT" "$ROOT_FS_DIR/trunk"

# Create setup directory and copy over scripts, config files, and locally
# built packages.
mkdir -p "$SETUP_DIR"
mkdir -p "${SETUP_DIR}/local_packages"
cp "${SCRIPTS_DIR}/${ROOTFS_CUSTOMIZE_SCRIPT}" "$SETUP_DIR"
cp "$FLAGS_pkglist" "${SETUP_DIR}/package-list-prod.txt"
cp "${FLAGS_build_root}/x86/local_packages"/* "${SETUP_DIR}/local_packages"

if [ -n "$FLAGS_pkglist2" ]
then
  cp "$FLAGS_pkglist2" "${SETUP_DIR}/package-list-2.txt"
fi

# Set up repository for local packages to install in the rootfs via apt-get.
cd "$SETUP_DIR"
dpkg-scanpackages local_packages/ /dev/null | \
   gzip > local_packages/Packages.gz
cd -

# File-type mirrors have a different path when bind-mounted inside the chroot
# ${FOO/bar/baz} replaces bar with baz when evaluating $FOO.
MIRROR_INSIDE="${FLAGS_mirror/$GCLIENT_ROOT//trunk}"
MIRROR2_INSIDE="${FLAGS_mirror2/$GCLIENT_ROOT//trunk}"

# Write options for customize script into the chroot
CUST_OPTS="${SETUP_DIR}/customize_opts.sh"
cat <<EOF > $CUST_OPTS
SETUP_DIR="$ROOTFS_SETUP_DIR"
KERNEL_VERSION="$KERNEL_VERSION"
SERVER="$MIRROR_INSIDE"
SUITE="$FLAGS_suite"
SERVER2="$MIRROR2_INSIDE"
SUITE2="$FLAGS_suite2"
CHROMEOS_OFFICIAL="$CHROMEOS_OFFICIAL"
EOF
# Also export ChromeOS version strings
set | grep "CHROMEOS_VERSION" >> $CUST_OPTS

# Run the setup script
sudo chroot "$ROOT_FS_DIR" "${ROOTFS_SETUP_DIR}/${ROOTFS_CUSTOMIZE_SCRIPT}"

# Move package lists from the image into the output dir
sudo mv "$ROOT_FS_DIR"/etc/package_list_*.txt "$OUTPUT_DIR"

# Unmount mounts within the rootfs so it is ready to be imaged.
cleanup_rootfs_mounts

# -- Turn root file system into bootable image --

# Setup extlinux configuration.
# TODO: For some reason the /dev/disk/by-uuid is not being generated by udev
# in the initramfs. When we figure that out, switch to root=UUID=$UUID.
cat <<EOF | sudo dd of="$ROOT_FS_DIR"/boot/extlinux.conf
DEFAULT chromeos-usb
PROMPT 0
TIMEOUT 0

label chromeos-usb
  menu label chromeos-usb
  kernel vmlinuz
  append quiet console=tty2 initrd=initrd.img init=/sbin/init boot=local rootwait root=LABEL=$DISK_LABEL ro noresume noswap i915.modeset=1 loglevel=1

label chromeos-hd
  menu label chromeos-hd
  kernel vmlinuz
  append quiet console=tty2 init=/sbin/init boot=local rootwait root=HDROOT ro noresume noswap i915.modeset=1 loglevel=1
EOF

# Make partition bootable and label it.
sudo "$SCRIPTS_DIR/extlinux.sh" -z --install "${ROOT_FS_DIR}/boot"

cleanup_rootfs_loop

# Create a master boot record.
# Start with the syslinux master boot record. We need to zero-pad to
# fill out a 512-byte sector size.
SYSLINUX_MBR="/usr/lib/syslinux/mbr.bin"
dd if="$SYSLINUX_MBR" of="$MBR_IMG" bs=512 count=1 conv=sync
# Create a partition table in the MBR.
NUM_SECTORS=$((`stat --format="%s" "$ROOT_FS_IMG"` / 512))
sudo sfdisk -H64 -S32 -uS -f "$MBR_IMG" <<EOF
,$NUM_SECTORS,L,-,
,$NUM_SECTORS,S,-,
,$NUM_SECTORS,L,*,
;
EOF

OUTSIDE_OUTPUT_DIR="~/chromeos/src/build/images/${IMAGE_SUBDIR}"
echo "Done.  Image created in ${OUTPUT_DIR}"
echo "To copy to USB keyfob, outside the chroot, do something like:"
echo "  ./image_to_usb.sh --from=${OUTSIDE_OUTPUT_DIR} --to=/dev/sdb"
echo "To convert to VMWare image, outside the chroot, do something like:"
echo "  ./image_to_vmware.sh --from=${OUTSIDE_OUTPUT_DIR}"

trap - EXIT
