# Copyright (c) 2010 The Chromium OS Authors. All rights reserved.
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
NUM_JOBS=`grep -c "^processor" /proc/cpuinfo`

# Store location of the calling script.
TOP_SCRIPT_DIR="${TOP_SCRIPT_DIR:-$(dirname $0)}"

# Find root of source tree
if [ "x$GCLIENT_ROOT" != "x" ]
then
  # GCLIENT_ROOT already set, so we're done
  true
elif [ "x$COMMON_SH" != "x" ]
then
  # COMMON_SH set, so assume that's us
  GCLIENT_ROOT="$(dirname "$COMMON_SH")/../.."
elif [ "x$BASH_SOURCE" != "x" ]
then
  # Using bash, so we can find ourselves
  GCLIENT_ROOT="$(dirname "$BASH_SOURCE")/../.."
else
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

# Canonicalize the directories for the root dir and the calling script.
# readlink is part of coreutils and should be present even in a bare chroot.
# This is better than just using
#     FOO = "$(cd $FOO ; pwd)"
# since that leaves symbolic links intact.
# Note that 'realpath' is equivalent to 'readlink -f'.
TOP_SCRIPT_DIR=`readlink -f $TOP_SCRIPT_DIR`
GCLIENT_ROOT=`readlink -f $GCLIENT_ROOT`

# Other directories should always be pathed down from GCLIENT_ROOT.
SRC_ROOT="$GCLIENT_ROOT/src"
SRC_INTERNAL="$GCLIENT_ROOT/src-internal"
SCRIPTS_DIR="$SRC_ROOT/scripts"

# Load developer's custom settings.  Default location is in scripts dir,
# since that's available both inside and outside the chroot.  By convention,
# settings from this file are variables starting with 'CHROMEOS_'
CHROMEOS_DEV_SETTINGS="${CHROMEOS_DEV_SETTINGS:-$SCRIPTS_DIR/.chromeos_dev}"
if [ -f $CHROMEOS_DEV_SETTINGS ]
then
  # Turn on exit-on-error during custom settings processing
  SAVE_OPTS=`set +o`
  set -e

  # Read settings
  . $CHROMEOS_DEV_SETTINGS

  # Restore previous state of exit-on-error
  eval "$SAVE_OPTS"
fi

# Load shflags
if [[ -f /usr/lib/shflags ]]; then
  . /usr/lib/shflags
elif [ -f ./lib/shflags/shflags ]; then
  . "./lib/shflags/shflags"
else
  . "${SRC_ROOT}/scripts/lib/shflags/shflags"
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
if [ -d $SRC_ROOT/overlays ]; then
  ALL_BOARDS=$(cd $SRC_ROOT/overlays;ls -1d overlay-* 2>&-|sed 's,overlay-,,g')
fi
# Strip CR
ALL_BOARDS=$(echo $ALL_BOARDS)
# Set a default BOARD
#DEFAULT_BOARD=x86-generic # or...
DEFAULT_BOARD=$(echo $ALL_BOARDS | awk '{print $NF}')

# Enable --fast by default.
DEFAULT_FAST="${FLAGS_TRUE}"

# Detect whether we're inside a chroot or not
if [ -e /etc/debian_chroot ]
then
  INSIDE_CHROOT=1
else
  INSIDE_CHROOT=0
fi

# Directory locations inside the dev chroot
CHROOT_TRUNK_DIR="/home/$USER/trunk"

# Install make for portage ebuilds.  Used by build_image and gmergefs.
# TODO: Is /usr/local/autotest-chrome still used by anyone?
DEFAULT_INSTALL_MASK="/usr/include /usr/man /usr/share/man /usr/share/doc \
  /usr/share/gtk-doc /usr/share/gtk-2.0 /usr/lib/gtk-2.0/include \
  /usr/share/info /usr/share/aclocal /usr/lib/gcc /usr/lib/pkgconfig \
  /usr/share/pkgconfig /usr/share/gettext /usr/share/readline /etc/runlevels \
  /usr/share/openrc /lib/rc *.a *.la /etc/init.d /usr/lib/debug
  /usr/local/autotest /usr/local/autotest-chrome"

