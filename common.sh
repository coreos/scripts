# Copyright (c) 2012 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Common constants for build scripts
# This must evaluate properly for both /bin/bash and /bin/sh

# All scripts should die on error unless commands are specifically excepted
# by prefixing with '!' or surrounded by 'set +e' / 'set -e'.
# TODO: Re-enable this once shflags is less prone to dying.
#set -e

# The number of jobs to pass to tools that can run in parallel (such as make
# and dpkg-buildpackage
NUM_JOBS=$(grep -c "^processor" /proc/cpuinfo)

# True if we have the 'pv' utility - also set up COMMON_PV_CAT for convenience
COMMON_PV_OK=1
COMMON_PV_CAT=pv
pv -V >/dev/null 2>&1 || COMMON_PV_OK=0
if [ $COMMON_PV_OK -eq 0 ]; then
  COMMON_PV_CAT=cat
fi

# Make sure we have the location and name of the calling script, using
# the current value if it is already set.
SCRIPT_LOCATION=${SCRIPT_LOCATION:-$(dirname "$(readlink -f "$0")")}
SCRIPT_NAME=${SCRIPT_NAME:-$(basename "$0")}

# Detect whether we're inside a chroot or not
if [ -e /etc/debian_chroot ]
then
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

if tput colors >/dev/null 2>&1; then
  # order matters: we want VIDOFF last so that when we trace with `set -x`,
  # our terminal doesn't bleed colors as bash dumps the values of vars.
  V_BOLD_RED="$(tput bold; tput setaf 1)"
  V_BOLD_GREEN="$(tput bold; tput setaf 2)"
  V_BOLD_YELLOW="$(tput bold; tput setaf 3)"
  V_REVERSE="$(tput rev)"
  V_VIDOFF="$(tput sgr0)"
fi

# Declare these asap so that code below can safely assume they exist.
function info {
  echo -e >&2  "${V_BOLD_GREEN}INFO    ${CROS_LOG_PREFIX:-""}: $@${V_VIDOFF}"
}

function warn {
  echo -e >&2 "${V_BOLD_YELLOW}WARNING ${CROS_LOG_PREFIX:-""}: $@${V_VIDOFF}"
}

function error {
  echo -e >&2    "${V_BOLD_RED}ERROR   ${CROS_LOG_PREFIX:-""}: $@${V_VIDOFF}"
}

function die {
  error "$@"
  exit 1
}

# Construct a list of possible locations for the source tree.  This list is
# based on various environment variables and globals that may have been set
# by the calling script.
function get_gclient_root_list() {
  if [ $INSIDE_CHROOT -eq 1 ]; then
    echo "/home/${USER}/trunk"

    if [ -n "${SUDO_USER}" ]; then echo "/home/${SUDO_USER}/trunk"; fi
  fi

  if [ -n "${COMMON_SH}" ]; then echo "$(dirname "$COMMON_SH")/../.."; fi
  if [ -n "${BASH_SOURCE}" ]; then echo "$(dirname "$BASH_SOURCE")/../.."; fi
}

# Based on the list of possible source locations we set GCLIENT_ROOT if it is
# not already defined by looking for a src directory in each seach path
# location.  If we do not find a valid looking root we error out.
function get_gclient_root() {
  if [ -n "${GCLIENT_ROOT}" ]; then
    return
  fi

  for path in $(get_gclient_root_list); do
    if [ -d "${path}/src" ]; then
      GCLIENT_ROOT=${path}
      break
    fi
  done

  if [ -z "${GCLIENT_ROOT}" ]; then
    # Using dash or sh, we don't know where we are.  $0 refers to the calling
    # script, not ourselves, so that doesn't help us.
    echo "Unable to determine location for common.sh.  If you are sourcing"
    echo "common.sh from a script run via dash or sh, you must do it in the"
    echo "following way:"
    echo '  COMMON_SH="$(dirname "$0")/../../scripts/common.sh"'
    echo '  . "$COMMON_SH"'
    echo "where the first line is the relative path from your script to"
    echo "common.sh."
    exit 1
  fi
}

# Find root of source tree
get_gclient_root

