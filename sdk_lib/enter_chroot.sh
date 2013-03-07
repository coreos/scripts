#!/bin/bash

# Copyright (c) 2011 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Script to enter the chroot environment

SCRIPT_ROOT=$(readlink -f $(dirname "$0")/..)
. "${SCRIPT_ROOT}/common.sh" || exit 1

# Script must be run outside the chroot and as root.
assert_outside_chroot
assert_root_user

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
DEFINE_string chrome_root_mount "/home/${SUDO_USER}/chrome_root" \
  "The mount point of the chrome broswer source in the chroot."
DEFINE_string cache_dir "" "Directory to use for caching."

DEFINE_boolean official_build $FLAGS_FALSE \
  "Set COREOS_OFFICIAL=1 for release builds."
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
after changing directory to /${SUDO_USER}/trunk/src/scripts.  Note that neither
the command nor args should include single quotes.  For example:

    $0 -- ./build_platform_packages.sh

Otherwise, provides an interactive shell.
"

CROS_LOG_PREFIX=cros_sdk:enter_chroot
SUDO_HOME=$(eval echo ~${SUDO_USER})

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
   COREOS_OFFICIAL=1
fi

[ -z "${FLAGS_cache_dir}" ] && \
  die "--cache_dir is required"

# Only now can we die on error.  shflags functions leak non-zero error codes,
# so will die prematurely if 'switch_to_strict_mode' is specified before now.
# TODO: replace shflags with something less error-prone, or contribute a fix.
switch_to_strict_mode

# These config files are to be copied into chroot if they exist in home dir.
FILES_TO_COPY_TO_CHROOT=(
  .gdata_cred.txt             # User/password for Google Docs on chromium.org
  .gdata_token                # Auth token for Google Docs on chromium.org
  .disable_build_stats_upload # Presence of file disables command stats upload
  .netrc                      # May contain required source fetching credentials
  .boto                       # Auth information for gsutil
  .boto-key.p12               # Service account key for gsutil
)

INNER_CHROME_ROOT=$FLAGS_chrome_root_mount  # inside chroot
CHROME_ROOT_CONFIG="/var/cache/chrome_root"  # inside chroot
FUSE_DEVICE="/dev/fuse"

chmod 0777 "$FLAGS_chroot/var/lock"

LOCKFILE="$FLAGS_chroot/var/lock/enter_chroot"
MOUNTED_PATH=$(readlink -f "$FLAGS_chroot")

# Reset the depot tools/internal trunk pathways to what they'll
# be w/in the chroot.
set_chroot_trunk_dir "${FLAGS_chroot}"


setup_mount() {
  # If necessary, mount $source in the host FS at $target inside the
  # chroot directory with $mount_args. We don't write to /etc/mtab because
  # these mounts are all contained within an unshare and are therefore
  # inaccessible to other namespaces (e.g. the host desktop system).
  local source="$1"
  local mount_args="-n $2"
  local target="$3"

  local mounted_path="${MOUNTED_PATH}$target"

  case " ${MOUNT_CACHE} " in
  *" ${mounted_path} "*)
    # Already mounted!
    ;;
  *)
    mkdir -p "${mounted_path}"
    # The args are left unquoted on purpose.
    if [[ -n ${source} ]]; then
      mount ${mount_args} "${source}" "${mounted_path}"
    else
      mount ${mount_args} "${mounted_path}"
    fi
    ;;
  esac
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
  local sshc="${SUDO_HOME}/.ssh/config"
  local chroot_ssh_dir="${1}"
  local filter
  local option

  if ! user_cp "${sshc}" "${chroot_ssh_dir}/config.orig" 2>/dev/null; then
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

  sed "/^.*\(${filter}\).*$/d" "${chroot_ssh_dir}/config.orig" | \
    user_clobber "${chroot_ssh_dir}/config"
}

copy_into_chroot_if_exists() {
  # $1 is file path outside of chroot to copy to path $2 inside chroot.
  [ -e "$1" ] && cp -p "$1" "${FLAGS_chroot}/$2"
}

