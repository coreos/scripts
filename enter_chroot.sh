#!/bin/bash

# Copyright (c) 2011 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Script to enter the chroot environment

# --- BEGIN COMMON.SH BOILERPLATE ---
# Load common CrOS utilities.  Inside the chroot this file is installed in
# /usr/lib/crosutils.  Outside the chroot we find it relative to the script's
# location.
find_common_sh() {
  local common_paths=(/usr/lib/crosutils $(dirname "$(readlink -f "$0")"))
  local path

  SCRIPT_ROOT=
  for path in "${common_paths[@]}"; do
    if [ -r "${path}/common.sh" ]; then
      SCRIPT_ROOT=${path}
      break
    fi
  done
}

find_common_sh
. "${SCRIPT_ROOT}/common.sh" || (echo "Unable to load common.sh" && exit 1)
# --- END COMMON.SH BOILERPLATE ---

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
DEFINE_boolean ssh_agent $FLAGS_TRUE "Import ssh agent."
DEFINE_boolean verbose $FLAGS_FALSE "Print out actions taken"

# More useful help
FLAGS_HELP="USAGE: $0 [flags] [VAR=value] [-- command [arg1] [arg2] ...]

One or more VAR=value pairs can be specified to export variables into
the chroot environment.  For example:

   $0 FOO=bar BAZ=bel

If [-- command] is present, runs the command inside the chroot,
after changing directory to /$USER/trunk/src/scripts.  Note that neither
the command nor args should include single quotes.  For example:

    $0 -- ./build_platform_packages.sh

Otherwise, provides an interactive shell.
"

# Version of info from common.sh that only echos if --verbose is set.
function debug {
  if [ $FLAGS_verbose -eq $FLAGS_TRUE ]; then
    info "$*"
  fi
}