# Canonicalize the directories for the root dir and the calling script.
# readlink is part of coreutils and should be present even in a bare chroot.
# This is better than just using
#     FOO = "$(cd $FOO ; pwd)"
# since that leaves symbolic links intact.
# Note that 'realpath' is equivalent to 'readlink -f'.
SCRIPT_LOCATION=$(readlink -f "$SCRIPT_LOCATION")
GCLIENT_ROOT=$(readlink -f "$GCLIENT_ROOT")

# Other directories should always be pathed down from GCLIENT_ROOT.
SRC_ROOT="$GCLIENT_ROOT/src"
SRC_INTERNAL="$GCLIENT_ROOT/src-internal"
SCRIPTS_DIR="$SRC_ROOT/scripts"

# Load developer's custom settings.  Default location is in scripts dir,
# since that's available both inside and outside the chroot.  By convention,
# settings from this file are variables starting with 'CHROMEOS_'
CHROMEOS_DEV_SETTINGS="${CHROMEOS_DEV_SETTINGS:-$SCRIPTS_DIR/.chromeos_dev}"
if [ -f "$CHROMEOS_DEV_SETTINGS" ]; then
  # Turn on exit-on-error during custom settings processing
  SAVE_OPTS=$(set +o)
  set -e

  # Read settings
  . "$CHROMEOS_DEV_SETTINGS"

  # Restore previous state of exit-on-error
  eval "$SAVE_OPTS"
fi

# Load shflags
# NOTE: This code snippet is in particular used by the au-generator (which
# stores shflags in ./lib/shflags/) and should not be touched.
if [ -f "${SCRIPTS_DIR}/lib/shflags/shflags" ]; then
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
DEFAULT_CHROOT_DIR=${CHROMEOS_CHROOT_DIR:-"$GCLIENT_ROOT/chroot"}

# All output files from build should go under $DEFAULT_BUILD_ROOT, so that
# they don't pollute the source directory.
DEFAULT_BUILD_ROOT=${CHROMEOS_BUILD_ROOT:-"$SRC_ROOT/build"}

# Set up a global ALL_BOARDS value
if [ -d "$SRC_ROOT/overlays" ]; then
  ALL_BOARDS=$(cd "$SRC_ROOT/overlays"; \
    ls -1d overlay-* 2>&- | sed 's,overlay-,,g')
fi
# Strip CR
ALL_BOARDS=$(echo $ALL_BOARDS)
# Set a default BOARD
#DEFAULT_BOARD=x86-generic # or...
DEFAULT_BOARD=$(echo $ALL_BOARDS | awk '{print $NF}')

# Enable --fast by default.
DEFAULT_FAST=${FLAGS_TRUE}

# Directory to store built images.  Should be set by sourcing script when used.
BUILD_DIR=

# Standard filenames
CHROMEOS_BASE_IMAGE_NAME="chromiumos_base_image.bin"
CHROMEOS_IMAGE_NAME="chromiumos_image.bin"
CHROMEOS_DEVELOPER_IMAGE_NAME="chromiumos_image.bin"
CHROMEOS_RECOVERY_IMAGE_NAME="recovery_image.bin"
CHROMEOS_TEST_IMAGE_NAME="chromiumos_test_image.bin"
CHROMEOS_FACTORY_TEST_IMAGE_NAME="chromiumos_factory_image.bin"
CHROMEOS_FACTORY_INSTALL_SHIM_NAME="factory_install_shim.bin"

# Directory locations inside the dev chroot
CHROOT_TRUNK_DIR="/home/$USER/trunk"

# Install make for portage ebuilds.  Used by build_image and gmergefs.
# TODO: Is /usr/local/autotest-chrome still used by anyone?
COMMON_INSTALL_MASK="
  *.a
  *.la
  /etc/init.d
  /etc/runlevels
  /lib/rc
  /usr/bin/Xnest
  /usr/bin/Xvfb
  /usr/include
  /usr/lib/debug
  /usr/lib/gcc
  /usr/lib/gtk-2.0/include
  /usr/lib/pkgconfig
  /usr/local/autotest-chrome
  /usr/man
  /usr/share/aclocal
  /usr/share/doc
  /usr/share/gettext
  /usr/share/gtk-2.0
  /usr/share/gtk-doc
  /usr/share/info
  /usr/share/man
  /usr/share/openrc
  /usr/share/pkgconfig
  /usr/share/readline
  /usr/src
  "

