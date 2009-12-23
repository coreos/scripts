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

# Flags
DEFINE_string target "x86" \
  "The target architecture to build for. One of { x86, arm }."
DEFINE_string root ""      \
  "The root file system to install packages in."
DEFINE_string output_dir "" \
  "The location of the output directory to use."
DEFINE_string package_list "" \
  "The package list file to use."
DEFINE_string setup_dir "/tmp" \
  "The staging directory to use."
DEFINE_string server "" \
  "The package server to use."
DEFINE_string suite "" \
  "The package suite to use."
DEFINE_string kernel_version "" \
  "The kernel version to use."

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

# Create the temporary apt source.list used to install packages.
APT_SOURCE="${FLAGS_output_dir}/sources.list"
cat <<EOF > "$APT_SOURCE"
deb file:"$FLAGS_setup_dir" local_packages/
deb $FLAGS_server $FLAGS_suite main restricted multiverse universe
EOF

# Cache directory for APT to use.
APT_CACHE_DIR="${FLAGS_output_dir}/tmp/cache/"
mkdir -p "${APT_CACHE_DIR}/archives/partial"

# Create the apt configuration file. See "man apt.conf"
APT_PARTS="${FLAGS_output_dir}/apt.conf.d"
mkdir -p "$APT_PARTS"  # An empty apt.conf.d to avoid other configs.
export APT_CONFIG="${FLAGS_output_dir}/apt.conf"
cat <<EOF > "$APT_CONFIG"
APT
{
  Install-Recommends "0";
  Install-Suggests "0";
  Get
  {
    Assume-Yes "1";
  };
};
Dir
{
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
apt-config dump > "${FLAGS_output_dir}/apt.conf.dump"

# Install prod packages
COMPONENTS=`cat $FLAGS_package_list | grep -v ' *#' | grep -v '^ *$' | sed '/$/{N;s/\n/ /;}'`
sudo APT_CONFIG="$APT_CONFIG" apt-get update
sudo APT_CONFIG="$APT_CONFIG" apt-get --force-yes \
  install $COMPONENTS

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
sudo APT_CONFIG="$APT_CONFIG" apt-get --force-yes \
  install "linux-image-${FLAGS_kernel_version}"

# Setup bootchart.
# TODO: Move this and other developer oriented "components" into an optional
# package-list-prod-dev.txt (ideally with a better name).
sudo APT_CONFIG="$APT_CONFIG" apt-get --force-yes \
  install bootchart

# Clean up the apt cache.
# TODO: The cache was populated by debootstrap, not these installs. Remove
# this line when we can get debootstrap to stop doing this.
sudo rm -f "${ROOT_FS_DIR}"/var/cache/apt/archives/*.deb

# List all packages installed so far, since these are what the local
# repository needs to contain.
# TODO: Replace with list_installed_packages.sh when it is fixed up.
dpkg --root="${ROOT_FS_DIR}" -l > \
  "${FLAGS_output_dir}/package_list_installed.txt"