# Double up on the first '--' argument.  Why?  For enter_chroot, we want to
# emulate the behavior of sudo for setting environment vars.  That is, we want:
#   ./enter_chroot [flags] [VAR=val] [-- command]
# ...but shflags ends up eating the '--' out of the command line and gives
# us back "VAR=val" and "command" together in one chunk.  By doubling up, we
# end up getting what we want back from shflags.
#
# Examples of how people might be using enter_chroot:
#  1. ./enter_chroot [chroot_flags]   VAR1=val1 VAR2=val2 -- cmd arg1 arg2
#     Set env vars and run cmd w/ args
#  2. ./enter_chroot [chroot_flags]   VAR1=val1 VAR2=val2
#     Set env vars and run shell
#  3. ./enter_chroot [chroot_flags]   -- cmd arg1 arg2
#     Run cmd w/ args
#  4. ./enter_chroot [chroot_flags]   VAR1=val1 VAR2=val2 cmd arg1 arg2
#     Like #1 _if_ args aren't flags (if they are, enter_chroot will claim them)
#  5. ./enter_chroot [chroot_flags]   cmd arg1 arg2
#     Like #3 _if_ args aren't flags (if they are, enter_chroot will claim them)
_FLAGS_FIXED=''
_SAW_DASHDASH=0
while [ $# -gt 0 ]; do
  _FLAGS_FIXED="${_FLAGS_FIXED:+${_FLAGS_FIXED} }'$1'"
  if [ $_SAW_DASHDASH -eq 0 ] && [[ "$1" == "--" ]]; then
    _FLAGS_FIXED="${_FLAGS_FIXED:+${_FLAGS_FIXED} }'--'"
    _SAW_DASHDASH=1
  fi
  shift
done
eval set -- "${_FLAGS_FIXED}"


# Parse command line flags
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

if [ $FLAGS_official_build -eq $FLAGS_TRUE ]; then
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
SYNCERPIDFILE="${FLAGS_chroot}/var/tmp/enter_chroot_sync.pid"


function ensure_mounted {
  # If necessary, mount $source in the host FS at $target inside the
  # chroot directory with $mount_args.
  local source="$1"
  local mount_args="$2"
  local target="$3"

  local mounted_path="$(readlink -f "${FLAGS_chroot}/$target")"

  if [ -z "$(mount | grep -F "on ${mounted_path} ")" ]; then
    # Attempt to make the mountpoint as the user.  This depends on the
    # fact that all mountpoints that should be owned by root are
    # already present.
    mkdir -p "${mounted_path}"

    # NB:  mount_args deliberately left unquoted
    debug mount ${mount_args} "${source}" "${mounted_path}"
    sudo -- mount ${mount_args} "${source}" "${mounted_path}" || \
      die "Could not mount ${source} on ${mounted_path}"
  fi
}

function env_sync_proc {
  # This function runs and performs periodic updates to the chroot env, if
  # necessary.

  local poll_interval=10
  local sync_files="etc/resolv.conf etc/hosts"

  # Make sure the synced files are writable by normal user, so that we
  # don't have to sudo inside the loop.
  for file in ${sync_files}; do
    sudo chown ${USER} ${FLAGS_chroot}/${file} 1>&2
  done

  while true; do
    # Sync files
    for file in ${sync_files}; do
      if ! cmp /${file} ${FLAGS_chroot}/${file} &> /dev/null; then
        cp -f /${file} ${FLAGS_chroot}/${file}
      fi
    done

    sleep ${poll_interval}
  done
}

function setup_env {
  # Validate sudo timestamp before entering the critical section so that we
  # don't stall for a password while we have the lockfile.
  # Don't use sudo -v since that has issues on machines w/ no password.
  sudo echo "" > /dev/null

  # Syncer proc, but only the first time
  if ! [ -f "${SYNCERPIDFILE}" ] || \
     ! [ -d /proc/$(cat "${SYNCERPIDFILE}") ]; then
    debug "Starting sync process"
    env_sync_proc &
    echo $! > "${SYNCERPIDFILE}"
    disown $!
  fi

  (
    flock 200
    echo $$ >> "$LOCKFILE"

    debug "Mounting chroot environment."
    ensure_mounted none "-t proc" /proc
    ensure_mounted none "-t sysfs" /sys
    ensure_mounted /dev "--bind" /dev
    ensure_mounted none "-t devpts" /dev/pts
    ensure_mounted "${FLAGS_trunk}" "--bind" "${CHROOT_TRUNK_DIR}"

    if [ $FLAGS_ssh_agent -eq $FLAGS_TRUE ]; then
      TARGET_DIR="$(readlink -f "${FLAGS_chroot}/home/${USER}/.ssh")"
      if [ -n "${SSH_AUTH_SOCK}" -a -d "${HOME}/.ssh" ]; then
        mkdir -p "${TARGET_DIR}"
        cp -r "${HOME}/.ssh/known_hosts" "${TARGET_DIR}"
        cp -r "${HOME}/.ssh/config" "${TARGET_DIR}"
        ASOCK="$(dirname "${SSH_AUTH_SOCK}")"
        ensure_mounted "${ASOCK}" "--bind" "${ASOCK}"
      fi
    fi

    MOUNTED_PATH="$(readlink -f "${FLAGS_chroot}${INNER_CHROME_ROOT}")"
    if [ -z "$(mount | grep -F "on $MOUNTED_PATH ")" ]; then
      ! CHROME_ROOT="$(readlink -f "$FLAGS_chrome_root")"
      if [ -z "$CHROME_ROOT" ]; then
        ! CHROME_ROOT="$(cat "${FLAGS_chroot}${CHROME_ROOT_CONFIG}" \
          2>/dev/null)"
        CHROME_ROOT_AUTO=1
      fi
      if [[ ( -n "$CHROME_ROOT" ) ]]; then
        if [[ ( ! -d "${CHROME_ROOT}/src" ) ]]; then
          error "Not mounting chrome source"
          sudo rm -f "${FLAGS_chroot}${CHROME_ROOT_CONFIG}"
          if [[ ! "$CHROME_ROOT_AUTO" ]]; then
            exit 1
          fi
        else
          debug "Mounting chrome source at: $INNER_CHROME_ROOT"
          sudo bash -c "echo '$CHROME_ROOT' > \
            '${FLAGS_chroot}${CHROME_ROOT_CONFIG}'"
          mkdir -p "$MOUNTED_PATH"
          sudo mount --bind "$CHROME_ROOT" "$MOUNTED_PATH" || \
            die "Could not mount $MOUNTED_PATH"
        fi
      fi
    fi

    MOUNTED_PATH="$(readlink -f "${FLAGS_chroot}${INNER_DEPOT_TOOLS_ROOT}")"
    if [ -z "$(mount | grep -F "on $MOUNTED_PATH ")" ]; then
      if [ $(which gclient 2>/dev/null) ]; then
        debug "Mounting depot_tools"
        DEPOT_TOOLS=$(dirname "$(which gclient)")
        mkdir -p "$MOUNTED_PATH"
        if ! sudo mount --bind "$DEPOT_TOOLS" "$MOUNTED_PATH"; then
          warn "depot_tools failed to mount; perhaps it's on NFS?"
          warn "This may impact chromium build."
        fi
      fi
    fi

    # Install fuse module.
    if [ -c "${FUSE_DEVICE}" ]; then
      sudo modprobe fuse 2> /dev/null ||\
        warn "-- Note: modprobe fuse failed.  gmergefs will not work"
    fi

    # Turn off automounting of external media when we enter the
    # chroot; thus we don't have to worry about being able to unmount
    # from inside.
    if [ $(which gconftool-2 2>/dev/null) ]; then
      gconftool-2 -g ${AUTOMOUNT_PREF} > \
        "${FLAGS_chroot}${SAVED_AUTOMOUNT_PREF_FILE}"
      if [ $(gconftool-2 -s --type=boolean ${AUTOMOUNT_PREF} false) ]; then
        warn "-- Note: USB sticks may be automounted by your host OS."
        warn "-- Note: If you plan to burn bootable media, you may need to"
        warn "-- Note: unmount these devices manually, or run image_to_usb.sh"
        warn "-- Note: outside the chroot."
      fi
    fi

    # Fix permissions on shared memory to allow non-root users access to POSIX
    # semaphores.
    sudo chmod -R 777 "${FLAGS_chroot}/dev/shm"
  ) 200>>"$LOCKFILE" || die "setup_env failed"
}

function teardown_env {
  # Validate sudo timestamp before entering the critical section so that we
  # don't stall for a password while we have the lockfile.
  # Don't use sudo -v since that has issues on machines w/ no password.
  sudo echo "" > /dev/null

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
        warn "could not re-set your automount preference."
    fi

    if [ -s "$LOCKFILE" ]; then
      debug "At least one other pid is running in the chroot, so not"
      debug "tearing down env."
    else
      debug "Stopping syncer process"
      kill $(cat "${SYNCERPIDFILE}")

      MOUNTED_PATH=$(readlink -f "$FLAGS_chroot")
      debug "Unmounting chroot environment."
      # sort the list of mounts in reverse order, to ensure umount of
      # cascading mounts in proper order
      for i in \
        $(mount | grep -F "on $MOUNTED_PATH/" | sort -r | awk '{print $3}'); do
        safe_umount "$i"
      done
    fi
  ) 200>>"$LOCKFILE" || die "teardown_env failed"
}

