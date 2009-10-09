#!/bin/bash

# Copyright (c) 2009 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Load common constants.  This should be the first executable line.
# The path to common.sh should be relative to your script's location.
. "$(dirname "$0")/common.sh"

# Script must be run outside the chroot
assert_outside_chroot

DEFAULT_DEST="$GCLIENT_ROOT/repo"
DEFAULT_DEV_PKGLIST="$SRC_ROOT/package_repo/repo_list_dev.txt"
DEFAULT_IMG_PKGLIST="$SRC_ROOT/package_repo/repo_list_image.txt"

# Command line options
DEFINE_string suite "$DEFAULT_EXT_SUITE" "Ubuntu suite to pull packages from."
DEFINE_string mirror "$DEFAULT_EXT_MIRROR" "Ubuntu repository mirror to use."
DEFINE_string dest "$DEFAULT_DEST" "Destination directory for repository."
DEFINE_string devlist "$DEFAULT_DEV_PKGLIST" \
  "File listing packages to use for development."
DEFINE_string imglist "$DEFAULT_IMG_PKGLIST" \
  "File listing packages to use for image."
DEFINE_string devsuite "$DEFAULT_DEV_SUITE" "Dev suite to update."
DEFINE_string imgsuite "$DEFAULT_IMG_SUITE" "Image suite to update."
DEFINE_boolean updev $FLAGS_TRUE "Update development repository."
DEFINE_boolean upimg $FLAGS_TRUE "Update image repository."

# Parse command line flags
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

# Die on error
set -e

# Architectures and sections to support in local mirror
REPO_ARCH="i386 armel"
REPO_SECTIONS="main restricted multiverse universe"

# Where to store packages downloaded from external repository, inside the
# chroot.
DEB_CACHE_DIR="/var/cache/make_local_repo"

CHROOT=`readlink -f $FLAGS_dest`
REPO_SUBDIR="apt"
REPO="$CHROOT/$REPO_SUBDIR"

#------------------------------------------------------------------------------
# Functions

# Run a command in the chroot
function in_chroot {
  sudo chroot "$CHROOT" "$@"
}

# Run a bash command line in the chroot
function bash_chroot {
  # Use $* not $@ since 'bash -c' needs a single arg
  sudo chroot "$CHROOT" bash -c "$*"
}

# Clean up chroot mount points
function cleanup_chroot_mounts {
  # Clear the trap from setup_chroot_mounts, now that we're unmounting.
  trap - EXIT

  mount | grep "on $(readlink -f "$CHROOT")" | awk '{print $3}' \
    | xargs -r -L1 sudo umount
}

# Set up chroot mount points
function setup_chroot_mounts {
  if [ ! -e "$CHROOT/proc" ]; then mkdir -p "$CHROOT/proc"; fi
  sudo mount none -t proc "$CHROOT/proc"
  if [ ! -e "$CHROOT/dev/pts" ]; then mkdir -p "$CHROOT/dev/pts"; fi
  sudo mount none -t devpts "$CHROOT/dev/pts"

  # Make sure we clean up the mounts on exit
  trap cleanup_chroot_mounts EXIT
}

# Make a minimal chroot
function make_chroot {
  echo "Creating chroot to build local package repository..."
  mkdir -p "$CHROOT"

  # Install packages which may not be installed on the local system
  install_if_missing debootstrap
 
  # Add debootstrap link for the suite, if it doesn't exist.
  if [ ! -e "/usr/share/debootstrap/scripts/$FLAGS_suite" ]
  then
    sudo ln -s /usr/share/debootstrap/scripts/gutsy \
      "/usr/share/debootstrap/scripts/$FLAGS_suite"
  fi

  # Run debootstrap
  sudo debootstrap --arch=i386 --variant=minbase \
    --include=gnupg \
    "$FLAGS_suite" "$CHROOT" "$FLAGS_mirror"

  # Set up chroot mounts, since the package installs below need them
  setup_chroot_mounts

  # Install packages into chroot
  bash_chroot "echo deb $FLAGS_mirror $FLAGS_suite $REPO_SECTIONS \
    > /etc/apt/sources.list"
  in_chroot apt-get update
  in_chroot apt-get --yes --force-yes install reprepro wget

  # Clean up chroot mounts
  cleanup_chroot_mounts
}

