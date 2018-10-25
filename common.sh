#!/bin/bash
# Copyright (c) 2012 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# All scripts should die on error unless commands are specifically excepted
# by prefixing with '!' or surrounded by 'set +e' / 'set -e'.

# The number of jobs to pass to tools that can run in parallel (such as make
# and dpkg-buildpackage
if [[ -z ${NUM_JOBS} ]]; then
  NUM_JOBS=$(grep -c "^processor" /proc/cpuinfo)
fi
# Ensure that any sub scripts we invoke get the max proc count.
export NUM_JOBS

# Make sure we have the location and name of the calling script, using
# the current value if it is already set.
: ${SCRIPT_LOCATION:=$(dirname "$(readlink -f "$0")")}
: ${SCRIPT_NAME:=$(basename "$0")}

# Detect whether we're inside a chroot or not
if [[ -e /etc/debian_chroot ]]; then
  INSIDE_CHROOT=1
else
  INSIDE_CHROOT=0
fi

# Determine and set up variables needed for fancy color output (if supported).
V_BOLD_RED=
V_BOLD_GREEN=
V_BOLD_YELLOW=
V_REVERSE=
V_VIDOFF=

if tput colors >&/dev/null; then
  # order matters: we want VIDOFF last so that when we trace with `set -x`,
  # our terminal doesn't bleed colors as bash dumps the values of vars.
  V_BOLD_RED=$(tput bold; tput setaf 1)
  V_BOLD_GREEN=$(tput bold; tput setaf 2)
  V_BOLD_YELLOW=$(tput bold; tput setaf 3)
  V_REVERSE=$(tput rev)
  V_VIDOFF=$(tput sgr0)
fi

# Turn on bash debug support if available for backtraces.
shopt -s extdebug 2>/dev/null

