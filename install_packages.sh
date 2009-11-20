#!/bin/sh

# Copyright (c) 2009 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Sets up the chromium-based os from inside a chroot of the root fs.
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

# Create the temporary apt source.list used to install packages.
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

# Clean up other useless stuff created as part of the install process.
rm -f /var/cache/apt/archives/*.deb

# List all packages still installed post-pruning
sudo sh -c "/trunk/src/scripts/list_installed_packages.sh \
  > /etc/package_list_pruned.txt"