# This function does extra "fixups" of the chroot.  It's a lot like
# chroot_hacks_from_outside() in common.sh, except that it is only called
# from enter_chroot.sh (chroot_hacks_from_outside is also called from
# make_chroot.sh).  This function was created because common.sh is on lockdown
# and can't be changed.
#
# NOTE: the need for this type of "fixup" should be going away.  If everything
# in the chroot is versioned and nothing is generated, there is no need to
# handle partly fixing up generated files.
#
# Please put date information so it's easy to keep track of when
# old hacks can be retired and so that people can detect when a
# hack triggered when it shouldn't have.
function chroot_hacks_too() {
  local chroot_home="${FLAGS_chroot}/home/${USER}"

  # Add chromite stuff if not already done.
  if ! grep -q "^PATH=.*/trunk/chromite/bin" "${chroot_home}/.bashrc"; then
    info "Upgrading old chroot (pre 2011-02-09) - adding chromite to path"
    echo "PATH=\$PATH:/home/${USER}/trunk/chromite/bin" >> \
      "${chroot_home}/.bashrc"
  fi
  if ! [ -L "${chroot_home}/.local/lib/python2.6/site-packages/chromite" ]; then
    info "Upgrading old chroot (pre 2011-02-09) - add chromite to site-packages"
    mkdir -p "${chroot_home}/.local/lib/python2.6/site-packages"
    ln -s ../../../../trunk/chromite \
      "${chroot_home}/.local/lib/python2.6/site-packages/"
  fi
}