# Usage: promote_api_keys
# This takes care of getting the developer API keys into the chroot where
# chrome can build with them.  It needs to take it from the places a dev
# is likely to put them, and recognize that older chroots may or may not
# have been used since the concept of keys got added, as well as before
# and after the developer decding to grab his own keys.
promote_api_keys() {
  local destination="${FLAGS_chroot}/home/${SUDO_USER}/.googleapikeys"
  # Don't disturb existing keys.  They could be set differently
  if [[ -s "${destination}" ]]; then
    return 0
  fi
  if [[ -r "${SUDO_HOME}/.googleapikeys" ]]; then
    cp -p "${SUDO_HOME}/.googleapikeys" "${destination}"
    if [[ -s "${destination}" ]] ; then
      info "Copied Google API keys into chroot."
    fi
  elif [[ -r "${SUDO_HOME}/.gyp/include.gypi" ]]; then
    local NAME="('google_(api_key|default_client_(id|secret))')"
    local WS="[[:space:]]*"
    local CONTENTS="('[^\\\\']*')"
    sed -nr -e "/^${WS}${NAME}${WS}[:=]${WS}${CONTENTS}.*/{s//\1: \4,/;p;}" \
         "${SUDO_HOME}/.gyp/include.gypi" | user_clobber "${destination}"
    if [[ -s "${destination}" ]]; then
      info "Put discovered Google API keys into chroot."
    fi
  fi
}

