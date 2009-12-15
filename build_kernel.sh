#! /bin/sh

# Copyright (c) 2009 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# This script contains the set of commands to build a kernel package.
#
# If successful, a new linux-image-*.deb file will appear in the specified
# output directory.
#
# The user-provided kernel config file is parsed to obtain information about
# the desired kernel version and target platform. Here are the requirements:
# 1) Kernel version string in the header, e.g. "Linux kernel version: 2.6.30"
# 2) Target architecture variables set up, e.g. CONFIG_X86, CONFIG_ARM, etc.
# 3) LOCALVERSION set to describe target platform (e.g. intel-menlow). This is
#    used for package naming.
SRC_ROOT=$(dirname $(readlink -f $(dirname "$0")))
. "${SRC_ROOT}/third_party/shflags/files/src/shflags"

KERNEL_DIR="$SRC_ROOT/third_party/kernel"
DEFAULT_KCONFIG="${KERNEL_DIR}/files/chromeos/config/chromeos-intel-menlow"

CROSS_COMPILE_FLAG=""
VERBOSE_FLAG=""

# Flags
DEFAULT_BUILD_ROOT=${BUILD_ROOT:-"${SRC_ROOT}/build"}
DEFINE_string config "${DEFAULT_KCONFIG}"                              \
  "The kernel configuration file to use."
DEFINE_integer revision 002                                            \
  "The package revision to use"
DEFINE_string output_root ""   \
  "Directory in which to place the resulting .deb package"
DEFINE_string build_root "$DEFAULT_BUILD_ROOT"                         \
  "Root of build output"
DEFINE_string cross_compile "" \
  "Prefix for cross compile build tools"
DEFINE_boolean verbose $FLAGS_FALSE "Print debugging information in addtion to normal processing."
FLAGS_HELP="Usage: $0 [flags]" 

# Parse command line
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

# Die on any errors.
set -e

# Get kernel package configuration from repo.
# TODO: Find a workaround for needing sudo for this. Maybe create a symlink
# to /tmp/kernel-pkg.conf when setting up the chroot env?
sudo cp "$KERNEL_DIR"/package/kernel-pkg.conf /etc/kernel-pkg.conf

# Parse kernel config file for target architecture information. This is needed
# to determine the full package name and also to setup the environment for
# kernel build scripts which use "uname -m" to autodetect architecture.
KCONFIG=`readlink -f "$FLAGS_config"`
if [ ! -f "$KCONFIG" ]; then
    KCONFIG="$KERNEL_DIR"/files/chromeos/config/"$KCONFIG"
fi
if [  $(grep 'CONFIG_X86=y' "$KCONFIG") ]
then
    ARCH="i386"
elif [ $(grep 'CONFIG_X86_64=y' "$KCONFIG") ]
then
    ARCH="x86_64"
elif [ $(grep 'CONFIG_ARM=y' "$KCONFIG") ]
then
    ARCH="armel"
    KPKG_ARCH=arm
else
    exit 1
fi

if [ ! $FLAGS_output_root ]
then
    FLAGS_output_root="${DEFAULT_BUILD_ROOT}/${ARCH}/local_packages" 
fi

# TODO: We detect the ARCH below. We can sed the FLAGS_output_root to replace
# an ARCH placeholder with the proper architecture rather than assuming x86.
mkdir -p "$FLAGS_output_root"

# Parse the config file for a line with "version" in it (in the header)
# and remove any leading text before the major number of the kernel version
FULLVERSION=$(sed -e '/version/ !d' -e 's/^[^0-9]*//' $KCONFIG)

# FULLVERSION should have the form "2.6.30-rc1-chromeos-asus-eeepc". In this
# example MAJOR is 2, MINOR is 6, EXTRA is 30, RELEASE is rc1, LOCAL is
# asus-eeepc. RC is optional since it only shows up for release candidates.
MAJOR=$(echo $FULLVERSION | sed -e 's/[^0-9].*//')
MIDDLE=$(echo $FULLVERSION | sed -e 's/[0-9].//' -e 's/[^0-9].*//')
MINOR=$(echo $FULLVERSION | sed -e 's/[0-9].//' -e 's/[0-9].//' -e 's/[^0-9].*//')
EXTRA=$(echo $FULLVERSION | sed -e 's/[0-9].//' -e 's/[0-9].//' -e 's/[0-9]*.//' -e 's/[^0-9].*//')
if [ ! -z $EXTRA ]; then
    VER_MME="${MAJOR}.${MIDDLE}.${MINOR}.${EXTRA}"
