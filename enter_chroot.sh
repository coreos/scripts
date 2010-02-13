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

DEFINE_boolean official_build $FLAGS_FALSE "Set CHROMEOS_OFFICIAL=1 for release builds."
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

INNER_CHROME_ROOT="/home/$USER/chrome_root"  # inside chroot
CHROME_ROOT_CONFIG="/var/cache/chrome_root"  # inside chroot
INNER_DEPOT_TOOLS_ROOT="/home/$USER/depot_tools"  # inside chroot

sudo chmod 0777 "$FLAGS_chroot/var/lock"

LOCKFILE="$FLAGS_chroot/var/lock/enter_chroot"

function setup_env {
  (
    flock 200
    echo $$ >> "$LOCKFILE"

    echo "Mounting chroot environment."

    # Mount only if not already mounted
    MOUNTED_PATH="$(readlink -f "$FLAGS_chroot/proc")"
    if [ -z "$(mount | grep -F "on $MOUNTED_PATH")" ]
    then
      sudo mount none -t proc "$MOUNTED_PATH"
    fi

    MOUNTED_PATH="$(readlink -f "$FLAGS_chroot/dev/pts")"
    if [ -z "$(mount | grep -F "on $MOUNTED_PATH")" ]
    then
      sudo mount none -t devpts "$MOUNTED_PATH"
    fi

    MOUNTED_PATH="$(readlink -f "${FLAGS_chroot}$CHROOT_TRUNK_DIR")"
    if [ -z "$(mount | grep -F "on $MOUNTED_PATH")" ]
    then
      sudo mount --bind "$FLAGS_trunk" "$MOUNTED_PATH"
    fi

    MOUNTED_PATH="$(readlink -f "${FLAGS_chroot}${INNER_CHROME_ROOT}")"
    if [ -z "$(mount | grep -F "on $MOUNTED_PATH")" ]
    then
      CHROME_ROOT="$FLAGS_chrome_root"
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
        sudo mount --bind "$CHROME_ROOT" "$MOUNTED_PATH"
      fi
    fi

    MOUNTED_PATH="$(readlink -f "${FLAGS_chroot}${INNER_DEPOT_TOOLS_ROOT}")"
    if [ -z "$(mount | grep -F "on $MOUNTED_PATH")" ]
    then
      if [ $(which gclient 2>/dev/null) ]; then
        echo "Mounting depot_tools"
        DEPOT_TOOLS=$(dirname $(which gclient) )
        mkdir -p "$MOUNTED_PATH"
        sudo mount --bind "$DEPOT_TOOLS" "$MOUNTED_PATH"
      fi
    fi
  ) 200>>"$LOCKFILE"
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

    if [ -s "$LOCKFILE" ]; then
      echo "At least one other pid is running in the chroot, so not"
      echo "tearing down env."
    else
      echo "Unmounting chroot environment."
      mount | grep "on $(readlink -f "$FLAGS_chroot")" | awk '{print $3}' \
        | xargs -r -L1 sudo umount
    fi
  ) 200>>"$LOCKFILE"
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
REVISION=$(git rev-parse HEAD)
ORIGIN_REVISION=$(git rev-parse origin/HEAD)
# Do not check for clean revision on official builds.  They are coming directly
# from a branch rev and cannot compare to origin/HEAD.
if [ $FLAGS_official_build != $FLAGS_TRUE ] && \
   [ "$REVISION" != "$ORIGIN_REVISION" ]
then
  # Mark dirty tree with "**"
  REVISION="${REVISION:0:8}**"
else
  REVISION="${REVISION:0:8}"
fi
CHROOT_PASSTHRU="CHROMEOS_REVISION=$REVISION BUILDBOT_BUILD=$FLAGS_build_number CHROMEOS_OFFICIAL=$CHROMEOS_OFFICIAL"

# Run command or interactive shell.  Also include the non-chrooted path to
# the source trunk for scripts that may need to print it (e.g.
# build_image.sh).
sudo chroot "$FLAGS_chroot" sudo -i -u $USER $CHROOT_PASSTHRU \
  EXTERNAL_TRUNK_PATH="${FLAGS_trunk}" LANG=C "$@"

# Remove trap and explicitly unmount
trap - EXIT
teardown_env
