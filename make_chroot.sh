#!/bin/bash

# Copyright (c) 2009 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# This script sets up an Ubuntu chroot environment. The ideas come
# from https://wiki.ubuntu.com/DebootstrapChroot and conversations with
# tedbo. The script is passed the path to an empty folder, which will be
# populated with the files to form an Ubuntu Jaunty system with the packages
# listed in PACKAGE_LIST_FILE (below) and their dependencies. Once created,
# the password is set to PASSWORD (below). One can enter the chrooted
# environment for work by running
# enter_chroot_dev_environment.sh /path/to/chroot-root

# Load common constants.  This should be the first executable line.
# The path to common.sh should be relative to your script's location.
. "$(dirname "$0")/common.sh"

# Script must be run outside the chroot
assert_outside_chroot

DEFAULT_PKGLIST="$SRC_ROOT/package_repo/package-list-dev.txt"

# Define command line flags
# See http://code.google.com/p/shflags/wiki/Documentation10x
DEFINE_string suite "$DEFAULT_DEV_SUITE" "Repository suite to base image on."
DEFINE_string mirror "$DEFAULT_DEV_MIRROR" "Local repository mirror to use."
DEFINE_string chroot "$DEFAULT_CHROOT_DIR" \
  "Destination dir for the chroot environment."
DEFINE_string pkglist "$DEFAULT_PKGLIST" \
  "File listing additional packages to install."
DEFINE_boolean delete $FLAGS_FALSE "Delete an existing chroot." 
DEFINE_boolean replace $FLAGS_FALSE "Overwrite existing chroot, if any."

# Parse command line flags
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

# Only now can we die on error.  shflags functions leak non-zero error codes,
# so will die prematurely if 'set -e' is specified before now.
# TODO: replace shflags with something less error-prone, or contribute a fix.
set -e

COMPONENTS=`cat $FLAGS_pkglist | grep -v ' *#' | grep -v '^ *$' | tr '\n' ' '`
FULLNAME="Chrome OS dev user"
DEFGROUPS="eng,admin,adm,dialout,cdrom,floppy,audio,dip,video"
PASSWORD=chronos
CRYPTED_PASSWD=$(perl -e 'print crypt($ARGV[0], "foo")', $PASSWORD)

function in_chroot {
  sudo chroot "$FLAGS_chroot" "$@"
}

function bash_chroot {
  # Use $* not $@ since 'bash -c' needs a single arg
  sudo chroot "$FLAGS_chroot" bash -c "$*"
}

function cleanup {
  # Clean up mounts
  mount | grep "on $(readlink -f "$FLAGS_chroot")" | awk '{print $3}' \
    | xargs -r -L1 sudo umount
}

function delete_existing {
  # Delete old chroot dir
  if [ -e "$FLAGS_chroot" ]
  then
    echo "Cleaning up old mount points..."
    cleanup
    echo "Deleting $FLAGS_chroot..."
    sudo rm -rf "$FLAGS_chroot"
  fi
}

# Install packages which may not be installed on the local system
install_if_missing debootstrap

# Add debootstrap link for the suite, if it doesn't exist.
if [ ! -e "/usr/share/debootstrap/scripts/$FLAGS_suite" ]
then
  sudo ln -s /usr/share/debootstrap/scripts/hardy \
    "/usr/share/debootstrap/scripts/$FLAGS_suite"
fi

# Handle deleting an existing environment
if [ $FLAGS_delete -eq $FLAGS_TRUE ]
then
  delete_existing
  echo "Done."
  exit 0
fi

# Handle existing directory
if [ -e "$FLAGS_chroot" ]
then
  if [ $FLAGS_replace -eq $FLAGS_TRUE ]
  then
    delete_existing
  else
    echo "Directory $FLAGS_chroot already exists."
    echo "Use --replace if you really want to overwrite it."
    exit 1
  fi
fi

# Create the destination directory
mkdir -p "$FLAGS_chroot"

# Run debootstrap to create the base chroot environment
echo "Running debootstrap..."
echo "You may need to enter password for sudo now..."
sudo debootstrap --arch=i386 "$FLAGS_suite" "$FLAGS_chroot" "$FLAGS_mirror"
echo "Done running debootstrap."

