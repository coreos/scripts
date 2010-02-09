# Copyright (c) 2009 The Chromium OS Authors. All rights reserved.
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
. "$SRC_ROOT/third_party/shflags/files/src/shflags"

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

# Detect whether we're inside a chroot or not
if [ -e /etc/debian_chroot ]
then
  INSIDE_CHROOT=1
else
  INSIDE_CHROOT=0
fi

# Directory locations inside the dev chroot
CHROOT_TRUNK_DIR="/home/$USER/trunk"

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