# Mask for base, dev, and test images (build_image, build_image --test)
DEFAULT_INSTALL_MASK="
  $COMMON_INSTALL_MASK
  /usr/local/autotest
  "

# Mask for factory test image (build_image --factory)
FACTORY_TEST_INSTALL_MASK="
  $COMMON_INSTALL_MASK
  */.svn
  */CVS
  /usr/local/autotest/[^c]*
  /usr/local/autotest/conmux
  /usr/local/autotest/client/deps/chrome_test
  /usr/local/autotest/client/deps/piglit
  /usr/local/autotest/client/deps/pyauto_dep
  /usr/local/autotest/client/deps/realtimecomm_*
  /usr/local/autotest/client/site_tests/desktopui_PageCyclerTests
  /usr/local/autotest/client/site_tests/graphics_WebGLConformance
  /usr/local/autotest/client/site_tests/platform_ToolchainOptions
  /usr/local/autotest/client/site_tests/realtimecomm_GTalk*
  "

# Mask for factory install shim (build_image factory_install)
FACTORY_SHIM_INSTALL_MASK="
  $DEFAULT_INSTALL_MASK
  /opt/[^g]*
  /opt/google/chrome
  /opt/google/o3d
  /opt/google/talkplugin
  /usr/lib/dri
  /usr/lib/python2.6/test
  /usr/local/autotest-pkgs
  /usr/share/X11
  /usr/share/chewing
  /usr/share/fonts
  /usr/share/ibus-pinyin
  /usr/share/libhangul
  /usr/share/locale
  /usr/share/m17n
  /usr/share/mime
  /usr/share/sounds
  /usr/share/tts
  /usr/share/zoneinfo
  "

# -----------------------------------------------------------------------------
# Functions

function setup_board_warning {
  echo
  echo "$V_REVERSE=================  WARNING  ======================$V_VIDOFF"
  echo
  echo "*** No default board detected in " \
    "$GCLIENT_ROOT/src/scripts/.default_board"
  echo "*** Either run setup_board with default flag set"
  echo "*** or echo |board_name| > $GCLIENT_ROOT/src/scripts/.default_board"
  echo
}