else
    VER_MME="${MAJOR}.${MIDDLE}.${MINOR}"
fi

LOCAL=$(sed -e '/CONFIG_LOCALVERSION=/ !d' -e 's/.*="-//' -e 's/"//' $KCONFIG)
RC=$(echo $FULLVERSION | sed -r \
   "s/${VER_MME}-([^-]*)-*${LOCAL}/\1/")

# The tag will be appended by make-kpkg to the extra version and will show up
# in both the kernel and package names.
CHROMEOS_TAG="chromeos"
PACKAGE="linux-image-${VER_MME}-${CHROMEOS_TAG}-${LOCAL}_${FLAGS_revision}_${ARCH}.deb"

# Set up kernel source tree and prepare to start the compilation.
# TODO: Decide on proper working directory when building kernels. It should
# be somewhere under ${BUILD_ROOT}.
SRCDIR="${FLAGS_build_root}/kernels/kernel-${ARCH}-${LOCAL}"
rm -rf "$SRCDIR"
mkdir -p "$SRCDIR"
cd "$SRCDIR"

# Get kernel sources
# TODO(msb): uncomment once git is available in the chroot
#   git clone "${KERNEL_DIR}"/linux_${VER_MME}
mkdir linux-${VER_MME}
cd "linux-$VER_MME"
cp -a "${KERNEL_DIR}"/files/* .

# Move kernel config to kernel source tree and rename to .config so that
# it can be used for "make oldconfig" by make-kpkg.
cp "$KCONFIG" .config

# Remove stale packages. make-kpkg will dump the package in the parent
# directory. From there, it will be moved to the output directory.
rm -f "../${PACKAGE}"
rm -f "${FLAGS_output_root}"/linux-image-*.deb

# Speed up compilation by running parallel jobs.
if [ ! -e "/proc/cpuinfo" ]
then
    # default to a reasonable level
    CONCURRENCY_LEVEL=2
else
    # speed up compilation by running #cpus * 2 simultaneous jobs
    CONCURRENCY_LEVEL=$(($(cat /proc/cpuinfo | grep "processor" | wc -l) * 2))
fi

# Setup the cross-compilation environment, if necessary, using the cross_compile
# Flag from the command line
if [ $FLAGS_cross_compile ]
then
    CROSS_COMPILE_FLAG="--cross-compile $FLAGS_cross_compile"
fi

if [ $FLAGS_verbose -eq $FLAGS_TRUE ]
then
    VERBOSE_FLAG="--verbose"
fi

# Build the kernel and make package. "setarch" is used so that scripts which
# detect architecture (like the "oldconfig" rule in kernel Makefile) don't get
# confused when cross-compiling.
make-kpkg clean

# Setarch does not support arm, so if we are compiling for arm we need to 
# make sure that uname -m will return the appropriate architeture. 
if [ ! -n "$(setarch $ARCH ls)" ]
then
    alias uname="echo $ARCH"
    SETARCH=""
else
    SETARCH="setarch $ARCH"
fi

MAKEFLAGS="CONCURRENCY_LEVEL=$CONCURRENCY_LEVEL" \
          $SETARCH \
          make-kpkg \
          $VERBOSE_FLAG \
          $CROSS_COMPILE_FLAG \
          --append-to-version="-$CHROMEOS_TAG" --revision="$FLAGS_revision" \
          --arch="$ARCH" \
          --rootcmd fakeroot \
          --config oldconfig \
          --initrd --bzImage kernel_image

# make-kpkg dumps the newly created package in the parent directory
if [ -e "../${PACKAGE}" ]
then
    mv "../${PACKAGE}" "${FLAGS_output_root}"
    echo "Kernel build successful, check ${FLAGS_output_root}/${PACKAGE}"
else
    echo "Kernel build failed"
    exit 1
fi
