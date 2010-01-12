#!/bin/bash

# Copyright (c) 2009 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Script to install packages into the target root file system.
#
# NOTE: This script should be called by build_image.sh. Do not run this
# on your own unless you know what you are doing.

# Load common constants.  This should be the first executable line.
# The path to common.sh should be relative to your script's location.
. "$(dirname "$0")/common.sh"

# Script must be run inside the chroot
assert_inside_chroot
assert_not_root_user

DEFAULT_PKGLIST="${SRC_ROOT}/package_repo/package-list-prod.txt"

# Flags
DEFINE_string output_dir "" \
  "The location of the output directory to use [REQUIRED]."
DEFINE_string root ""      \
  "The root file system to install packages in."
DEFINE_string target "x86" \
  "The target architecture to build for. One of { x86, arm }."
DEFINE_string build_root "$DEFAULT_BUILD_ROOT"                \
  "Root of build output"
DEFINE_string package_list "$DEFAULT_PKGLIST" \
  "The package list file to use."
DEFINE_string server "$DEFAULT_EXT_MIRROR" \
  "The package server to use."
DEFINE_string suite "$DEFAULT_IMG_SUITE" \
  "The package suite to use."

# Parse command line
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

# Die on any errors.
set -e

KERNEL_DEB_PATH=$(find "${FLAGS_build_root}/${FLAGS_target}/local_packages" \
  -name "linux-image-*.deb")
KERNEL_DEB=$(basename "${KERNEL_DEB_PATH}" .deb | sed -e 's/linux-image-//' \
  -e 's/_.*//')
KERNEL_VERSION=${KERNEL_VERSION:-${KERNEL_DEB}}

if [[ -z "$FLAGS_output_dir" ]]; then
  echo "Error: --output_dir is required."
  exit 1
fi
OUTPUT_DIR=$(readlink -f "$FLAGS_output_dir")
SETUP_DIR="${OUTPUT_DIR}/local_repo"
ROOT_FS_DIR="${OUTPUT_DIR}/rootfs"
if [[ -n "$FLAGS_root" ]]; then
  ROOT_FS_DIR=$(readlink -f "$FLAGS_root")
fi
mkdir -p "$OUTPUT_DIR" "$SETUP_DIR" "$ROOT_FS_DIR"

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
  ! sudo umount "$ROOT_FS_DIR"/lib/modules/2.6.*/volatile/ > /dev/null 2>&1

  sudo umount "${ROOT_FS_DIR}/proc"
}