# Sets the default board variable for calling script
function get_default_board {
  DEFAULT_BOARD=

  if [ -f "$GCLIENT_ROOT/src/scripts/.default_board" ] ; then
    DEFAULT_BOARD=$(cat "$GCLIENT_ROOT/src/scripts/.default_board")
    # Check for user typos like whitespace.
    if [[ -n ${DEFAULT_BOARD//[a-zA-Z0-9-_]} ]] ; then
      die ".default_board: invalid name detected; please fix:" \
          "'${DEFAULT_BOARD}'"
    fi
  fi
}


# Enter a chroot and restart the current script if needed
function restart_in_chroot_if_needed {
  # NB:  Pass in ARGV:  restart_in_chroot_if_needed "$@"
  if [ $INSIDE_CHROOT -ne 1 ]; then
    # Get inside_chroot path for script.
    local chroot_path="$(reinterpret_path_for_chroot "$0")"
    exec $GCLIENT_ROOT/chromite/bin/cros_sdk -- "$chroot_path" "$@"
  fi
}

# Fail unless we're inside the chroot.  This guards against messing up your
# workstation.
function assert_inside_chroot {
  if [ $INSIDE_CHROOT -ne 1 ]; then
    echo "This script must be run inside the chroot.  Run this first:"
    echo "    cros_sdk"
    exit 1
  fi
}

# Fail if we're inside the chroot.  This guards against creating or entering
# nested chroots, among other potential problems.
function assert_outside_chroot {
  if [ $INSIDE_CHROOT -ne 0 ]; then
    echo "This script must be run outside the chroot."
    exit 1
  fi
}

function assert_not_root_user {
  if [ $(id -u) = 0 ]; then
    echo "This script must be run as a non-root user."
    exit 1
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
function check_flags_only_and_allow_null_arg {
  do_shift=1
  if [[ $# == 1 && -z "$@" ]]; then
    echo "$0: warning: ignoring null argument" >&2
    shift
    do_shift=0
  fi
  if [[ $# -gt 0 ]]; then
    echo "error: invalid arguments: \"$@\"" >&2
    flags_help
    exit 1
  fi
  return $do_shift
}

# Retry an emerge command according to $FLAGS_retries
function eretry () {
  local i
  for i in $(seq $FLAGS_retries); do
    echo "Retrying $@"
    "$@" && return 0
  done
  "$@" && return 0
  return 1
}

# Removes single quotes around parameter
# Arguments:
#   $1 - string which optionally has surrounding quotes
# Returns:
#   None, but prints the string without quotes.
function remove_quotes() {
  echo "$1" | sed -e "s/^'//; s/'$//"
}

# Writes stdin to the given file name as root using sudo in overwrite mode.
#
# $1 - The output file name.
function sudo_clobber() {
  sudo tee "$1" > /dev/null
}

# Writes stdin to the given file name as root using sudo in append mode.
#
# $1 - The output file name.
function sudo_append() {
  sudo tee -a "$1" > /dev/null
}

# Execute multiple commands in a single sudo. Generally will speed things
# up by avoiding multiple calls to `sudo`. If any commands fail, we will
# call die with the failing command. We can handle a max of ~100 commands,
# but hopefully no one will ever try that many at once.
#
# $@ - The commands to execute, one per arg.
function sudo_multi() {
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

# Locate all mounts below a specified directory.
#
# $1 - The root tree.
function sub_mounts() {
  # Assume that `mount` outputs a list of mount points in the order
  # that things were mounted (since it always has and hopefully always
  # will).  As such, we have to unmount in reverse order to cleanly
  # unmount submounts (think /dev/pts and /dev).
  mount | \
    awk -v path="$1" -v len="${#1}" \
      '(substr($3, 1, len) == path) { print $3 }' | \
    tac
}

# Unmounts a directory, if the unmount fails, warn, and then lazily unmount.
#
# $1 - The path to unmount.
function safe_umount_tree {
  local mounts=$(sub_mounts "$1")

  # Hmm, this shouldn't normally happen, but anything is possible.
  if [ -z "${mounts}" ] ; then
    return 0
  fi

  # First try to unmount in one shot to speed things up.
  if sudo umount -d ${mounts}; then
    return 0
  fi

  # Well that didn't work, so lazy unmount remaining ones.
  mounts=$(sub_mounts "$1")
  warn "Failed to unmount ${mounts}"
  warn "Doing a lazy unmount"
  if ! sudo umount -d -l ${mounts}; then
    mounts=$(sub_mounts "$1")
    die "Failed to lazily unmount ${mounts}"
  fi
}

# Fixes symlinks that are incorrectly prefixed with the build root ${1}
# rather than the real running root '/'.
# TODO(sosa) - Merge setup - cleanup below with this method.
fix_broken_symlinks() {
  local build_root="${1}"
  local symlinks=$(find "${build_root}/usr/local" -lname "${build_root}/*")
  local symlink
  for symlink in ${symlinks}; do
    echo "Fixing ${symlink}"
    local target=$(ls -l "${symlink}" | cut -f 2 -d '>')
    # Trim spaces from target (bashism).
    target=${target/ /}
    # Make new target (removes rootfs prefix).
    new_target=$(echo ${target} | sed "s#${build_root}##")

    echo "Fixing symlink ${symlink}"
    sudo unlink "${symlink}"
    sudo ln -sf "${new_target}" "${symlink}"
  done
}

# Sets up symlinks for the developer root. It is necessary to symlink
# usr and local since the developer root is mounted at /usr/local and
# applications expect to be installed under /usr/local/bin, etc.
# This avoids packages installing into /usr/local/usr/local/bin.
# ${1} specifies the symlink target for the developer root.
# ${2} specifies the symlink target for the var directory.
# ${3} specifies the location of the stateful partition.
setup_symlinks_on_root() {
  # Give args better names.
  local dev_image_target=${1}
  local var_target=${2}
  local dev_image_root="${3}/dev_image"

  # If our var target is actually the standard var, we are cleaning up the
  # symlinks (could also check for /usr/local for the dev_image_target).
  if [ ${var_target} = "/var" ]; then
    echo "Cleaning up /usr/local symlinks for ${dev_image_root}"
  else
    echo "Setting up symlinks for /usr/local for ${dev_image_root}"
  fi

  # Set up symlinks that should point to ${dev_image_target}.
  local path
  for path in usr local; do
    if [ -h "${dev_image_root}/${path}" ]; then
      sudo unlink "${dev_image_root}/${path}"
    elif [ -e "${dev_image_root}/${path}" ]; then
      die "${dev_image_root}/${path} should be a symlink if exists"
    fi
    sudo ln -s "${dev_image_target}" "${dev_image_root}/${path}"
  done

  # Setup var symlink.
  if [ -h "${dev_image_root}/var" ]; then
    sudo unlink "${dev_image_root}/var"
  elif [ -e "${dev_image_root}/var" ]; then
    die "${dev_image_root}/var should be a symlink if it exists"
  fi

  sudo ln -s "${var_target}" "${dev_image_root}/var"
}

# These two helpers clobber the ro compat value in our root filesystem.
#
# When the system is built with --enable_rootfs_verification, bit-precise
# integrity checking is performed.  That precision poses a usability issue on
# systems that automount partitions with recognizable filesystems, such as
# ext2/3/4.  When the filesystem is mounted 'rw', ext2 metadata will be
# automatically updated even if no other writes are performed to the
# filesystem.  In addition, ext2+ does not support a "read-only" flag for a
# given filesystem.  That said, forward and backward compatibility of
# filesystem features are supported by tracking if a new feature breaks r/w or
# just write compatibility.  We abuse the read-only compatibility flag[1] in
# the filesystem header by setting the high order byte (le) to FF.  This tells
# the kernel that features R24-R31 are all enabled.  Since those features are
# undefined on all ext-based filesystem, all standard kernels will refuse to
# mount the filesystem as read-write -- only read-only[2].
#
# [1] 32-bit flag we are modifying:
#  http://git.chromium.org/cgi-bin/gitweb.cgi?p=kernel.git;a=blob;f=include/linux/ext2_fs.h#l417
# [2] Mount behavior is enforced here:
#  http://git.chromium.org/cgi-bin/gitweb.cgi?p=kernel.git;a=blob;f=fs/ext2/super.c#l857
#
# N.B., if the high order feature bits are used in the future, we will need to
#       revisit this technique.
disable_rw_mount() {
  local rootfs="$1"
  local offset="${2-0}"  # in bytes
  local ro_compat_offset=$((0x464 + 3))  # Set 'highest' byte
  printf '\377' |
    sudo dd of="$rootfs" seek=$((offset + ro_compat_offset)) \
            conv=notrunc count=1 bs=1
}

enable_rw_mount() {
  local rootfs="$1"
  local offset="${2-0}"
  local ro_compat_offset=$((0x464 + 3))  # Set 'highest' byte
  printf '\000' |
    sudo dd of="$rootfs" seek=$((offset + ro_compat_offset)) \
            conv=notrunc count=1 bs=1
}

# Get current timestamp. Assumes common.sh runs at startup.
start_time=$(date +%s)

# Print time elsapsed since start_time.
print_time_elapsed() {
  local end_time=$(date +%s)
  local elapsed_seconds=$(($end_time - $start_time))
  local minutes=$(($elapsed_seconds / 60))
  local seconds=$(($elapsed_seconds % 60))
  echo "Elapsed time: ${minutes}m${seconds}s"
}

# The board and variant command line options can be used in a number of ways
# to specify the board and variant.  The board can encode both pieces of
# information separated by underscores.  Or the variant can be passed using
# the separate variant option.  This function extracts the canonical board and
# variant information and provides it in the BOARD, VARIANT and BOARD_VARIANT
# variables.
get_board_and_variant() {
  local flags_board="${1}"
  local flags_variant="${2}"

  BOARD=$(echo "$flags_board" | cut -d '_' -f 1)
  VARIANT=${flags_variant:-$(echo "$flags_board" | cut -s -d '_' -f 2)}

  if [ -n "$VARIANT" ]; then
    BOARD_VARIANT="${BOARD}_${VARIANT}"
  else
    BOARD_VARIANT="${BOARD}"
  fi
}

# This function converts a chromiumos image into a test image, either
# in place or by copying to a new test image filename first. It honors
# the following flags (see mod_image_for_test.sh)
#
#   --factory
#   --factory_install
#   --force_copy
#
# On entry, pass the directory containing the image, and the image filename
# On exit, it puts the pathname of the resulting test image into
# CHROMEOS_RETURN_VAL
# (yes this is ugly, but perhaps less ugly than the alternatives)
#
# Usage:
#   SRC_IMAGE=$(prepare_test_image "directory" "imagefile")
prepare_test_image() {
  # If we're asked to modify the image for test, then let's make a copy and
  # modify that instead.
  # Check for manufacturing image.
  local args

  if [ ${FLAGS_factory} -eq ${FLAGS_TRUE} ]; then
    args="--factory"
  fi

  # Check for install shim.
  if [ ${FLAGS_factory_install} -eq ${FLAGS_TRUE} ]; then
    args="--factory_install"
  fi

  # Check for forcing copy of image
  if [ ${FLAGS_force_copy} -eq ${FLAGS_TRUE} ]; then
    args="${args} --force_copy"
  fi

  # Modify the image for test, creating a new test image
  "${SCRIPTS_DIR}/mod_image_for_test.sh" --board=${FLAGS_board} \
    --image="$1/$2" --noinplace ${args}

  # From now on we use the just-created test image
  if [ ${FLAGS_factory} -eq ${FLAGS_TRUE} ]; then
    CHROMEOS_RETURN_VAL="$1/${CHROMEOS_FACTORY_TEST_IMAGE_NAME}"
  else
    CHROMEOS_RETURN_VAL="$1/${CHROMEOS_TEST_IMAGE_NAME}"
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

  if [ -z "${path}" ]; then
    die "No ${name} file specified."
  fi

  if [ ! -e "${path}" ]; then
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

  if ! which "${tool}" >/dev/null ; then
    error "The ${tool} utility was not found in your path.  Run the following"
    error "command in your chroot to install it: sudo -E emerge ${ebuild}"
    exit 1
  fi
}

# Reinterprets path from outside the chroot for use inside.
# Returns "" if "" given.
# $1 - The path to reinterpret.
function reinterpret_path_for_chroot() {
  if [ $INSIDE_CHROOT -ne 1 ]; then
    if [ -z "${1}" ]; then
      echo ""
    else
      local path_abs_path=$(readlink -f "${1}")
      local gclient_root_abs_path=$(readlink -f "${GCLIENT_ROOT}")

      # Strip the repository root from the path.
      local relative_path=$(echo ${path_abs_path} \
          | sed "s:${gclient_root_abs_path}/::")

      if [ "${relative_path}" = "${path_abs_path}" ]; then
        die "Error reinterpreting path.  Path ${1} is not within source tree."
      fi

      # Prepend the chroot repository path.
      echo "/home/${USER}/trunk/${relative_path}"
    fi
  else
    # Path is already inside the chroot :).
    echo "${1}"
  fi
}

function emerge_custom_kernel() {
  local install_root="$1"
  local root=${FLAGS_build_root}/${FLAGS_board}
  local tmp_pkgdir=${root}/custom-packages

  # Clean up any leftover state in custom directories.
  sudo rm -rf "${tmp_pkgdir}"

  # Update chromeos-initramfs to contain the latest binaries from the build
  # tree. This is basically just packaging up already-built binaries from
  # $root. We are careful not to muck with the existing prebuilts so that
  # prebuilts can be uploaded in parallel.
  # TODO(davidjames): Implement ABI deps so that chromeos-initramfs will be
  # rebuilt automatically when its dependencies change.
  sudo -E PKGDIR="${tmp_pkgdir}" $EMERGE_BOARD_CMD -1 \
    chromeos-base/chromeos-initramfs || die "Cannot emerge chromeos-initramfs"

  # Verify all dependencies of the kernel are installed. This should be a
  # no-op, but it's good to check in case a developer didn't run
  # build_packages.
  local kernel=$(portageq-${FLAGS_board} expand_virtual ${root} virtual/kernel)
  sudo -E PKGDIR="${tmp_pkgdir}" $EMERGE_BOARD_CMD --onlydeps \
    ${kernel} || die "Cannot emerge kernel dependencies"

  # Build the kernel. This uses the standard root so that we can pick up the
  # initramfs from there. But we don't actually install the kernel to the
  # standard root, because that'll muck up the kernel debug symbols there,
  # which we want to upload in parallel.
  sudo -E PKGDIR="${tmp_pkgdir}" $EMERGE_BOARD_CMD --buildpkgonly \
    ${kernel} || die "Cannot emerge kernel"

  # Install the custom kernel to the provided install root.
  sudo -E PKGDIR="${tmp_pkgdir}" $EMERGE_BOARD_CMD --usepkgonly \
    --root=${install_root} ${kernel} || die "Cannot emerge kernel to root"
}

function enable_strict_sudo {
  if [ -z "$CROS_SUDO_KEEP_ALIVE" ]; then
    echo "$0 was somehow invoked in a way that the sudo keep alive could"
    echo "not be found.  Failing due to this.  See crosbug.com/18393."
    exit 126
  fi
  function sudo {
    `type -P sudo` -n "$@"
  }
}

# Checks that stdin and stderr are both terminals.
# If so, we assume that there is a live user we can interact with.
# This check can be overridden by setting the CROS_NO_PROMPT environment
# variable to a non-empty value.
function is_interactive() {
  [ -z "${CROS_NO_PROMPT}" -a -t 0 -a -t 2 ]
}

function assert_interactive() {
  if ! is_interactive; then
    die "Script ${0##*/} tried to get user input on a non-interactive terminal."
  fi
}

# Selection menu with a default option: this is similar to bash's select
# built-in, only that in case of an empty selection it'll return the default
# choice. Like select, it uses PS3 as the prompt.
#
# $1:   name of variable to be assigned the selected value; it better not be of
#       the form choose_foo to avoid conflict with local variables.
# $2:   default value to return in case of an empty user entry.
# $3:   value to return in case of an invalid choice.
# $...: options for selection.
#
# Usage example:
#
#  PS3="Select one [1]: "
#  choose reply "foo" "ERROR" "foo" "bar" "foobar"
#
# This will present the following menu and prompt:
#
#  1) foo
#  2) bar
#  3) foobar
#  Select one [1]:
#
# The return value will be stored in a variable named 'reply'. If the input is
# 1, 2 or 3, the return value will be "foo", "bar" or "foobar", respectively.
# If it is empty (i.e. the user clicked Enter) it will be "foo".  Anything else
# will return "ERROR".
function choose() {
  typeset -i choose_i=1

  # Retrieve output variable name and default return value.
  local choose_reply=$1
  local choose_default="$2"
  local choose_invalid="$3"
  shift 3

  # Select a return value
  unset REPLY
  if [ $# -gt 0 ]; then
    assert_interactive

    # Actual options provided, present a menu and prompt for a choice.
    local choose_opt
    for choose_opt in "$@"; do
      echo "$choose_i) $choose_opt" >&2
      choose_i=choose_i+1
    done
    read -p "$PS3"
  fi
  # Filter out strings containing non-digits.
  if [ "${REPLY}" != "${REPLY%%[!0-9]*}" ]; then
    REPLY=0
  fi
  choose_i="${REPLY}"

  if [ $choose_i -ge 1 -a $choose_i -le $# ]; then
    # Valid choice, return the corresponding value.
    eval ${choose_reply}="${!choose_i}"
  elif [ -z "${REPLY}" ]; then
    # Empty choice, return default value.
    eval ${choose_reply}="${choose_default}"
  else
    # Invalid choice, return corresponding value.
    eval ${choose_reply}="${choose_invalid}"
  fi
}