# Set up necessary mounts
sudo mount none -t proc "$FLAGS_chroot/proc"
sudo mount none -t devpts "$FLAGS_chroot/dev/pts"
# ...and make sure we clean them up on exit
trap cleanup EXIT

# Set up sudoers.  Inside the chroot, the user can sudo without a password.
# (Safe enough, since the only way into the chroot is to 'sudo chroot', so
# the user's already typed in one sudo password...)
bash_chroot "echo %admin ALL=\(ALL\) ALL >> /etc/sudoers"
bash_chroot "echo $USER ALL=NOPASSWD: ALL >> /etc/sudoers"

# Set up apt sources
# If a local repository is used, it will have a different path when 
# bind-mounted inside the chroot
MIRROR_INSIDE="${FLAGS_mirror/$GCLIENT_ROOT/$CHROOT_TRUNK_DIR}"
bash_chroot "echo deb $MIRROR_INSIDE $FLAGS_suite \
  main restricted multiverse universe > /etc/apt/sources.list"
# TODO: enable sources when needed.  Currently, kernel source is checked in
# and all other sources are pulled via DEPS files.
#bash_chroot "echo deb-src $MIRROR_INSIDE $FLAGS_suite \
#  main restricted multiverse universe >> /etc/apt/sources.list"

# Set /etc/debian_chroot so '(chroot)' shows up in shell prompts
CHROOT_BASE=`basename $FLAGS_chroot`
bash_chroot "echo $CHROOT_BASE > /etc/debian_chroot"

# Copy config from outside chroot into chroot
sudo cp /etc/hosts "$FLAGS_chroot/etc/hosts"

# Add ourselves as a user inside the chroot
in_chroot groupadd admin
in_chroot groupadd -g 5000 eng
in_chroot useradd -G ${DEFGROUPS} -g eng -u `id -u` -s \
  /bin/bash -m -c "${FULLNAME}" -p ${CRYPTED_PASSWD} ${USER}

# Bind-mount trunk into chroot so we can install local packages
mkdir "${FLAGS_chroot}$CHROOT_TRUNK_DIR"
sudo mount --bind "$GCLIENT_ROOT" "${FLAGS_chroot}$CHROOT_TRUNK_DIR"

# Niceties for interactive logins ('enter_chroot.sh'); these are ignored
# when specifying a command to enter_chroot.sh.
# Warn less when apt-get installing packqages
echo "export LANG=C" >> "$FLAGS_chroot/home/$USER/.bashrc"
chmod a+x "$FLAGS_chroot/home/$USER/.bashrc"
# Automatically change to scripts directory
echo "cd trunk/src/scripts" >> "$FLAGS_chroot/home/$USER/.profile"

# Warn if attempting to use source control commands inside the chroot
for NOUSE in svn gcl gclient
do
  echo "alias $NOUSE='echo In the chroot, it is a bad idea to run $NOUSE'" \
    >> "$FLAGS_chroot/home/$USER/.profile"
done

if [ "$USER" = "chrome-bot" ]
then
  # Copy ssh keys, so chroot'd chrome-bot can scp files from chrome-web.
  cp -r ~/.ssh "$FLAGS_chroot/home/$USER/"
fi

# Install additional packages
echo "Installing additional packages..."
in_chroot apt-get update
bash_chroot "export DEBIAN_FRONTEND=noninteractive LANG=C && \
  apt-get --yes --force-yes install $COMPONENTS"

# Clean up the chroot mounts
trap - EXIT
cleanup

if [ "$FLAGS_chroot" = "$DEFAULT_CHROOT_DIR" ]
then
  CHROOT_EXAMPLE_OPT=""
else
  CHROOT_EXAMPLE_OPT="--chroot=$FLAGS_chroot"
fi

echo "All set up.  To enter the chroot, run:"
echo "    $SCRIPTS_DIR/enter_chroot.sh $CHROOT_EXAMPLE_OPT"
echo ""
echo "CAUTION: Do *NOT* rm -rf the chroot directory; if there are stale bind"
echo "mounts you may end up deleting your source tree too.  To unmount and"
echo "delete the chroot cleanly, use:"
echo "    $0 --delete $CHROOT_EXAMPLE_OPT"
