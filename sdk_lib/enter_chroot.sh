#!/bin/bash

# Copyright (c) 2011 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Script to enter the chroot environment

SCRIPT_ROOT=$(readlink -f $(dirname "$0")/..)
. "${SCRIPT_ROOT}/common.sh" || exit 1

enable_strict_sudo

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
DEFINE_string distfiles "" \
  "Override the destination dir used for distfiles."

DEFINE_boolean official_build $FLAGS_FALSE \
  "Set CHROMEOS_OFFICIAL=1 for release builds."
DEFINE_boolean mount $FLAGS_FALSE "Only set up mounts."
DEFINE_boolean unmount $FLAGS_FALSE "Only tear down mounts."
DEFINE_boolean ssh_agent $FLAGS_TRUE "Import ssh agent."
DEFINE_boolean early_make_chroot $FLAGS_FALSE \
  "Internal flag.  If set, the command is run as root without sudo."
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
debug() {
  if [ $FLAGS_verbose -eq $FLAGS_TRUE ]; then
    info "$*"
  fi
}

# Parse command line flags
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

if [ $FLAGS_official_build -eq $FLAGS_TRUE ]; then
   CHROMEOS_OFFICIAL=1
fi

[ -z "${FLAGS_distfiles}" ] && \
  FLAGS_distfiles="${FLAGS_trunk}/distfiles"

# Only now can we die on error.  shflags functions leak non-zero error codes,
# so will die prematurely if 'switch_to_strict_mode' is specified before now.
# TODO: replace shflags with something less error-prone, or contribute a fix.
switch_to_strict_mode

# These config files are to be copied into chroot if they exist in home dir.
FILES_TO_COPY_TO_CHROOT=(
  .gdata_cred.txt             # User/password for Google Docs on chromium.org
  .gdata_token                # Auth token for Google Docs on chromium.org
  .disable_build_stats_upload # Presence of file disables command stats upload
)

INNER_CHROME_ROOT=$FLAGS_chrome_root_mount  # inside chroot
CHROME_ROOT_CONFIG="/var/cache/chrome_root"  # inside chroot
INNER_DEPOT_TOOLS_ROOT="/home/$USER/depot_tools"  # inside chroot
FUSE_DEVICE="/dev/fuse"
AUTOMOUNT_PREF="/apps/nautilus/preferences/media_automount"
SAVED_AUTOMOUNT_PREF_FILE="/tmp/.automount_pref"

# Avoid the sudo call if possible since it is a little slow.
if [ $(stat -c %a "$FLAGS_chroot/var/lock") != 777 ]; then
  sudo chmod 0777 "$FLAGS_chroot/var/lock"
fi

LOCKFILE="$FLAGS_chroot/var/lock/enter_chroot"
SYNCERPIDFILE="${FLAGS_chroot}/var/tmp/enter_chroot_sync.pid"


MOUNTED_PATH=$(readlink -f "$FLAGS_chroot")
mount_queue_init() {
  MOUNT_QUEUE=()
}

queue_mount() {
  # If necessary, mount $source in the host FS at $target inside the
  # chroot directory with $mount_args.
  local source="$1"
  local mount_args="$2"
  local target="$3"

  local mounted_path="${MOUNTED_PATH}$target"

  case " ${MOUNT_CACHE} " in
  *" ${mounted_path} "*)
    # Already mounted!
    ;;
  *)
    MOUNT_QUEUE+=(
      "mkdir -p '${mounted_path}'"
      # The args are left unquoted on purpose.
      "mount ${mount_args} '${source}' '${mounted_path}'"
    )
    ;;
  esac
}