# Output a backtrace all the way back to the raw invocation, suppressing
# only the _dump_trace frame itself.
_dump_trace() {
  local j n p func src line args
  p=${#BASH_ARGV[@]}
  for (( n = ${#FUNCNAME[@]}; n > 1; --n )); do
    func=${FUNCNAME[${n} - 1]}
    src=${BASH_SOURCE[${n}]##*/}
    line=${BASH_LINENO[${n} - 1]}
    args=
    if [[ -z ${BASH_ARGC[${n} -1]} ]]; then
      args='(args unknown, no debug available)'
    else
      for (( j = 0; j < ${BASH_ARGC[${n} -1]}; ++j )); do
        args="${args:+${args} }'${BASH_ARGV[$(( p - j - 1 ))]}'"
      done
      ! (( p -= ${BASH_ARGC[${n} - 1]} ))
    fi
    if [[ ${n} == ${#FUNCNAME[@]} ]]; then
      error "script called: ${0##*/} ${args}"
      error "Backtrace:  (most recent call is last)"
    else
      error "$(printf '  file %s, line %s, called: %s %s' \
               "${src}" "${line}" "${func}" "${args}")"
    fi
  done
}

# Declare these asap so that code below can safely assume they exist.
_message() {
  local prefix="$1${CROS_LOG_PREFIX:-${SCRIPT_NAME}}"
  shift
  if [[ $# -eq 0 ]]; then
    echo -e "${prefix}:${V_VIDOFF}" >&2
    return
  fi
  (
    # Handle newlines in the message, prefixing each chunk correctly.
    # Do this in a subshell to avoid having to track IFS/set -f state.
    IFS="
"
    set +f
    set -- $*
    IFS=' '
    if [[ $# -eq 0 ]]; then
      # Empty line was requested.
      set -- ''
    fi
    for line in "$@"; do
      echo -e "${prefix}: ${line}${V_VIDOFF}" >&2
    done
  )
}

info() {
  _message "${V_BOLD_GREEN}INFO    " "$*"
}

warn() {
  _message "${V_BOLD_YELLOW}WARNING " "$*"
}

error() {
  _message "${V_BOLD_RED}ERROR   " "$*"
}


# For all die functions, they must explicitly force set +eu;
# no reason to have them cause their own crash if we're inthe middle
# of reporting an error condition then exiting.
die_err_trap() {
  local command=$1 result=$2
  set +e +u

  # Per the message, bash misreports 127 as 1 during err trap sometimes.
  # Note this fact to ensure users don't place too much faith in the
  # exit code in that case.
  set -- "Command '${command}' exited with nonzero code: ${result}"
  if [[ ${result} -eq 1 ]] && [[ -z $(type -t ${command}) ]]; then
    set -- "$@" \
       '(Note bash sometimes misreports "command not found" as exit code 1 '\
'instead of 127)'
  fi
  _dump_trace
  error
  error "Command failed:"
  DIE_PREFIX='  '
  die_notrace "$@"
}

# Exit this script due to a failure, outputting a backtrace in the process.
die() {
  set +e +u
  _dump_trace
  error
  error "Error was:"
  DIE_PREFIX='  '
  die_notrace "$@"
}

# Exit this script w/out a backtrace.
die_notrace() {
  set +e +u
  if [[ $# -eq 0 ]]; then
    set -- '(no error message given)'
  fi
  local line
  for line in "$@"; do
    error "${DIE_PREFIX}${line}"
  done
  exit 1
}

# Simple version comparison routine
# Note: not a true semver comparison and build revisions are ignored
cmp_ver() {
  local rev a="${2%%+*}" b="${3%%+*}"
  case "$1" in
    le) rev="" ;;
    ge) rev="--reverse" ;;
    *) die "Invalid operator $1" ;;
  esac
  printf '%s\n%s\n' "$a" "$b" | sort --version-sort --check=quiet $rev
  return $?
}

# Split a semver into a 3 item array (major minor patch)
# Usage: split_ver 1.2.3 NAME
split_ver() {
  local v="$1" n="$2"
  v="${v%%-*}" # strip off pre-release suffix
  v="${v%%+*}" # strip off build id suffix
  v="${v//./ }"
  local -a a="(${v})"
  if [[ ${#a[@]} -ne 3 ]]; then
    die "Invalid version string '$1'"
  fi
  declare -g -a ${n}="(${v})"
}

# repo source root inside the chroot, usually mounted from the outside.
CHROOT_TRUNK_DIR="/mnt/host/source"

# Construct a list of possible locations for the source tree.  This list is
# based on various environment variables and globals that may have been set
# by the calling script.
get_gclient_root_list() {
  if [[ ${INSIDE_CHROOT} -eq 1 ]]; then
    echo "${CHROOT_TRUNK_DIR}"
  fi

  if [[ -n ${COMMON_SH} ]]; then echo "$(dirname "${COMMON_SH}")/../.."; fi
  if [[ -n ${BASH_SOURCE} ]]; then echo "$(dirname "${BASH_SOURCE}")/../.."; fi
}

# Based on the list of possible source locations we set GCLIENT_ROOT if it is
# not already defined by looking for a src directory in each seach path
# location.  If we do not find a valid looking root we error out.
get_gclient_root() {
  if [[ -n ${GCLIENT_ROOT} ]]; then
    return
  fi

  for path in $(get_gclient_root_list); do
    if [[ -d ${path}/src ]]; then
      GCLIENT_ROOT=${path}
      break
    fi
  done

  if [[ -z ${GCLIENT_ROOT} ]]; then
    # Using dash or sh, we don't know where we are.  $0 refers to the calling
    # script, not ourselves, so that doesn't help us.
    echo "Unable to determine location for common.sh.  If you are sourcing"
    echo "common.sh from a script run via dash or sh, you must do it in the"
    echo "following way:"
    echo '  COMMON_SH="$(dirname "$0")/../../scripts/common.sh"'
    echo '  . "${COMMON_SH}"'
    echo "where the first line is the relative path from your script to"
    echo "common.sh."
    exit 1
  fi
}

# Populate the ENVIRONMENT_WHITELIST array.
load_environment_whitelist() {
  ENVIRONMENT_WHITELIST=(
    COREOS_BUILD_ID
    COREOS_OFFICIAL
    GIT_AUTHOR_EMAIL
    GIT_AUTHOR_NAME
    GIT_COMMITTER_EMAIL
    GIT_COMMITTER_NAME
    GIT_PROXY_COMMAND
    GIT_SSH
    RSYNC_PROXY
    GNUPGHOME
    GPG_AGENT_INFO
    SSH_AGENT_PID
    SSH_AUTH_SOCK
    USE
    all_proxy
    ftp_proxy
    http_proxy
    https_proxy
    no_proxy
  )
}

load_environment_var() {
  local file="$1" name value
  shift
  for name in "$@"; do
    value=$(grep "^${name}=" "${file}" | sed 's|"||g')
    export "${value}"
  done
}

# Find root of source tree
get_gclient_root

# Canonicalize the directories for the root dir and the calling script.
# readlink is part of coreutils and should be present even in a bare chroot.
# This is better than just using
#     FOO="$(cd ${FOO} ; pwd)"
# since that leaves symbolic links intact.
# Note that 'realpath' is equivalent to 'readlink -f'.
SCRIPT_LOCATION=$(readlink -f "${SCRIPT_LOCATION}")
GCLIENT_ROOT=$(readlink -f "${GCLIENT_ROOT}")
# TODO(marineam): I'm tempted to deprecate GCLIENT_ROOT, this isn't Google
# and even if it was the source is managed by 'repo', not 'gclient'
REPO_ROOT="${GCLIENT_ROOT}"

# Other directories should always be pathed down from GCLIENT_ROOT.
SRC_ROOT="${GCLIENT_ROOT}/src"
SRC_INTERNAL="${GCLIENT_ROOT}/src-internal"
SCRIPTS_DIR="${SRC_ROOT}/scripts"
BUILD_LIBRARY_DIR="${SCRIPTS_DIR}/build_library"
REPO_CACHE_DIR="${REPO_ROOT}/.cache"
REPO_MANIFESTS_DIR="${REPO_ROOT}/.repo/manifests"

# Source COREOS_VERSION_ID from manifest.
if [[ -f "${REPO_MANIFESTS_DIR}/version.txt" ]]; then
  # The build id may be provided externally by the build system.
  if [[ -n ${COREOS_BUILD_ID} ]]; then
    load_environment_var "${REPO_MANIFESTS_DIR}/version.txt" \
    COREOS_VERSION_ID COREOS_SDK_VERSION
  else
    load_environment_var "${REPO_MANIFESTS_DIR}/version.txt" \
    COREOS_VERSION_ID COREOS_BUILD_ID COREOS_SDK_VERSION
    # Don't promote COREOS_BUILD_ID into an environment variable when it
    # didn't start as one, since we don't want it leaking into the SDK
    # chroot environment via ENVIRONMENT_WHITELIST.
    declare +x COREOS_BUILD_ID
  fi
  : ${COREOS_BUILD_ID:=$(date +%Y-%m-%d-%H%M)}
elif [[ -f "${SCRIPT_LOCATION}/version.txt" ]]; then
  # This only happens in update.zip where we must use the current build id.
  load_environment_var "${SCRIPT_LOCATION}/version.txt" \
      COREOS_VERSION_ID COREOS_BUILD_ID COREOS_SDK_VERSION
else
  die "Unable to locate version.txt"
fi

# Official builds must set COREOS_OFFICIAL=1 to use an official version.
# Unofficial builds always appended the build identifier.
if [[ ${COREOS_OFFICIAL:-0} -ne 1 && -n "${COREOS_BUILD_ID}" ]]; then
  COREOS_VERSION="${COREOS_VERSION_ID}+${COREOS_BUILD_ID}"
else
  COREOS_VERSION="${COREOS_VERSION_ID}"
fi

# Compatibility alias
COREOS_VERSION_STRING="${COREOS_VERSION}"

# Calculate what today's build version should be, used by release
# scripts to provide a reasonable default value. The value is the number
# of days since COREOS_EPOCH, Mon Jul  1 00:00:00 UTC 2013
readonly COREOS_EPOCH=1372636800
TODAYS_VERSION=$(( (`date +%s` - ${COREOS_EPOCH}) / 86400 ))

# Download URL prefix for SDK and board binary packages
: ${COREOS_DEV_BUILDS:=http://builds.developer.core-os.net}

# Load developer's custom settings.  Default location is in scripts dir,
# since that's available both inside and outside the chroot.  By convention,
# settings from this file are variables starting with 'CHROMEOS_'
: ${CHROMEOS_DEV_SETTINGS:=${SCRIPTS_DIR}/.chromeos_dev}
if [[ -f ${CHROMEOS_DEV_SETTINGS} ]]; then
  # Turn on exit-on-error during custom settings processing
  SAVE_OPTS=$(set +o)
  switch_to_strict_mode

  # Read settings
  . "${CHROMEOS_DEV_SETTINGS}"

  # Restore previous state of exit-on-error
  eval "${SAVE_OPTS}"
fi

# Load shflags
# NOTE: This code snippet is in particular used by the au-generator (which
# stores shflags in ./lib/shflags/) and should not be touched.
if [[ -f ${SCRIPTS_DIR}/lib/shflags/shflags ]]; then
  . "${SCRIPTS_DIR}/lib/shflags/shflags" || die "Couldn't find shflags"
else
  . ./lib/shflags/shflags || die "Couldn't find shflags"
fi

# Our local mirror
DEFAULT_CHROMEOS_SERVER=${CHROMEOS_SERVER:-"http://build.chromium.org/mirror"}

# Upstream mirrors and build suites come in 2 flavors
#   DEV - development chroot, used to build the chromeos image
#   IMG - bootable image, to run on actual hardware

DEFAULT_DEV_MIRROR=${CHROMEOS_DEV_MIRROR:-"${DEFAULT_CHROMEOS_SERVER}/ubuntu"}
DEFAULT_DEV_SUITE=${CHROMEOS_DEV_SUITE:-"karmic"}

DEFAULT_IMG_MIRROR=${CHROMEOS_IMG_MIRROR:-"${DEFAULT_CHROMEOS_SERVER}/ubuntu"}
DEFAULT_IMG_SUITE=${CHROMEOS_IMG_SUITE:-"karmic"}

# Default location for chroot
DEFAULT_CHROOT_DIR=${CHROMEOS_CHROOT_DIR:-"${GCLIENT_ROOT}/chroot"}

# All output files from build should go under ${DEFAULT_BUILD_ROOT}, so that
# they don't pollute the source directory.
DEFAULT_BUILD_ROOT=${CHROMEOS_BUILD_ROOT:-"${SRC_ROOT}/build"}

# Sets the default board variable for calling script.
if [[ -f ${GCLIENT_ROOT}/src/scripts/.default_board ]]; then
  DEFAULT_BOARD=$(<"${GCLIENT_ROOT}/src/scripts/.default_board")
  # Check for user typos like whitespace.
  if [[ -n ${DEFAULT_BOARD//[a-zA-Z0-9-_]} ]]; then
    die ".default_board: invalid name detected; please fix:" \
        "'${DEFAULT_BOARD}'"
  fi
elif [ -z "${DEFAULT_BOARD-}" ]; then
  DEFAULT_BOARD=amd64-usr
fi

# Directory to store built images.  Should be set by sourcing script when used.
BUILD_DIR=

# Standard filenames
COREOS_DEVELOPER_CONTAINER_NAME="coreos_developer_container.bin"
COREOS_PRODUCTION_IMAGE_NAME="coreos_production_image.bin"

# -----------------------------------------------------------------------------
# Functions

setup_board_warning() {
  echo
  echo "${V_REVERSE}================  WARNING  =====================${V_VIDOFF}"
  echo
  echo "*** No default board detected in " \
    "${GCLIENT_ROOT}/src/scripts/.default_board"
  echo "*** Either run setup_board with default flag set"
  echo "*** or echo |board_name| > ${GCLIENT_ROOT}/src/scripts/.default_board"
  echo
}

is_nfs() {
  [[ $(stat -f -L -c %T "$1") == "nfs" ]]
}

warn_if_nfs() {
  if is_nfs "$1"; then
    warn "$1 is on NFS. This is untested. You can send patches if it's broken."
  fi
}

# Fail unless we're inside the chroot.  This guards against messing up your
# workstation.
assert_inside_chroot() {
  if [[ ${INSIDE_CHROOT} -ne 1 ]]; then
    echo "This script must be run inside the chroot.  Run this first:"
    echo "    cros_sdk"
    exit 1
  fi
}

# Fail if we're inside the chroot.  This guards against creating or entering
# nested chroots, among other potential problems.
assert_outside_chroot() {
  if [[ ${INSIDE_CHROOT} -ne 0 ]]; then
    echo "This script must be run outside the chroot."
    exit 1
  fi
}

assert_not_root_user() {
  if [[ ${UID:-$(id -u)} == 0 ]]; then
    echo "This script must be run as a non-root user."
    exit 1
  fi
}

assert_root_user() {
  if [[ ${UID:-$(id -u)} != 0 ]] || [[ ${SUDO_USER:-root} == "root" ]]; then
    die_notrace "This script must be run using sudo from a non-root user."
  fi
}

# We depend on some relatively modern kernel features, in particular a
# reasonably recent btrfs version is required to generate images.
# Current requirement: 3.7 added btrfs' extref incompat feature
assert_kernel_version() {
  local req_kv="3.7"
  local cur_kv=$(uname -r)
  if ! cmp_ver ge "${cur_kv}" "${req_kv}"; then
    die_notrace "Detected kernel ${cur_kv}, ${req_kv} or later is required"
  fi
}

# Check that all arguments are flags; that is, there are no remaining arguments
# after parsing from shflags.  Allow (with a warning) a single empty-string
# argument.
#
# TODO: fix buildbot so that it doesn't pass the empty-string parameter,
# then change this function.
#
# Usage: check_flags_only_and_allow_null_arg "$@" && set --
check_flags_only_and_allow_null_arg() {
  local do_shift=1
  if [[ $# -eq 1 ]] && [[ -z $1 ]]; then
    echo "$0: warning: ignoring null argument" >&2
    shift
    do_shift=0
  fi
  if [[ $# -gt 0 ]]; then
    echo "error: invalid arguments: \"$*\"" >&2
    flags_help
    exit 1
  fi
  return ${do_shift}
}

# Removes single quotes around parameter
# Arguments:
#   $1 - string which optionally has surrounding quotes
# Returns:
#   None, but prints the string without quotes.
remove_quotes() {
  echo "$1" | sed -e "s/^'//; s/'$//"
}

# Writes stdin to the given file name as root using sudo in overwrite mode.
#
# $1 - The output file name.
sudo_clobber() {
  sudo tee "$1" >/dev/null
}

# Writes stdin to the given file name as root using sudo in append mode.
#
# $1 - The output file name.
sudo_append() {
  sudo tee -a "$1" >/dev/null
}

# Execute multiple commands in a single sudo. Generally will speed things
# up by avoiding multiple calls to `sudo`. If any commands fail, we will
# call die with the failing command. We can handle a max of ~100 commands,
# but hopefully no one will ever try that many at once.
#
# $@ - The commands to execute, one per arg.
sudo_multi() {
  local i cmds

  # Construct the shell code to execute. It'll be of the form:
  # ... && ( ( command ) || exit <command index> ) && ...
  # This way we know which command exited. The exit status of
  # the underlying command is lost, but we never cared about it
  # in the first place (other than it is non zero), so oh well.
  for (( i = 1; i <= $#; ++i )); do
    cmds+=" && ( ( ${!i} ) || exit $(( i + 10 )) )"
  done

  # Execute our constructed shell code.
  sudo -- sh -c ":${cmds[*]}" && i=0 || i=$?

  # See if this failed, and if so, print out the failing command.
  if [[ $i -gt 10 ]]; then
    : $(( i -= 10 ))
    die "sudo_multi failed: ${!i}"
  elif [[ $i -ne 0 ]]; then
    die "sudo_multi failed for unknown reason $i"
  fi
}

# Writes stdin to the given file name as the sudo user in overwrite mode.
#
# $@ - The output file names.
user_clobber() {
  install -m644 -o ${SUDO_UID} -g ${SUDO_GID} /dev/stdin "$@"
}

# Copies the specified file owned by the user to the specified location.
# If the copy fails as root (e.g. due to root_squash and NFS), retry the copy
# with the user's account before failing.
user_cp() {
  cp -p "$@" 2>/dev/null || sudo -u ${SUDO_USER} -- cp -p "$@"
}

# Appends stdin to the given file name as the sudo user.
#
# $1 - The output file name.
user_append() {
  cat >> "$1"
  chown ${SUDO_UID}:${SUDO_GID} "$1"
}

# Create the specified directory, along with parents, as the sudo user.
#
# $@ - The directories to create.
user_mkdir() {
  install -o ${SUDO_UID} -g ${SUDO_GID} -d "$@"
}

# Create the specified symlink as the sudo user.
#
# $1 - Link target
# $2 - Link name
user_symlink() {
  ln -sfT "$1" "$2"
  chown -h ${SUDO_UID}:${SUDO_GID} "$2"
}

# Locate all mounts below a specified directory.
#
# $1 - The root tree.
sub_mounts() {
  # Assume that `mount` outputs a list of mount points in the order
  # that things were mounted (since it always has and hopefully always
  # will).  As such, we have to unmount in reverse order to cleanly
  # unmount submounts (think /dev/pts and /dev).
  awk -v path=$1 -v len="${#1}" \
    '(substr($2, 1, len) == path) { print $2 }' /proc/self/mounts | \
    tac | \
    sed -e 's/\\040(deleted)$//'
  # Hack(zbehan): If a bind mount's source is mysteriously removed,
  # we'd end up with an orphaned mount with the above string in its name.
  # It can only be seen through /proc/mounts and will stick around even
  # when it should be gone already. crosbug.com/31250
}

# Unmounts a directory, if the unmount fails, warn, and then lazily unmount.
#
# $1 - The path to unmount.
safe_umount_tree() {
  local mounts=$(sub_mounts "$1")

  # Hmm, this shouldn't normally happen, but anything is possible.
  if [[ -z ${mounts} ]]; then
    return 0
  fi

  # First try to unmount, this might fail because of nested binds.
  if sudo umount -d ${mounts}; then
    return 0;
  fi

  # Check whether our mounts were successfully unmounted.
  mounts=$(sub_mounts "$1")
  if [[ -z ${mounts} ]]; then
    warn "umount failed, but devices were unmounted anyway"
    return 0
  fi

  # Try one more time, this one will die hard if it fails.
  warn "Failed to unmount ${mounts}"
  safe_umount -d ${mounts}
}


# Run umount as root.
safe_umount() {
  if sudo umount "$@"; then
    return 0;
  else
    failboat safe_umount
  fi
}

# Check if a single path is mounted.
is_mounted() {
  if grep -q "$(readlink -f "$1")" /proc/self/mounts; then
    return 0
  else
    return 1
  fi
}

fix_mtab() {
    local root="$1" mounts="../proc/self/mounts"
    if [[ "$(readlink "${root}/etc/mtab")" != "${mounts}" ]]; then
        sudo ln -sf "${mounts}" "${root}/etc/mtab"
    fi
}

get_git_id() {
  git var GIT_COMMITTER_IDENT | sed -e 's/^.*<\(\S\+\)>.*$/\1/'
}

# Generate a DIGESTS file, as normally used by Gentoo.
# This is an alternative to shash which doesn't know how to report errors.
# Usage: make_digests -d file.DIGESTS file1 [file2...]
_digest_types="md5 sha1 sha512"
make_digests() {
    [[ "$1" == "-d" ]] || die
    local digests="$(readlink -f "$2")"
    shift 2

    pushd "$(dirname "$1")" >/dev/null
    echo -n > "${digests}"
    for filename in "$@"; do
        filename=$(basename "$filename")
        info "Computing DIGESTS for ${filename}"
        for hash_type in $_digest_types; do
            echo "# $hash_type HASH" | tr "a-z" "A-Z" >> "${digests}"
            ${hash_type}sum "${filename}" >> "${digests}"
        done
    done
    popd >/dev/null
}

# Validate a DIGESTS file. Essentially the inverse of make_digests.
# Usage: verify_digests [-d file.DIGESTS] file1 [file2...]
# If -d is not specified file1.DIGESTS will be used
verify_digests() {
    local digests filename hash_type status
    if [[ "$1" == "-d" ]]; then
        [[ -n "$2" ]] || die "-d requires an argument"
        digests="$(readlink -f "$2")"
        shift 2
    else
        digests=$(basename "${1}.DIGESTS")
    fi

    pushd "$(dirname "$1")" >/dev/null
    for filename in "$@"; do
        filename=$(basename "$filename")
        info "Validating DIGESTS for ${filename}"
        for hash_type in $_digest_types; do
            grep -A1 -i "^# ${hash_type} HASH$" "${digests}" | \
                grep "$filename$" | ${hash_type}sum -c - --strict || return 1
            # Also check that none of the greps failed in the above pipeline
            for status in ${PIPESTATUS[@]}; do
                [[ $status -eq 0 ]] || return 1
            done
        done
    done
    popd >/dev/null
}

# Get current timestamp. Assumes common.sh runs at startup.
start_time=$(date +%s)

# Get time elapsed since start_time in seconds.
get_elapsed_seconds() {
  local end_time=$(date +%s)
  local elapsed_seconds=$(( end_time - start_time ))
  echo ${elapsed_seconds}
}

# Print time elapsed since start_time.
print_time_elapsed() {
  # Optional first arg to specify elapsed_seconds.  If not given, will
  # recalculate elapsed time to now.  Optional second arg to specify
  # command name associated with elapsed time.
  local elapsed_seconds=${1:-$(get_elapsed_seconds)}
  local cmd_base=${2:-}

  local minutes=$(( elapsed_seconds / 60 ))
  local seconds=$(( elapsed_seconds % 60 ))

  if [[ -n ${cmd_base} ]]; then
    info "Elapsed time (${cmd_base}): ${minutes}m${seconds}s"
  else
    info "Elapsed time: ${minutes}m${seconds}s"
  fi
}

# Save original command line.
command_line_arr=( "$0" "$@" )

command_completed() {
  # Call print_elapsed_time regardless.
  local run_time=$(get_elapsed_seconds)
  local cmd_base=$(basename "${command_line_arr[0]}")
  print_time_elapsed ${run_time} ${cmd_base}
}

# The board and variant command line options can be used in a number of ways
# to specify the board and variant.  The board can encode both pieces of
# information separated by underscores.  Or the variant can be passed using
# the separate variant option.  This function extracts the canonical board and
# variant information and provides it in the BOARD, VARIANT and BOARD_VARIANT
# variables.
get_board_and_variant() {
  local flags_board=$1
  local flags_variant=$2

  BOARD=$(echo "${flags_board}" | cut -d '_' -f 1)
  VARIANT=${flags_variant:-$(echo "${flags_board}" | cut -s -d '_' -f 2)}

  BOARD_VARIANT=${BOARD}
  if [[ -n ${VARIANT} ]]; then
    BOARD_VARIANT+="_${VARIANT}"
  fi
}

# Check that the specified file exists.  If the file path is empty or the file
# doesn't exist on the filesystem generate useful error messages.  Otherwise
# show the user the name and path of the file that will be used.  The padding
# parameter can be used to tabulate multiple name:path pairs.  For example:
#
# check_for_file "really long name" "...:" "file.foo"
# check_for_file "short name" ".........:" "another.bar"
#
# Results in the following output:
#
# Using really long name...: file.foo
# Using short name.........: another.bar
#
# If tabulation is not required then passing "" for padding generates the
# output "Using <name> <path>"
check_for_file() {
  local name=$1
  local padding=$2
  local path=$3

  if [[ -z ${path} ]]; then
    die "No ${name} file specified."
  fi

  if [[ ! -e ${path} ]]; then
    die "No ${name} file found at: ${path}"
  else
    info "Using ${name}${padding} ${path}"
  fi
}

# Check that the specified tool exists.  If it does not exist in the PATH
# generate a useful error message indicating how to install the ebuild
# that contains the required tool.
check_for_tool() {
  local tool=$1
  local ebuild=$2

  if ! which "${tool}" >/dev/null; then
    error "The ${tool} utility was not found in your path.  Run the following"
    error "command in your chroot to install it: sudo -E emerge ${ebuild}"
    exit 1
  fi
}

# Reinterprets path from outside the chroot for use inside.
# Returns "" if "" given.
# $1 - The path to reinterpret.
reinterpret_path_for_chroot() {
  if [[ ${INSIDE_CHROOT} -ne 1 ]]; then
    if [[ -z $1 ]]; then
      echo ""
    else
      local path_abs_path=$(readlink -f "$1")
      local gclient_root_abs_path=$(readlink -f "${GCLIENT_ROOT}")

      # Strip the repository root from the path.
      local relative_path=$(echo ${path_abs_path} \
          | sed "s:${gclient_root_abs_path}/::")

      if [[ ${relative_path} == "${path_abs_path}" ]]; then
        die "Error reinterpreting path.  Path $1 is not within source tree."
      fi

      # Prepend the chroot repository path.
      echo "/home/${USER}/trunk/${relative_path}"
    fi
  else
    # Path is already inside the chroot :).
    echo "$1"
  fi
}

# Get the relative path between two locations. Handy for printing paths to
# the user that will usually make sense both inside and outside the chroot.
relpath() {
  local py='import sys, os; print os.path.relpath(sys.argv[1], sys.argv[2])'
  python2 -c "${py}" "${1}" "${2:-.}"
}

enable_strict_sudo() {
  if [[ -z ${CROS_SUDO_KEEP_ALIVE} ]]; then
    echo "$0 was somehow invoked in a way that the sudo keep alive could"
    echo "not be found.  Failing due to this.  See crosbug.com/18393."
    exit 126
  fi
  sudo() {
    $(type -P sudo) -n "$@"
  }
}

# Checks that stdin and stderr are both terminals.
# If so, we assume that there is a live user we can interact with.
# This check can be overridden by setting the CROS_NO_PROMPT environment
# variable to a non-empty value.
is_interactive() {
  [[ -z ${CROS_NO_PROMPT} && -t 0 && -t 2 ]]
}

assert_interactive() {
  if ! is_interactive; then
    die "Script ${0##*/} tried to get user input on a non-interactive terminal."
  fi
}

# Display --help if requested. This is used to hide options from help
# that are not intended for developer use.
#
# How to use:
#  1) Declare the options that you want to appear in help.
#  2) Call this function.
#  3) Declare the options that you don't want to appear in help.
#
# See build_packages for example usage.
show_help_if_requested() {
  local opt
  for opt in "$@"; do
    if [[ ${opt} == "-h" || ${opt} == "--help" ]]; then
      flags_help
      exit 0
    fi
  done
}

switch_to_strict_mode() {
  # Set up strict execution mode; note that the trap
  # must follow switch_to_strict_mode, else it will have no effect.
  set -e
  trap 'die_err_trap "${BASH_COMMAND:-command unknown}" "$?"' ERR
  if [[ $# -ne 0 ]]; then
    set "$@"
  fi
}

# TODO: Re-enable this once shflags is set -e safe.
#switch_to_strict_mode

okboat() {
  # http://www.chris.com/ascii/index.php?art=transportation/nautical
  echo -e "${V_BOLD_GREEN}"
  cat <<BOAT
    .  o ..
    o . o o.o
         ...oo_
           _[__\\___
        __|_o_o_o_o\\__
    OK  \\' ' ' ' ' ' /
    ^^^^^^^^^^^^^^^^^^^^
BOAT
  echo -e "${V_VIDOFF}"
}

failboat() {
  echo -e "${V_BOLD_RED}"
  cat <<BOAT
             '
        '    )
         ) (
        ( .')  __/\\
          (.  /o/\` \\
           __/o/\`   \\
    FAIL  / /o/\`    /
    ^^^^^^^^^^^^^^^^^^^^
BOAT
  echo -e "${V_VIDOFF}"
  die "$* failed"
}

# The binfmt_misc support in the kernel is required.
setup_qemu_static() {
  local root_fs_dir="$1"
  case "${BOARD}" in
    amd64-usr) return 0;;
    *) die "Unsupported arch" ;;
  esac
}

clean_qemu_static() {
  local root_fs_dir="$1"
  case "${BOARD}" in
    amd64-usr) return 0;;
    *) die "Unsupported arch" ;;
  esac
}