# Create reprepro repository
function make_repo {
  echo "Creating repository directory..."
  sudo rm -rf "$REPO"
  sudo mkdir -p "$REPO"
  sudo chown $USER "$REPO"
  mkdir -p "$REPO/conf"
  mkdir -p "$REPO/incoming"

  # Create the distributions conf file
  CONF="$REPO/conf/distributions"
  rm -f "$CONF"
  cat <<EOF > $CONF
Origin: $FLAGS_mirror
Label: Chrome OS Dev
Suite: stable
Codename: $FLAGS_devsuite 
Version: 3.1
Architectures: $REPO_ARCH
Components: $REPO_SECTIONS
Description: Chrome OS Development

Origin: $FLAGS_mirror
Label: Chrome OS
Suite: stable
Codename: $FLAGS_imgsuite 
Version: 3.1
Architectures: $REPO_ARCH
Components: $REPO_SECTIONS
Description: Chrome OS Image
EOF
}

# Update a suite in the repository from a list of packages
function update_suite {
  SUITE="${1:?}"
  PKGLIST="${2:?}"

  echo "Updating $SUITE from $PKGLIST..."

  # Clear the suite first
  # Since packages are either source or not, this removes all of them.
  in_chroot reprepro -b "$REPO_SUBDIR" removefilter "$SUITE" "!Source"
  in_chroot reprepro -b "$REPO_SUBDIR" removefilter "$SUITE" "Source"

  # Add packages to the suite
  echo "Downloading packages..."
  for DEB in `grep -v '^#' < $PKGLIST | awk '{print $1}'`
  do
    echo "Adding $DEB..."

    DEB_PRIO=`cat $PKGLIST | grep '^'$DEB' ' | awk '{print $3}'`
    DEB_SECTION=`cat $PKGLIST | grep '^'$DEB' ' | awk '{print $4}'`
    DEB_PATH=`cat $PKGLIST | grep '^'$DEB' ' | awk '{print $5}'`
    DEB_FILE="$DEB_CACHE_DIR/"`basename $DEB_PATH`

    # Download the package if necessary
    if [ ! -e "$CHROOT/$DEB_FILE" ]
    then
      in_chroot wget --no-verbose "$FLAGS_mirror/${DEB_PATH}" -O "$DEB_FILE"
    fi

    # Copy the file into the target suite with the correct priority
    in_chroot reprepro -b "$REPO_SUBDIR" -P "$DEB_PRIO" -S "$DEB_SECTION" \
      includedeb "$SUITE" "$DEB_FILE"
  done
}

#------------------------------------------------------------------------------

# Create a minimal chroot in which we can run reprepro, if one doesn't
# already exist.  Necessary since the version of reprepro available on
# older systems is buggy.
if [ ! -e "$CHROOT" ]
then
  make_chroot
fi

# Set up chroot mounts
setup_chroot_mounts

# Create/update repo.  Need to run this every time so we rebuild the 
# distributions file.
make_repo

# Create cache directory for downloaded .debs.  This needs to be outside the
# repository so we can delete and rebuild the repository without needing to 
# re-download all the .debs.
if [ ! -e "$CHROOT/$DEB_CACHE_DIR" ]
then
  sudo mkdir -p "$CHROOT/$DEB_CACHE_DIR"
  sudo chown $USER "$CHROOT/$DEB_CACHE_DIR"
fi

# Update the development and image suites
if [ $FLAGS_updev -eq $FLAGS_TRUE ]
then
  update_suite $FLAGS_devsuite $FLAGS_devlist 
fi

if [ $FLAGS_upimg -eq $FLAGS_TRUE ]
then
  update_suite $FLAGS_imgsuite $FLAGS_imglist 
fi

# Clean up the chroot mounts
cleanup_chroot_mounts

echo "Done."
