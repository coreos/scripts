#!/bin/bash

# Copyright (c) 2009 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Script to enter the chroot environment

# Load common constants.  This should be the first executable line.
# The path to common.sh should be relative to your script's location.
. "$(dirname "$0")/common.sh"

# Script must be run outside the chroot and as a regular user.
assert_outside_chroot
assert_not_root_user

# Define command line flags
# See http://code.google.com/p/shflags/wiki/Documentation10x
DEFINE_string chroot "$DEFAULT_CHROOT_DIR" \
  "The destination dir for the chroot environment." "d"
DEFINE_string trunk "$GCLIENT_ROOT" \
  "The source trunk to bind mount within the chroot." "s"
DEFINE_string build_number "" \
  "The build-bot build number (when called by buildbot only)." "b"
DEFINE_string chrome_root "" \
  "The root of your chrome browser source. Should contain a 'src' subdir."
DEFINE_string chrome_root_mount "/home/$USER/chrome_root" \
  "The mount point of the chrome broswer source in the chroot."

DEFINE_boolean official_build $FLAGS_FALSE \
  "Set CHROMEOS_OFFICIAL=1 for release builds."
DEFINE_boolean mount $FLAGS_FALSE "Only set up mounts."
DEFINE_boolean unmount $FLAGS_FALSE "Only tear down mounts."

# More useful help
FLAGS_HELP="USAGE: $0 [flags] [VAR=value] [-- \"command\"]

One or more VAR=value pairs can be specified to export variables into
the chroot environment.  For example:

   $0 FOO=bar BAZ=bel