# Set up repository for locally built packages; these take highest precedence.
mkdir -p "${SETUP_DIR}/local_packages"
cp "${FLAGS_build_root}/${FLAGS_target}/local_packages"/* \
  "${SETUP_DIR}/local_packages"
cd "$SETUP_DIR"
dpkg-scanpackages local_packages/ /dev/null | \
   gzip > local_packages/Packages.gz
cd -

# Create the temporary apt source.list used to install packages.
APT_SOURCE="${OUTPUT_DIR}/sources.list"
cat <<EOF > "$APT_SOURCE"
deb file:"$SETUP_DIR" local_packages/
deb $FLAGS_server $FLAGS_suite main restricted multiverse universe
EOF

# Cache directory for APT to use. This cache is re-used across builds. We
# rely on the cache to reduce traffic to the hosted repositories.
APT_CACHE_DIR="${FLAGS_build_root}/apt_cache-${FLAGS_target}/"
mkdir -p "${APT_CACHE_DIR}/archives/partial"

# Create the apt configuration file. See "man apt.conf"
APT_PARTS="${OUTPUT_DIR}/apt.conf.d"
mkdir -p "$APT_PARTS"  # An empty apt.conf.d to avoid other configs.
export APT_CONFIG="${OUTPUT_DIR}/apt.conf"
cat <<EOF > "$APT_CONFIG"
APT
{
  Install-Recommends "0";
  Install-Suggests "0";
  Get
  {
    Assume-Yes "1";
    AllowUnauthenticated "1";
  };
};
Dir
{
  Bin {
    dpkg "${SCRIPTS_DIR}/dpkg_no_scripts.sh";
  };
  Cache "$APT_CACHE_DIR";
  Cache {
    archives "${APT_CACHE_DIR}/archives";
  };
  Etc
  {
    sourcelist "$APT_SOURCE";
    parts "$APT_PARTS";
  };
  State "${ROOT_FS_DIR}/var/lib/apt/";
  State
  {
    status "${ROOT_FS_DIR}/var/lib/dpkg/status";
  };
};
DPkg
{
  options {"--root=${ROOT_FS_DIR}";};
};
EOF

# TODO: Full audit of the apt conf dump to make sure things are ok.
apt-config dump > "${OUTPUT_DIR}/apt.conf.dump"

# We do a rough equivalent to debootstrap that installs the minimal
# packages needed to be able to run apt to install the rest. We don't
# use debootstrap since it is geared toward having a second stage that
# needs to run package maintainer scripts. This is also simpler.

# The set of required packages before apt can take over.
PACKAGES="debconf libacl1 libattr1 libc6 libgcc1 libselinux1"

# Set of packages that we need to install early so that other packages
# maintainer scripts can still basically run.
#
# login  - So that groupadd will work
# base-passwd/passwd - So that chmod and useradd/groupadd will work
# bash - So that scripts can run
# libpam-runtime/libuuid1 - Not exactly sure why
# sysv-rc - So that we can overwrite invoke-rc.d, update-rc.d
EXTRA_PACKAGES="base-files base-passwd bash libpam-runtime libuuid1 login passwd sysv-rc"

# Prep the rootfs to work with dpgk and apt
sudo mkdir -p "${ROOT_FS_DIR}/var/lib/dpkg/info"
sudo touch "${ROOT_FS_DIR}/var/lib/dpkg/available"   \
  "${ROOT_FS_DIR}/var/lib/dpkg/diversions"           \
  "${ROOT_FS_DIR}/var/lib/dpkg/status"
sudo mkdir -p "${ROOT_FS_DIR}/var/lib/apt/lists/partial"  \
  "${ROOT_FS_DIR}/var/lib/dpkg/updates"

# Download the initial packages into the apt cache if necessary.
REPO="${APT_CACHE_DIR}/archives"
sudo APT_CONFIG="$APT_CONFIG" DEBIAN_FRONTEND=noninteractive apt-get update
sudo APT_CONFIG="$APT_CONFIG" DEBIAN_FRONTEND=noninteractive \
  apt-get --download-only install $PACKAGES $EXTRA_PACKAGES

# Install initial packages directly with dpkg_no_scripts.sh
for p in $PACKAGES $EXTRA_PACKAGES; do
  PKG=$(ls "${REPO}"/${p}_*_i386.deb || /bin/true)
  if [ -z "$PKG" ]; then
    PKG=$(ls "${REPO}"/${p}_*_all.deb)
  fi
  sudo "${SCRIPTS_DIR}"/dpkg_no_scripts.sh \
    --root="$ROOT_FS_DIR" --nodpkg_fallback --unpack "$PKG"
  sudo "${SCRIPTS_DIR}"/dpkg_no_scripts.sh \
    --root="$ROOT_FS_DIR" --nodpkg_fallback --configure "$p"
done

# Make sure that apt is ready to work. We use --fix-broken to trigger apt
# to install additional critical packages. If there are any of these, we
# disable the maintainer scripts so they install ok.
TMP_FORCE_NO_SCRIPTS="-o=DPkg::options::=--nodpkg_fallback"
sudo APT_CONFIG="$APT_CONFIG" DEBIAN_FRONTEND=noninteractive \
  apt-get $TMP_FORCE_NO_SCRIPTS --force-yes --fix-broken install

# TODO: Remove these hacks when we stop having maintainer scripts altogether.
sudo cp -a /dev/* "${ROOT_FS_DIR}/dev"
sudo cp -a /etc/resolv.conf "${ROOT_FS_DIR}/etc/resolv.conf"
sudo ln -sf /bin/true "${ROOT_FS_DIR}/usr/sbin/invoke-rc.d"
sudo ln -sf /bin/true "${ROOT_FS_DIR}/usr/sbin/update-rc.d"

# Set up mounts for working within the rootfs. We copy some basic
# network information from the host so that maintainer scripts can
# access the network as needed.
# TODO: All of this rootfs mount stuff can be removed as soon as we stop
# running the maintainer scripts on install.
sudo mount -t proc proc "${ROOT_FS_DIR}/proc"
sudo cp /etc/hosts "${ROOT_FS_DIR}/etc"
trap cleanup_rootfs_mounts EXIT

# Install prod packages
COMPONENTS=`cat $FLAGS_package_list | grep -v ' *#' | grep -v '^ *$' | sed '/$/{N;s/\n/ /;}'`
sudo APT_CONFIG="$APT_CONFIG" DEBIAN_FRONTEND=noninteractive \
  apt-get --force-yes install $COMPONENTS

# Create kernel installation configuration to suppress warnings,
# install the kernel in /boot, and manage symlinks.
cat <<EOF | sudo dd of="${ROOT_FS_DIR}/etc/kernel-img.conf"
link_in_boot = yes
do_symlinks = yes
minimal_swap = yes
clobber_modules = yes
warn_reboot = no
do_bootloader = no
do_initrd = yes
warn_initrd = no
EOF

# Install the kernel.
sudo APT_CONFIG="$APT_CONFIG" DEBIAN_FRONTEND=noninteractive \
  apt-get --force-yes install "linux-image-${KERNEL_VERSION}"

# List all packages installed so far, since these are what the local
# repository needs to contain.
# TODO: Replace with list_installed_packages.sh when it is fixed up.
dpkg --root="${ROOT_FS_DIR}" -l > \
  "${OUTPUT_DIR}/package_list_installed.txt"

cleanup_rootfs_mounts
trap - EXIT