if [ $FLAGS_mount -eq $FLAGS_TRUE ]; then
  setup_env
  info "Make sure you run"
  info "    $0 --unmount"
  info "before deleting $FLAGS_chroot"
  info "or you'll end up deleting $FLAGS_trunk too!"
  exit 0
fi

if [ $FLAGS_unmount -eq $FLAGS_TRUE ]; then
  teardown_env
  exit 0
fi

# Apply any hacks needed to update the chroot.
chroot_hacks_from_outside "${FLAGS_chroot}"
chroot_hacks_too


# Make sure we unmount before exiting
trap teardown_env EXIT
setup_env

CHROOT_PASSTHRU="BUILDBOT_BUILD=$FLAGS_build_number CHROMEOS_OFFICIAL=$CHROMEOS_OFFICIAL"
CHROOT_PASSTHRU="${CHROOT_PASSTHRU} \
CHROMEOS_RELEASE_APPID=${CHROMEOS_RELEASE_APPID:-"{DEV-BUILD}"}"

# Set CHROMEOS_VERSION_TRACK, CHROMEOS_VERSION_AUSERVER,
# CHROMEOS_VERSION_DEVSERVER as environment variables to override the default
# assumptions (local AU server). These are used in cros_set_lsb_release, and
# are used by external Chromium OS builders.
CHROOT_PASSTHRU="${CHROOT_PASSTHRU} \
CHROMEOS_VERSION_TRACK=${CHROMEOS_VERSION_TRACK} \
CHROMEOS_VERSION_AUSERVER=${CHROMEOS_VERSION_AUSERVER} \
CHROMEOS_VERSION_DEVSERVER=${CHROMEOS_VERSION_DEVSERVER}"

# Pass proxy variables into the environment.
for type in http_proxy ftp_proxy all_proxy GIT_PROXY_COMMAND GIT_SSH; do
   eval value=\$${type}
   if [ -n "${value}" ]; then
      CHROOT_PASSTHRU="${CHROOT_PASSTHRU} ${type}=${value}"
   fi
done

if [ -d "$HOME/.subversion" ]; then
  TARGET="/home/${USER}/.subversion"
  mkdir -p "${FLAGS_chroot}${TARGET}"
  ensure_mounted "${HOME}/.subversion" "--bind" "${TARGET}"
fi

# Configure committer username and email in chroot .gitconfig
git config -f ${FLAGS_chroot}/home/${USER}/.gitconfig --replace-all \
  user.name "$(cd /tmp; git var GIT_COMMITTER_IDENT | sed -e 's/ *<.*//')" ||
    true
git config -f ${FLAGS_chroot}/home/${USER}/.gitconfig --replace-all \
  user.email "$(cd /tmp; git var GIT_COMMITTER_IDENT | \
    sed -e 's/.*<\([^>]*\)>.*/\1/')" ||
      true

# Run command or interactive shell.  Also include the non-chrooted path to
# the source trunk for scripts that may need to print it (e.g.
# build_image.sh).
sudo -- chroot "$FLAGS_chroot" sudo -i -u $USER $CHROOT_PASSTHRU \
  EXTERNAL_TRUNK_PATH="${FLAGS_trunk}" LANG=C SSH_AGENT_PID="${SSH_AGENT_PID}" \
  SSH_AUTH_SOCK="${SSH_AUTH_SOCK}" "$@"

# Remove trap and explicitly unmount
trap - EXIT
teardown_env