FACTORY_INSTALL_MASK="/opt/google/chrome /opt/google/o3d /opt/netscape \
  /opt/google/talkplugin /opt/Qualcomm /opt/Synaptics \
  /usr/lib/dri /usr/lib/python2.6/test \
  /usr/share/chewing /usr/share/fonts \
  /usr/share/ibus-pinyin /usr/share/libhangul /usr/share/locale \
  /usr/share/m17n /usr/share/mime /usr/share/sounds /usr/share/tts \
  /usr/share/X11 /usr/share/zoneinfo /usr/lib/debug
  /usr/local/autotest /usr/local/autotest-chrome /usr/local/autotest-pkgs"

# Check to ensure not running old scripts
V_REVERSE='[7m'
V_VIDOFF='[m'
case "$(basename $0)" in
  build_image.sh|build_platform_packages.sh|customize_rootfs.sh|make_chroot.sh)
  echo
  echo "$V_REVERSE============================================================"
  echo "===========================  WARNING  ======================"
  echo "============================================================$V_VIDOFF"
  echo
  echo "RUNNING OLD BUILD SYSTEM SCRIPTS. RUN THE PORTAGE-BASED BUILD HERE:"
  echo "http://www.chromium.org/chromium-os/building-chromium-os/portage-based-build"
  echo
  if [ "$USER" != "chrome-bot" ]
  then
    read -n1 -p "Press any key to continue using the OLD build system..."
    echo
    echo
  fi
  ;;
esac

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
    DEFAULT_BOARD=`cat "$GCLIENT_ROOT/src/scripts/.default_board"`
  fi
}


# Make a package
function make_pkg_common {
  # Positional parameters from calling script.  :? means "fail if unset".
  set -e
  PKG_BASE=${1:?}
  shift
  set +e

  # All packages are built in the chroot
  assert_inside_chroot

  # Command line options
  DEFINE_string build_root "$DEFAULT_BUILD_ROOT" "Root of build output"

  # Parse command line and update positional args
  FLAGS "$@" || exit 1
  eval set -- "${FLAGS_ARGV}"

  # Die on any errors
  set -e

  # Make output dir
  OUT_DIR="$FLAGS_build_root/x86/local_packages"
  mkdir -p "$OUT_DIR"

  # Remove previous package from output dir
  rm -f "$OUT_DIR"/${PKG_BASE}_*.deb

  # Rebuild the package
  pushd "$TOP_SCRIPT_DIR"
  rm -f ../${PKG_BASE}_*.deb
  dpkg-buildpackage -b -tc -us -uc -j$NUM_JOBS
  mv ../${PKG_BASE}_*.deb "$OUT_DIR"
  rm ../${PKG_BASE}_*.changes
  popd
}

# Enter a chroot and restart the current script if needed
function restart_in_chroot_if_needed {
  # NB:  Pass in ARGV:  restart_in_chroot_if_needed "$@"
  if [ $INSIDE_CHROOT -ne 1 ]
  then
    # Equivalent to enter_chroot.sh -- <current command>
    exec $SCRIPTS_DIR/enter_chroot.sh -- \
      $CHROOT_TRUNK_DIR/src/scripts/$(basename $0) "$@"
  fi
}

# Fail unless we're inside the chroot.  This guards against messing up your
# workstation.
function assert_inside_chroot {
  if [ $INSIDE_CHROOT -ne 1 ]
  then
    echo "This script must be run inside the chroot.  Run this first:"
    echo "    $SCRIPTS_DIR/enter_chroot.sh"
    exit 1
  fi
}

# Fail if we're inside the chroot.  This guards against creating or entering
# nested chroots, among other potential problems.
function assert_outside_chroot {
  if [ $INSIDE_CHROOT -ne 0 ]
  then
    echo "This script must be run outside the chroot."
    exit 1
  fi
}

function assert_not_root_user {
  if [ `id -u` = 0 ]; then
    echo "This script must be run as a non-root user."
    exit 1
  fi
}