If [-- \"command\"] is present, runs the command inside the chroot,
after changing directory to /$USER/trunk/src/scripts.  Note that the
command should be enclosed in quotes to prevent interpretation by the
shell before getting into the chroot.  For example:

    $0 -- \"./build_platform_packages.sh\"

Otherwise, provides an interactive shell.
"

# Parse command line flags
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

if [ $FLAGS_official_build -eq $FLAGS_TRUE ]
then
   CHROMEOS_OFFICIAL=1
fi

# Only now can we die on error.  shflags functions leak non-zero error codes,
# so will die prematurely if 'set -e' is specified before now.
# TODO: replace shflags with something less error-prone, or contribute a fix.
set -e

INNER_CHROME_ROOT=$FLAGS_chrome_root_mount  # inside chroot
CHROME_ROOT_CONFIG="/var/cache/chrome_root"  # inside chroot
INNER_DEPOT_TOOLS_ROOT="/home/$USER/depot_tools"  # inside chroot
FUSE_DEVICE="/dev/fuse"
AUTOMOUNT_PREF="/apps/nautilus/preferences/media_automount"
SAVED_AUTOMOUNT_PREF_FILE="/tmp/.automount_pref"

sudo chmod 0777 "$FLAGS_chroot/var/lock"

LOCKFILE="$FLAGS_chroot/var/lock/enter_chroot"

function setup_env {
  (
    flock 200
    echo $$ >> "$LOCKFILE"

    echo "Mounting chroot environment."

    # Mount only if not already mounted
    MOUNTED_PATH="$(readlink -f "$FLAGS_chroot/proc")"
    if [ -z "$(mount | grep -F "on $MOUNTED_PATH ")" ]
    then
      sudo mount none -t proc "$MOUNTED_PATH" || \
          die "Could not mount $MOUNTED_PATH"
    fi

    MOUNTED_PATH="$(readlink -f "$FLAGS_chroot/sys")"
    if [ -z "$(mount | grep -F "on $MOUNTED_PATH ")" ]
    then
      sudo mount none -t sysfs "$MOUNTED_PATH" || \
          die "Could not mount $MOUNTED_PATH"
    fi

    MOUNTED_PATH="$(readlink -f "${FLAGS_chroot}/dev")"
    if [ -z "$(mount | grep -F "on $MOUNTED_PATH ")" ]
    then
      sudo mount --bind /dev "$MOUNTED_PATH" || \
          die "Could not mount $MOUNTED_PATH"
    fi

    MOUNTED_PATH="$(readlink -f "${FLAGS_chroot}/dev/pts")"
    if [ -z "$(mount | grep -F "on $MOUNTED_PATH ")" ]
    then
      sudo mount none -t devpts "$MOUNTED_PATH" || \
          die "Could not mount $MOUNTED_PATH"
    fi

    MOUNTED_PATH="$(readlink -f "${FLAGS_chroot}$CHROOT_TRUNK_DIR")"
    if [ -z "$(mount | grep -F "on $MOUNTED_PATH ")" ]
    then
      sudo mount --bind "$FLAGS_trunk" "$MOUNTED_PATH" || \
          die "Could not mount $MOUNTED_PATH"
    fi

    MOUNTED_PATH="$(readlink -f "${FLAGS_chroot}${INNER_CHROME_ROOT}")"
    if [ -z "$(mount | grep -F "on $MOUNTED_PATH ")" ]
    then
      ! CHROME_ROOT="$(readlink -f "$FLAGS_chrome_root")"
      if [ -z "$CHROME_ROOT" ]; then
        ! CHROME_ROOT="$(cat "${FLAGS_chroot}${CHROME_ROOT_CONFIG}" \
          2>/dev/null)"
      fi
      if [[ ( -z "$CHROME_ROOT" ) || ( ! -d "${CHROME_ROOT}/src" ) ]]; then
        echo "Not mounting chrome source"
        sudo rm -f "${FLAGS_chroot}${CHROME_ROOT_CONFIG}"
      else
        echo "Mounting chrome source at: $INNER_CHROME_ROOT"
        echo "$CHROME_ROOT" | \
          sudo dd of="${FLAGS_chroot}${CHROME_ROOT_CONFIG}"
        mkdir -p "$MOUNTED_PATH"
        sudo mount --bind "$CHROME_ROOT" "$MOUNTED_PATH" || \
          die "Could not mount $MOUNTED_PATH"
      fi
    fi

    MOUNTED_PATH="$(readlink -f "${FLAGS_chroot}${INNER_DEPOT_TOOLS_ROOT}")"
    if [ -z "$(mount | grep -F "on $MOUNTED_PATH ")" ]
    then
      if [ $(which gclient 2>/dev/null) ]; then
        echo "Mounting depot_tools"
        DEPOT_TOOLS=$(dirname $(which gclient) )
        mkdir -p "$MOUNTED_PATH"
        if ! sudo mount --bind "$DEPOT_TOOLS" "$MOUNTED_PATH"; then
          echo "depot_tools failed to mount; perhaps it's on NFS?"
          echo "This may impact chromium build."
        fi
      fi
    fi

    # Install fuse module.
    if [ -c "${FUSE_DEVICE}" ] ; then
      sudo modprobe fuse 2> /dev/null ||\
        echo "-- Note: modprobe fuse failed.  gmergefs will not work"
    fi

    # Turn off automounting of external media when we enter the
    # chroot; thus we don't have to worry about being able to unmount
    # from inside.
    if [ $(which gconftool-2 2>/dev/null) ]; then
      gconftool-2 -g ${AUTOMOUNT_PREF} > \
        "${FLAGS_chroot}${SAVED_AUTOMOUNT_PREF_FILE}"
      if [ $(gconftool-2 -s --type=boolean ${AUTOMOUNT_PREF} false) ]; then
        echo "-- Note: USB sticks may be automounted by your host OS."
        echo "-- Note: If you plan to burn bootable media, you may need to"
        echo "-- Note: unmount these devices manually, or run image_to_usb.sh"
        echo "-- Note: outside the chroot."
      fi
    fi

  ) 200>>"$LOCKFILE" || die "setup_env failed"
}

function teardown_env {
  # Only teardown if we're the last enter_chroot to die
  (
    flock 200

    # check each pid in $LOCKFILE to see if it's died unexpectedly
    TMP_LOCKFILE="$LOCKFILE.tmp"

    echo -n > "$TMP_LOCKFILE"  # Erase/reset temp file
    cat "$LOCKFILE" | while read PID; do
      if [ "$PID" = "$$" ]; then
        # ourself, leave PROC_NAME empty
        PROC_NAME=""
      else
        PROC_NAME=$(ps --pid $PID -o comm=)
      fi

      if [ ! -z "$PROC_NAME" ]; then
        # All good, keep going
        echo "$PID" >> "$TMP_LOCKFILE"
      fi
    done
    # Remove any dups from lock file while installing new one
    sort -n "$TMP_LOCKFILE" | uniq > "$LOCKFILE"

    if [ $(which gconftool-2 2>/dev/null) ]; then
      SAVED_PREF=$(cat "${FLAGS_chroot}${SAVED_AUTOMOUNT_PREF_FILE}")
      gconftool-2 -s --type=boolean ${AUTOMOUNT_PREF} ${SAVED_PREF} || \
        echo "could not re-set your automount preference."
    fi

    if [ -s "$LOCKFILE" ]; then
      echo "At least one other pid is running in the chroot, so not"
      echo "tearing down env."
    else
      MOUNTED_PATH=$(readlink -f "$FLAGS_chroot")
      echo "Unmounting chroot environment."
      # sort the list of mounts in reverse order, to ensure umount of
      # cascading mounts in proper order
      for i in \
        $(mount | grep -F "on $MOUNTED_PATH/" | sort -r | awk '{print $3}'); do
        safe_umount "$i"
      done
    fi
  ) 200>>"$LOCKFILE" || die "teardown_env failed"
}

if [ $FLAGS_mount -eq $FLAGS_TRUE ]
then
  setup_env
  echo "Make sure you run"
  echo "    $0 --unmount"
  echo "before deleting $FLAGS_chroot"
  echo "or you'll end up deleting $FLAGS_trunk too!"
  exit 0
fi

if [ $FLAGS_unmount -eq $FLAGS_TRUE ]
then
  teardown_env
  exit 0
fi

# Make sure we unmount before exiting
trap teardown_env EXIT
setup_env

# Get the git revision to pass into the chroot.
#
# This must be determined outside the chroot because (1) there is no
# git inside the chroot, and (2) if there were it would likely be
# the wrong version, which would mess up the .git directories.
#
# Note that this fixes $CHROMEOS_REVISION at the time the chroot is
# entered.  That's ok for the main use case of automated builds,
# which pass each command line into a separate call to enter_chroot
# so always have up-to-date info.  For developer builds, there may not
# be a single revision, since the developer may have
# hand-sync'd some subdirs and edited files in others.
# In that case, check against origin/HEAD and mark** revision.
# Use git:8 chars of sha1
REVISION=$(git rev-parse --short=8 HEAD)
CHROOT_PASSTHRU="CHROMEOS_REVISION=$REVISION BUILDBOT_BUILD=$FLAGS_build_number CHROMEOS_OFFICIAL=$CHROMEOS_OFFICIAL"

# Run command or interactive shell.  Also include the non-chrooted path to
# the source trunk for scripts that may need to print it (e.g.
# build_image.sh).
sudo chroot "$FLAGS_chroot" sudo -i -u $USER $CHROOT_PASSTHRU \
  EXTERNAL_TRUNK_PATH="${FLAGS_trunk}" LANG=C "$@"

# Remove trap and explicitly unmount
trap - EXIT
teardown_env