setup_env() {
  (
    flock 200

    # Make the lockfile writable for backwards compatibility.
    chown ${SUDO_UID}:${SUDO_GID} "${LOCKFILE}"

    # Refresh /etc/resolv.conf and /etc/hosts in the chroot.
    install -C -m644 /etc/resolv.conf ${FLAGS_chroot}/etc/resolv.conf
    install -C -m644 /etc/hosts ${FLAGS_chroot}/etc/hosts

    debug "Mounting chroot environment."
    MOUNT_CACHE=$(echo $(awk '{print $2}' /proc/mounts))
    setup_mount none "-t proc" /proc
    setup_mount none "-t sysfs" /sys
    setup_mount /dev "--bind" /dev
    setup_mount none "-t devpts" /dev/pts
    if [ -d /run ]; then
      setup_mount /run "--bind" /run
      if [ -d /run/shm ]; then
        setup_mount /run/shm "--bind" /run/shm
      fi
    fi

    setup_mount "${FLAGS_trunk}" "--bind" "${CHROOT_TRUNK_DIR}"

    debug "Setting up referenced repositories if required."
    REFERENCE_DIR=$(git config --file  \
      "${FLAGS_trunk}/.repo/manifests.git/config" \
      repo.reference)
    if [ -n "${REFERENCE_DIR}" ]; then

      ALTERNATES="${FLAGS_trunk}/.repo/alternates"

      # Ensure this directory exists ourselves, and has the correct ownership.
      user_mkdir "${ALTERNATES}"

      unset ALTERNATES

      IFS=$'\n';
      required=( $( sudo -u "${SUDO_USER}" -- \
        "${FLAGS_trunk}/chromite/lib/rewrite_git_alternates.py" \
        "${FLAGS_trunk}" "${REFERENCE_DIR}" "${CHROOT_TRUNK_DIR}" ) )
      unset IFS

      setup_mount "${FLAGS_trunk}/.repo/chroot/alternates" --bind \
        "${CHROOT_TRUNK_DIR}/.repo/alternates"

      # Note that as we're bringing up each referened repo, we also
      # mount bind an empty directory over its alternates.  This is
      # required to suppress git from tracing through it- we already
      # specify the required alternates for CHROOT_TRUNK_DIR, no point
      # in having git try recursing through each on their own.
      #
      # Finally note that if you're unfamiliar w/ chroot/vfs semantics,
      # the bind is visible only w/in the chroot.
      user_mkdir ${FLAGS_trunk}/.repo/chroot/empty
      position=1
      for x in "${required[@]}"; do
        base="${CHROOT_TRUNK_DIR}/.repo/chroot/external${position}"
        setup_mount "${x}" "--bind" "${base}"
        if [ -e "${x}/.repo/alternates" ]; then
          setup_mount "${FLAGS_trunk}/.repo/chroot/empty" "--bind" \
            "${base}/.repo/alternates"
        fi
        position=$(( ${position} + 1 ))
      done
      unset required position base
    fi
    unset REFERENCE_DIR

    chroot_cache='/var/cache/chromeos-cache'
    debug "Setting up shared cache dir directory."
    user_mkdir "${FLAGS_cache_dir}"/distfiles/{target,host}
    user_mkdir "${FLAGS_chroot}/${chroot_cache}"
    setup_mount "${FLAGS_cache_dir}" "--bind" "${chroot_cache}"
    # TODO(build): remove this as of 12/01/12.
    # Because of how distfiles -> cache_dir was deployed, if this isn't
    # a symlink, we *know* the ondisk pathways aren't compatible- thus
    # fix it now.
    distfiles_path="${FLAGS_chroot}/var/cache/distfiles"
    if [ ! -L "${distfiles_path}" ]; then
      # While we're at it, ensure the var is exported w/in the chroot; it
      # won't exist if distfiles isn't a symlink.
      p="${FLAGS_chroot}/etc/profile.d/chromeos-cachedir.sh"
      rm -rf "${distfiles_path}"
      ln -s chromeos-cache/distfiles "${distfiles_path}"
      mkdir -p -m 775 "${p%/*}"
      echo 'export CHROMEOS_CACHEDIR=${chroot_cache}' > "${p}"
      chmod 0644 "${p}"
    fi

    if [ $FLAGS_ssh_agent -eq $FLAGS_TRUE ]; then
      # Clean up previous ssh agents.
      rmdir "${FLAGS_chroot}"/tmp/ssh-* 2>/dev/null

      if [ -n "${SSH_AUTH_SOCK}" -a -d "${SUDO_HOME}/.ssh" ]; then
        TARGET_DIR="${FLAGS_chroot}/home/${SUDO_USER}/.ssh"
        user_mkdir "${TARGET_DIR}"
        (
          # Only copy ~/.ssh/{known_hosts,*.pub} if they exist. Since we set
          # nullglob, this needs to happen within a subshell.
          shopt -s nullglob
          files=("${SUDO_HOME}"/.ssh/{known_hosts,*.pub})
          if [[ ${#files[@]} -gt 0 ]]; then
            user_cp "${files[@]}" "${TARGET_DIR}/"
          fi
        )
        copy_ssh_config "${TARGET_DIR}"
        chown -R ${SUDO_UID}:${SUDO_GID} "${TARGET_DIR}"

        # Don't try to bind mount the ssh agent dir if it has gone stale.
        ASOCK=${SSH_AUTH_SOCK%/*}
        if [ -d "${ASOCK}" ]; then
          setup_mount "${ASOCK}" "--bind" "${ASOCK}"
        fi
      fi
    fi

    if [[ -d "$SUDO_HOME/.subversion" ]]; then
      TARGET="/home/${SUDO_USER}/.subversion"
      setup_mount "${SUDO_HOME}/.subversion" "--bind" "${TARGET}"
      # Symbolic-link the .subversion directory so sandboxed subversion.class
      # clients can use it.
      for d in \
        "${FLAGS_cache_dir}"/distfiles/{host,target}/svn-src/"${SUDO_USER}"; do
        if [[ ! -L "${d}/.subversion" ]]; then
          rm -rf "${d}/.subversion"
          user_mkdir "${d}"
          user_symlink /home/${SUDO_USER}/.subversion "${d}/.subversion"
        fi
      done
    fi

    # A reference to the DEPOT_TOOLS path may be passed in by cros_sdk.
    if [ -n "${DEPOT_TOOLS}" ]; then
      debug "Mounting depot_tools"
      setup_mount "${DEPOT_TOOLS}" --bind "${DEPOT_TOOLS_DIR}"
    fi

    # Mount additional directories as specified in .local_mounts file.
    local local_mounts="${FLAGS_trunk}/src/scripts/.local_mounts"
    if [[ -f ${local_mounts} ]]; then
      info "Mounting local folders (read-only for safety concern)"
      # format: mount_source
      #      or mount_source mount_point
      #      or # comments
      local mount_source mount_point
      while read mount_source mount_point; do
        if [[ -z ${mount_source} ]]; then
          continue
        fi
        # if only source is assigned, use source as mount point.
        : ${mount_point:=${mount_source}}
        debug "  mounting ${mount_source} on ${mount_point}"
        setup_mount "${mount_source}" "--bind" "${mount_point}"
        # --bind can't initially be read-only so we have to do it via remount.
        setup_mount "" "-o remount,ro" "${mount_point}"
      done < <(sed -e 's:#.*::' "${local_mounts}")
    fi

    CHROME_ROOT="$(readlink -f "$FLAGS_chrome_root" || :)"
    if [ -z "$CHROME_ROOT" ]; then
      CHROME_ROOT="$(cat "${FLAGS_chroot}${CHROME_ROOT_CONFIG}" \
        2>/dev/null || :)"
      CHROME_ROOT_AUTO=1
    fi
    if [[ -n "$CHROME_ROOT" ]]; then
      if [[ ! -d "${CHROME_ROOT}/src" ]]; then
        error "Not mounting chrome source"
        rm -f "${FLAGS_chroot}${CHROME_ROOT_CONFIG}"
        if [[ ! "$CHROME_ROOT_AUTO" ]]; then
          exit 1
        fi
      else
        debug "Mounting chrome source at: $INNER_CHROME_ROOT"
        echo $CHROME_ROOT > "${FLAGS_chroot}${CHROME_ROOT_CONFIG}"
        setup_mount "$CHROME_ROOT" --bind "$INNER_CHROME_ROOT"
      fi
    fi

    # Install fuse module.  Skip modprobe when possible for slight
    # speed increase when initializing the env.
    if [ -c "${FUSE_DEVICE}" ] && ! grep -q fuse /proc/filesystems; then
      modprobe fuse 2> /dev/null ||\
        warn "-- Note: modprobe fuse failed.  gmergefs will not work"
    fi

    # Fix permissions on ccache tree.  If this is a fresh chroot, then they
    # might not be set up yet.  Or if the user manually `rm -rf`-ed things,
    # we need to reset it.  Otherwise, gcc itself takes care of fixing things
    # on demand, but only when it updates.
    ccache_dir="${FLAGS_chroot}/var/cache/distfiles/ccache"
    if [[ ! -d ${ccache_dir} ]]; then
      mkdir -p -m 2775 "${ccache_dir}"
    fi
    find -H "${ccache_dir}" -type d -exec chmod 2775 {} + &
    find -H "${ccache_dir}" -gid 0 -exec chgrp 250 {} + &

    # Certain files get copied into the chroot when entering.
    for fn in "${FILES_TO_COPY_TO_CHROOT[@]}"; do
      copy_into_chroot_if_exists "${SUDO_HOME}/${fn}" "/home/${SUDO_USER}/${fn}"
    done
    promote_api_keys

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
      chroot "$FLAGS_chroot" env LC_ALL=C locale-gen -q -u \
        -G "$(printf '%s\n' "${gen_locales[@]}")"
    fi

    # Fix permissions on shared memory to allow non-root users access to POSIX
    # semaphores.
    chmod -R 777 "${FLAGS_chroot}/dev/shm"

    # Have found a few chroots where ~/.gsutil is owned by root:root, probably
    # as a result of old gsutil or tools. This causes permission errors when
    # gsutil cp tries to create its cache files, so ensure the user can
    # actually write to their directory.
    gsutil_dir="${FLAGS_chroot}/home/${SUDO_USER}/.gsutil"
    if [ -d "${gsutil_dir}" ]; then
      chown -R ${SUDO_UID}:${SUDO_GID} "${gsutil_dir}"
    fi
  ) 200>>"$LOCKFILE" || die "setup_env failed"
}

setup_env

CHROOT_PASSTHRU=(
  "BUILDBOT_BUILD=$FLAGS_build_number"
  "CHROMEOS_RELEASE_APPID=${CHROMEOS_RELEASE_APPID:-{DEV-BUILD}}"
  "EXTERNAL_TRUNK_PATH=${FLAGS_trunk}"
)

# Add the whitelisted environment variables to CHROOT_PASSTHRU.
load_environment_whitelist
for var in "${ENVIRONMENT_WHITELIST[@]}" ; do
  [ "${!var+set}" = "set" ] && CHROOT_PASSTHRU+=( "${var}=${!var}" )
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
  cmd=( sudo -i -u "${SUDO_USER}" )
fi

cmd+=( "${CHROOT_PASSTHRU[@]}" "$@" )
exec chroot "${FLAGS_chroot}" "${cmd[@]}"
