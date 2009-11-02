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

KERNEL_VERSION=${KERNEL_VERSION:-"2.6.30-chromeos-intel-menlow"}

# Flags
DEFAULT_BUILD_ROOT=${BUILD_ROOT:-"${SRC_ROOT}/build"}
DEFINE_string config "config.${KERNEL_VERSION}"                        \
  "The kernel configuration file to use. See src/platform/kernel/config/*"
DEFINE_integer revision 002                                            \
  "The package revision to use"
DEFINE_string output_root "${DEFAULT_BUILD_ROOT}/x86/local_packages"   \
  "Directory in which to place the resulting .deb package"
DEFINE_string build_root "$DEFAULT_BUILD_ROOT"                         \
  "Root of build output"
FLAGS_HELP="Usage: $0 [flags] <deb_patch1> <deb_patch2> ..."

# Parse command line
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

# Die on any errors.
set -e

KERNEL_DIR="$SRC_ROOT/third_party/kernel"
KCONFIG="${KERNEL_DIR}/config/${FLAGS_config}"

# TODO: We detect the ARCH below. We can sed the FLAGS_output_root to replace
# an ARCH placeholder with the proper architecture rather than assuming x86.
mkdir -p "$FLAGS_output_root"

# Use remaining arguments passed into the script as patch names. These are
# for non-chromeos debian-style patches. The chromeos patches will be applied
# manually below.
PATCHES="$*"

# Get kernel package configuration from repo.
# TODO: Find a workaround for needing sudo for this. Maybe create a symlink
# to /tmp/kernel-pkg.conf when setting up the chroot env?
sudo cp "$KERNEL_DIR"/package/kernel-pkg.conf /etc/kernel-pkg.conf

# Parse kernel config file for target architecture information. This is needed
# to determine the full package name and also to setup the environment for
# kernel build scripts which use "uname -m" to autodetect architecture.
if [ -n $(grep 'CONFIG_X86=y' "$KCONFIG") ]
then
    ARCH="i386"
elif [ -n $(grep 'CONFIG_X86_64=y' "$KCONFIG") ]
then
    ARCH="x86_64"
elif [ -n $(grep 'CONFIG_ARM=y' "$KCONFIG") ]
then
    ARCH="arm"
else
    exit 1
fi

# Parse the config file for a line with "version" in it (in the header)
# and remove any leading text before the major number of the kernel version
FULLVERSION=$(sed -e '/version/ !d' -e 's/^[^0-9]*//' $KCONFIG)

# FULLVERSION should have the form "2.6.30-rc1-chromeos-asus-eeepc". In this
# example MAJOR is 2, MINOR is 6, EXTRA is 30, RELEASE is rc1, LOCAL is
# asus-eeepc. RC is optional since it only shows up for release candidates.
MAJOR=$(echo $FULLVERSION | sed -e 's/[^0-9].*//')
MINOR=$(echo $FULLVERSION | sed -e 's/[0-9].//' -e 's/[^0-9].*//')
EXTRA=$(echo $FULLVERSION | sed -e 's/[0-9].//' -e 's/[0-9].//' -e 's/[^0-9].*//')
VER_MME="${MAJOR}.${MINOR}.${EXTRA}"
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

# Get kernel sources and patches.
if [ -d ${KERNEL_DIR}/linux-${VER_MME} ]; then
# TODO(msb): uncomment once git is available in the chroot
#   git clone "${KERNEL_DIR}"/linux_${VER_MME}
    cp -a "${KERNEL_DIR}"/linux-${VER_MME} .
else
    # old way...
# TODO: find a better source for the kernel source.  Old versions of karmic
# aren't hosted on archive.ubuntu.com
#apt-get source linux-source-$MAJOR.$MINOR.$EXTRA
# Name directory to what the patches expect
    mkdir linux-${VER_MME}
    cp -a "${KERNEL_DIR}"/files/* linux-${VER_MME}

    if [ ! -z $PATCHES ]
    then
        # TODO: Get rid of sudo if possible. Maybe the non-chromeos kernel
	# patches will be infrequent enough that we can make them part of
	# the chroot env?
        sudo apt-get install $PATCHES
    fi

    # Apply chromeos patches
    CHROMEOS_PATCHES=`ls "$KERNEL_DIR"/patches/*.patch`
    for i in ${CHROMEOS_PATCHES}
    do
      patch -d "linux-$VER_MME" -p1 < "$i"
    done

    # TODO: Remove a config option which references a non-existent directory in
    # ubuntu kernel sources.
    sed -i '/gfs/ d' linux-$VER_MME/ubuntu/Makefile
fi

# Move kernel config to kernel source tree and rename to .config so that
# it can be used for "make oldconfig" by make-kpkg.
cp "$KCONFIG" "linux-${VER_MME}/.config"
cd "linux-$VER_MME"

# Remove stale packages. make-kpkg will dump the package in the parent
# directory. From there, it will be moved to the output directory.
rm -f "../${PACKAGE}"
rm -f "${FLAGS_output_root}/${PACKAGE}"

# Speed up compilation by running parallel jobs.
if [ ! -e "/proc/cpuinfo" ]
then
    # default to a reasonable level
    CONCURRENCY_LEVEL=2
else
    # speed up compilation by running #cpus * 2 simultaneous jobs
    CONCURRENCY_LEVEL=$(($(cat /proc/cpuinfo | grep "processor" | wc -l) * 2))
fi

# The patch listing will be added into make-kpkg with --added-patches flag.
# We need to change the formatting so they are a comma-separated values list
# rather than whitespace separated.
PATCHES_CSV=$(echo $PATCHES | sed -e 's/ \{1,\}/,/g' | sed -e 's/,$//')

# Build the kernel and make package. "setarch" is used so that scripts which
# detect architecture (like the "oldconfig" rule in kernel Makefile) don't get
# confused when cross-compiling.
make-kpkg clean
MAKEFLAGS="CONCURRENCY_LEVEL=$CONCURRENCY_LEVEL" \
          setarch $ARCH make-kpkg \
          --append-to-version="-$CHROMEOS_TAG" --revision="$FLAGS_revision" \
          --arch="$ARCH" \
          --rootcmd fakeroot \
          --config oldconfig \
          --initrd --bzImage kernel_image \
          --added-patches "$PATCHES_CSV"

# make-kpkg dumps the newly created package in the parent directory
if [ -e "../${PACKAGE}" ]
then
    mv "../${PACKAGE}" "${FLAGS_output_root}"
    echo "Kernel build successful, check ${FLAGS_output_root}/${PACKAGE}"
else
    echo "Kernel build failed"
    exit 1
fi