# Install a package if it's not already installed
function install_if_missing {
  # Positional parameters from calling script.  :? means "fail if unset".
  PKG_NAME=${1:?}
  shift

  if [ -z `which $PKG_NAME` ]
  then
    echo "Can't find $PKG_NAME; attempting to install it."
    sudo apt-get --yes --force-yes install $PKG_NAME
  fi
}

# Returns true if the input file is whitelisted.
#
# $1 - The file to check
is_whitelisted() {
  local file=$1
  local whitelist="$FLAGS_whitelist"
  test -f "$whitelist" || (echo "Whitelist file missing ($whitelist)" && exit 1)

  local checksum=$(md5sum "$file" | awk '{ print $1 }')
  local count=$(sed -e "s/#.*$//" "${whitelist}" | grep -c "$checksum" \
                || /bin/true)
  test $count -ne 0
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

V_RED="\e[31m"
V_YELLOW="\e[33m"
V_BOLD_GREEN="\e[1;32m"
V_BOLD_RED="\e[1;31m"
V_BOLD_YELLOW="\e[1;33m"

function info {
  echo -e >&2 "${V_BOLD_GREEN}INFO   : $1${V_VIDOFF}"
}

function warn {
  echo -e >&2 "${V_BOLD_YELLOW}WARNING: $1${V_VIDOFF}"
}

function error {
  echo -e >&2   "${V_BOLD_RED}ERROR  : $1${V_VIDOFF}"
}

function die {
  error "$1"
  exit 1
}

# Retry an emerge command according to $FLAGS_retries
# The $EMERGE_JOBS flags will only be added the first time the command is run
function eretry () {
  local i=
  for i in $(seq $FLAGS_retries); do
    echo Retrying $*
    $* $EMERGE_JOBS && return 0
  done
  $* && return 0
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

# Unmounts a directory, if the unmount fails, warn, and then lazily unmount.
#
# $1 - The path to unmount.
function safe_umount {
  path=${1:?}
  shift

  if ! sudo umount -d "${path}"; then
    warn "Failed to unmount ${path}"
    warn "Doing a lazy unmount"

    sudo umount -d -l "${path}" || die "Failed to lazily unmount ${path}"
  fi
}

# Fixes symlinks that are incorrectly prefixed with the build root ${1}
# rather than the real running root '/'.
# TODO(sosa) - Merge setup - cleanup below with this method.
fix_broken_symlinks() {
  local build_root="${1}"
  local symlinks=$(find "${build_root}/usr/local" -lname "${build_root}/*")
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
  for path in usr local; do
    if [ -h "${dev_image_root}/${path}" ]; then
      sudo unlink "${dev_image_root}/${path}"
    elif [ -e "${dev_image_root}/${path}" ]; then
      die "${dev_image_root}/${path} should be a symlink if exists"
    fi
    sudo ln -s ${dev_image_target} "${dev_image_root}/${path}"
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
  end_time=$(date +%s)
  elapsed_seconds="$(( $end_time - $start_time ))"
  minutes="$(( $elapsed_seconds / 60 ))"
  seconds="$(( $elapsed_seconds % 60 ))"
  echo "Elapsed time: ${minutes}m${seconds}s"
}

# This function is a place to put code to incrementally update the
# chroot so that users don't need to fully re-make it.  It should
# be called from scripts that are run _outside_ the chroot.
#
# Please put date information so it's easy to keep track of when
# old hacks can be retired and so that people can detect when a
# hack triggered when it shouldn't have.
#
# ${1} specifies the location of the chroot.
chroot_hacks_from_outside() {
  # Give args better names.
  local chroot_dir="${1}"

  # Add root as a sudoer if not already done.
  if ! sudo grep -q '^root ALL=(ALL) ALL$' "${chroot_dir}/etc/sudoers" ; then
    info "Upgrading old chroot (pre 2010-10-19) - adding root to sudoers"
    sudo bash -c "echo root ALL=\(ALL\) ALL >> \"${chroot_dir}/etc/sudoers\""
  fi
}