process_mounts() {
  if [[ ${#MOUNT_QUEUE[@]} -eq 0 ]]; then
    return 0
  fi
  sudo_multi "${MOUNT_QUEUE[@]}"
  mount_queue_init
}

env_sync_proc() {
  # This function runs and performs periodic updates to the chroot env, if
  # necessary.

  local poll_interval=10
  local sync_files=( etc/resolv.conf etc/hosts )

  # Make sure the files exist before the find -- they might not in a
  # fresh chroot which results in warnings in the build output.
  local chown_cmd=(
    # Make sure the files exists first -- they might not in a fresh chroot.
    "touch ${sync_files[*]/#/${FLAGS_chroot}/}"
    # Make sure the files are writable by normal user so that we don't have
    # to execute sudo in the main loop below.
    "chown ${USER} ${sync_files[*]/#/${FLAGS_chroot}/}"
  )
  sudo_multi "${chown_cmd[@]}"

  # Drop stdin, stderr, stdout, and chroot lock.
  # This is needed for properly daemonizing the process.
  exec 0>&- 1>&- 2>&- 200>&-

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

copy_ssh_config() {
  # Copy user .ssh/config into the chroot filtering out strings not supported
  # by the chroot ssh. The chroot .ssh directory is passed in as the first
  # parameter.

  # ssh options to filter out. The entire strings containing these substrings
  # will be deleted before copying.
  local bad_options=(
    'UseProxyIf'
    'GSSAPIAuthentication'
    'GSSAPIKeyExchange'
    'ProxyUseFdpass'
  )
  local sshc="${HOME}/.ssh/config"
  local chroot_ssh_dir="${1}"
  local filter
  local option

  if [ ! -f "${sshc}" ]; then
    return # Nothing to copy.
  fi

  for option in "${bad_options[@]}"
  do
    if [ -z "${filter}" ]; then
      filter="${option}"
    else
      filter+="\\|${option}"
    fi
  done

  sed "/^.*\(${filter}\).*$/d" "${sshc}" > "${chroot_ssh_dir}/config"
}

copy_into_chroot_if_exists() {
  # $1 is file path outside of chroot to copy to path $2 inside chroot.
  [ -e "$1" ] || return
  cp "$1" "${FLAGS_chroot}/$2"
}

setup_env() {
  # Validate sudo timestamp before entering the critical section so that we
  # don't stall for a password while we have the lockfile.
  # Don't use sudo -v since that has issues on machines w/ no password.
  sudo echo "" > /dev/null

  (
    flock 200
    echo $$ >> "$LOCKFILE"

    # If there isn't a syncer daemon started already, start one.  The
    # daemon is considered to not be started under the following
    # conditions:
    #
    #   o There is no PID file
    #
    #   o The PID file is 0 bytes in size, which might be a partial
    #     manifestation of chromium-os:17680.  This situation will not
    #     occur anymore, but you might have a chroot which was already
    #     affected.
    #
    #   o The /proc node for the process named by the PID file does
    #     not exist.
    #
    #     Note: This does not address PID recycling.  While
    #           increasingly unlikely, it is possible for the PID in
    #           the PID file to refer to a running process that is not
    #           the syncer process.  Since the PID file is now
    #           removed, I think it is only possible for this to occur
    #           if your system crashes and the PID file exists after
    #           restart.
    #
    # The daemon is killed by the enter_chroot that exits last.
    if [ -f "${SYNCERPIDFILE}" ] && [ ! -s "${SYNCERPIDFILE}" ] ; then
        info "You may have suffered from chromium-os:17680 and";
        info "could have stray 'enter_chroot.sh' processes running.";
        info "You must manually kill any such stray processes.";
        info "Exit all chroot shells; remaining 'enter_chroot.sh'";
        info "processes are probably stray.";
        sudo rm -f "${SYNCERPIDFILE}";
    fi;
    if ! [ -f "${SYNCERPIDFILE}" ] || \
       ! [ -d /proc/$(<"${SYNCERPIDFILE}") ]; then
      debug "Starting sync process"
      env_sync_proc &
      echo $! > "${SYNCERPIDFILE}"
      disown $!
    fi

    # Turn off automounting of external media when we enter the chroot by
    # stopping the gvfs-gdu-volume-monitor and gvfsd-trash daemons. This is
    # currently the most reliable way to disable automounting.
    # See https://bugzilla.gnome.org/show_bug.cgi?id=677648
    sudo killall -STOP -r '^gvfs-gdu-volume.*$|^gvfsd-trash$' 2>/dev/null \
      || true

    debug "Mounting chroot environment."
    MOUNT_CACHE=$(echo $(awk '{print $2}' /proc/mounts))
    mount_queue_init
    queue_mount none "-t proc" /proc
    queue_mount none "-t sysfs" /sys
    queue_mount /dev "--bind" /dev
    queue_mount none "-t devpts" /dev/pts
    if [ -d /run ]; then
      queue_mount /run "--bind" /run
      if [ -d /run/shm ]; then
        queue_mount /run/shm "--bind" /run/shm
      fi
    fi
    queue_mount "${FLAGS_trunk}" "--bind" "${CHROOT_TRUNK_DIR}"


    debug "Setting up referenced repositories if required."
    REFERENCE_DIR=$(git config --file  \
      "${FLAGS_trunk}/.repo/manifests.git/config" \
      repo.reference)
    if [ -n "${REFERENCE_DIR}" ]; then

      ALTERNATES="${FLAGS_trunk}/.repo/alternates"

      # Ensure this directory exists ourselves, and has the correct ownership.
      [ -d "${ALTERNATES}" ] || mkdir "${ALTERNATES}"
      [ -w "${ALTERNATES}" ] || sudo chown -R "${USER}" "${ALTERNATES}"

      unset ALTERNATES

      IFS=$'\n';
      required=( $( "${FLAGS_trunk}/chromite/lib/rewrite_git_alternates.py" \
        "${FLAGS_trunk}" "${REFERENCE_DIR}" "${CHROOT_TRUNK_DIR}" ) )
      unset IFS

      queue_mount "${FLAGS_trunk}/.repo/chroot/alternates" --bind \
        "${CHROOT_TRUNK_DIR}/.repo/alternates"

      # Note that as we're bringing up each referened repo, we also
      # mount bind an empty directory over its alternates.  This is
      # required to suppress git from tracing through it- we already
      # specify the required alternates for CHROOT_TRUNK_DIR, no point
      # in having git try recursing through each on their own.
      #
      # Finally note that if you're unfamiliar w/ chroot/vfs semantics,
      # the bind is visible only w/in the chroot.
      mkdir -p ${FLAGS_trunk}/.repo/chroot/empty
      position=1
      for x in "${required[@]}"; do
        base="${CHROOT_TRUNK_DIR}/.repo/chroot/external${position}"
        queue_mount "${x}" "--bind" "${base}"
        if [ -e "${x}/.repo/alternates" ]; then
          queue_mount "${FLAGS_trunk}/.repo/chroot/empty" "--bind" \
            "${base}/.repo/alternates"
        fi
        position=$(( ${position} + 1 ))
      done
      unset required position base
    fi
    unset REFERENCE_DIR

    debug "Setting up shared distfiles directory."
    mkdir -p "${FLAGS_distfiles}"/{target,host}
    sudo mkdir -p "${FLAGS_chroot}/var/cache/distfiles/"
    queue_mount "${FLAGS_distfiles}" "--bind" "/var/cache/distfiles"

    if [ $FLAGS_ssh_agent -eq $FLAGS_TRUE ]; then
      if [ -n "${SSH_AUTH_SOCK}" -a -d "${HOME}/.ssh" ]; then
        TARGET_DIR="${FLAGS_chroot}/home/${USER}/.ssh"
        mkdir -p "${TARGET_DIR}"
        # Ignore errors as some people won't have these files to copy.
        cp "${HOME}"/.ssh/{known_hosts,*.pub} "${TARGET_DIR}/" 2>/dev/null || :
        copy_ssh_config "${TARGET_DIR}"

        # Don't try to bind mount the ssh agent dir if it has gone stale.
        ASOCK=${SSH_AUTH_SOCK%/*}
        if [ -d "${ASOCK}" ]; then
          queue_mount "${ASOCK}" "--bind" "${ASOCK}"
        fi
      fi
    fi

    if [ -d "$HOME/.subversion" ]; then
      TARGET="/home/${USER}/.subversion"
      mkdir -p "${FLAGS_chroot}${TARGET}"
      queue_mount "${HOME}/.subversion" "--bind" "${TARGET}"
    fi

    if DEPOT_TOOLS=$(type -P gclient) ; then
      DEPOT_TOOLS=${DEPOT_TOOLS%/*} # dirname
      debug "Mounting depot_tools"
      queue_mount "$DEPOT_TOOLS" --bind "$INNER_DEPOT_TOOLS_ROOT"
    fi

    process_mounts

    CHROME_ROOT="$(readlink -f "$FLAGS_chrome_root" || :)"
    if [ -z "$CHROME_ROOT" ]; then
      CHROME_ROOT="$(cat "${FLAGS_chroot}${CHROME_ROOT_CONFIG}" \
        2>/dev/null || :)"
      CHROME_ROOT_AUTO=1
    fi
    if [[ -n "$CHROME_ROOT" ]]; then
      if [[ ! -d "${CHROME_ROOT}/src" ]]; then
        error "Not mounting chrome source"
        sudo rm -f "${FLAGS_chroot}${CHROME_ROOT_CONFIG}"
        if [[ ! "$CHROME_ROOT_AUTO" ]]; then
          exit 1
        fi
      else
        debug "Mounting chrome source at: $INNER_CHROME_ROOT"
        sudo bash -c "echo '$CHROME_ROOT' > \
          '${FLAGS_chroot}${CHROME_ROOT_CONFIG}'"
        queue_mount "$CHROME_ROOT" --bind "$INNER_CHROME_ROOT"
      fi
    fi

    process_mounts

    # Install fuse module.  Skip modprobe when possible for slight
    # speed increase when initializing the env.
    if [ -c "${FUSE_DEVICE}" ] && ! grep -q fuse /proc/filesystems; then
      sudo modprobe fuse 2> /dev/null ||\
        warn "-- Note: modprobe fuse failed.  gmergefs will not work"
    fi

    # Fix permissions on ccache tree.  If this is a fresh chroot, then they
    # might not be set up yet.  Or if the user manually `rm -rf`-ed things,
    # we need to reset it.  Otherwise, gcc itself takes care of fixing things
    # on demand, but only when it updates.
    ccache_dir="${FLAGS_chroot}/var/cache/distfiles/ccache"
    if [[ ! -d ${ccache_dir} ]]; then
      sudo mkdir -p -m 2775 "${ccache_dir}"
    fi
    sudo find -H "${ccache_dir}" -type d -exec chmod 2775 {} + &
    sudo find -H "${ccache_dir}" -gid 0 -exec chgrp 250 {} + &

    # Configure committer username and email in chroot .gitconfig.  Change
    # to the root directory first so that random $PWD/.git/config settings
    # do not get picked up.  We want to stick to ~/.gitconfig only.
    ident=$(cd /; git var GIT_COMMITTER_IDENT || :)
    ident_name=${ident%% <*}
    ident_email=${ident%%>*}; ident_email=${ident_email##*<}
    git config -f ${FLAGS_chroot}/home/${USER}/.gitconfig --replace-all \
      user.name "${ident_name}" || true
    git config -f ${FLAGS_chroot}/home/${USER}/.gitconfig --replace-all \
      user.email "${ident_email}" || true

    # Certain files get copied into the chroot when entering.
    for fn in "${FILES_TO_COPY_TO_CHROOT[@]}"; do
      copy_into_chroot_if_exists "${HOME}/${fn}" "/home/${USER}/${fn}"
    done

    # Make sure user's requested locales are available
    # http://crosbug.com/19139
    # And make sure en_US{,.UTF-8} are always available as
    # that what buildbot forces internally
    locales=$(printf '%s\n' en_US en_US.UTF-8 ${LANG} \
      $LC_{ADDRESS,ALL,COLLATE,CTYPE,IDENTIFICATION,MEASUREMENT,MESSAGES} \
      $LC_{MONETARY,NAME,NUMERIC,PAPER,TELEPHONE,TIME} | \
      sort -u | sed '/^C$/d')
    gen_locales=()
    for l in ${locales}; do
      if [[ ${l} == *.* ]]; then
        enc=${l#*.}
      else
        enc="ISO-8859-1"
      fi
      case $(echo ${enc//-} | tr '[:upper:]' '[:lower:]') in
        utf8) enc="UTF-8";;
      esac
      gen_locales=("${gen_locales[@]}" "${l} ${enc}")
    done
    if [[ ${#gen_locales[@]} -gt 0 ]] ; then
      # Force LC_ALL=C to workaround slow string parsing in bash
      # with long multibyte strings.  Newer setups have this fixed,
      # but locale-gen doesn't need to be run in any locale in the
      # first place, so just go with C to keep it fast.
      sudo -- chroot "$FLAGS_chroot" env LC_ALL=C locale-gen -q -u \
        -G "$(printf '%s\n' "${gen_locales[@]}")"
    fi

    # Fix permissions on shared memory to allow non-root users access to POSIX
    # semaphores.  Avoid the sudo call if possible (sudo is slow).
    if [ -n "$(find "${FLAGS_chroot}/dev/shm" ! -perm 777)" ] ; then
      sudo chmod -R 777 "${FLAGS_chroot}/dev/shm"
    fi

    # If the private overlays are installed, gsutil can use those credentials.
    if [ ! -e "${FLAGS_chroot}/home/${USER}/.boto" ]; then
      boto='src/private-overlays/chromeos-overlay/googlestorage_account.boto'
      if [ -s "${FLAGS_trunk}/${boto}" ]; then
        ln -s "trunk/${boto}" "${FLAGS_chroot}/home/${USER}/.boto"
      fi
    fi

    # Have found a few chroots where ~/.gsutil is owned by root:root, probably
    # as a result of old gsutil or tools. This causes permission errors when
    # gsutil cp tries to create its cache files, so ensure the user can
    # actually write to their directory.
    gsutil_dir="${FLAGS_chroot}/home/${USER}/.gsutil"
    if [ -d "${gsutil_dir}" ] && [ ! -w "${gsutil_dir}" ]; then
      sudo chown -R "${USER}:$(id -gn)" "${gsutil_dir}"
    fi
  ) 200>>"$LOCKFILE" || die "setup_env failed"
}

teardown_env() {
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
    sort -u -n "$TMP_LOCKFILE" > "$LOCKFILE"

    if [ -s "$LOCKFILE" ]; then
      debug "At least one other pid is running in the chroot, so not"
      debug "tearing down env."
    else
      debug "Stopping syncer process"
      # If another process entering the chroot is blocked on this
      # flock in setup_env(), it can be a race condition.
      #
      # When this locked region is exited, the setup_env() flock can
      # be entered before the script can exit and the /proc entry for
      # the PID is removed.  The newly-created chroot will not end up
      # with a syncer process.  To avoid that situation, remove the
      # syncer PID file.
      #
      # The syncer PID file should also be removed because the kernel
      # will reuse PIDs.  It's possible that the PID in the syncer PID
      # has been reused by another process; make sure we don't skip
      # starting the syncer process when this occurs by deleting the
      # PID file.
      kill $(<"${SYNCERPIDFILE}") && \
        { rm -f "${SYNCERPIDFILE}" 2>/dev/null || \
          sudo rm -f "${SYNCERPIDFILE}" ; } ||
        debug "Unable to clean up syncer process.";

      debug "Unmounting chroot environment."
      safe_umount_tree "${MOUNTED_PATH}/"

      # Now that we've exited the chroot, allow automounting again.
      sudo killall -CONT -r '^gvfs-gdu-volume.*$|^gvfsd-trash$' 2>/dev/null \
        || true
    fi
  ) 200>>"$LOCKFILE" || die "teardown_env failed"
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

# Make sure we unmount before exiting
trap teardown_env EXIT
setup_env

CHROOT_PASSTHRU=(
  "BUILDBOT_BUILD=$FLAGS_build_number"
  "CHROMEOS_OFFICIAL=$CHROMEOS_OFFICIAL"
  "CHROMEOS_RELEASE_APPID=${CHROMEOS_RELEASE_APPID:-{DEV-BUILD}}"

  # Set CHROMEOS_VERSION_TRACK, CHROMEOS_VERSION_AUSERVER,
  # CHROMEOS_VERSION_DEVSERVER as environment variables to override the default
  # assumptions (local AU server). These are used in cros_set_lsb_release, and
  # are used by external Chromium OS builders.

  "CHROMEOS_VERSION_TRACK=${CHROMEOS_VERSION_TRACK}"
  "CHROMEOS_VERSION_AUSERVER=${CHROMEOS_VERSION_AUSERVER}"
  "CHROMEOS_VERSION_DEVSERVER=${CHROMEOS_VERSION_DEVSERVER}"
  "EXTERNAL_TRUNK_PATH=${FLAGS_trunk}"
  "SSH_AGENT_PID=${SSH_AGENT_PID}"
  "SSH_AUTH_SOCK=${SSH_AUTH_SOCK}"
)

# Pass proxy variables into the environment.
for type in http_proxy ftp_proxy all_proxy GIT_PROXY_COMMAND GIT_SSH; do
  if [ -n "${!type}" ]; then
    CHROOT_PASSTHRU+=( "${type}=${!type}" )
  fi
done

# Run command or interactive shell.  Also include the non-chrooted path to
# the source trunk for scripts that may need to print it (e.g.
# build_image.sh).

if [ $FLAGS_early_make_chroot -eq $FLAGS_TRUE ]; then
  cmd=( /bin/bash -l -c 'env "$@"' -- )
elif [ ! -x "${FLAGS_chroot}/usr/bin/sudo" ]; then
  # Complain that sudo is missing.
  error "Failing since the chroot lacks sudo."
  error "Requested enter_chroot command was: $@"
  exit 127
else
  cmd=( sudo -i -u "$USER" )
fi

sudo -- chroot "${FLAGS_chroot}" "${cmd[@]}" "${CHROOT_PASSTHRU[@]}" "$@"

# Remove trap and explicitly unmount
trap - EXIT
teardown_env
