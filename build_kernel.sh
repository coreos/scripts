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
KERNEL_FDIR="$KERNEL_DIR/files"
DEFAULT_KFLAVOUR="chromeos-intel-menlow"

# Flags
DEFAULT_BUILD_ROOT=${BUILD_ROOT:-"${SRC_ROOT}/build"}
DEFINE_string flavour "${DEFAULT_KFLAVOUR}"                              \
  "The kernel flavour to build."
DEFINE_string output_root "${DEFAULT_BUILD_ROOT}/x86/local_packages"   \
  "Directory in which to place the resulting .deb package"
DEFINE_string build_root "$DEFAULT_BUILD_ROOT"                         \
  "Root of build output"
FLAGS_HELP="Usage: $0 [flags]"

# Parse command line
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

# Die on any errors.
set -e

# TODO: We detect the ARCH below. We can sed the FLAGS_output_root to replace
# an ARCH placeholder with the proper architecture rather than assuming x86.
mkdir -p "$FLAGS_output_root"

# Set up kernel source tree and prepare to start the compilation.
# TODO: Decide on proper working directory when building kernels. It should
# be somewhere under ${BUILD_ROOT}.
SRCDIR="${FLAGS_build_root}/kernels/kernel-${FLAGS_flavour}"
rm -rf "$SRCDIR"
mkdir -p "$SRCDIR"
cp -a "${KERNEL_FDIR}"/* "$SRCDIR"
cd "$SRCDIR"

#
# Build the config file
#
fakeroot debian/rules clean prepare-$FLAGS_flavour

# Parse kernel config file for target architecture information. This is needed
# to setup the environment for kernel build scripts which use "uname -m" to autodetect architecture.
KCONFIG="$SRCDIR/debian/build/build-$FLAGS_flavour/.config"
if [ ! -f "$KCONFIG" ]; then
    echo Total bummer. No config file was created.
    exit 1
fi
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
FULLVERSION=$(dpkg-parsechangelog -l$SRCDIR/debian.chrome/changelog|grep "Version:"|sed 's/^Version: //')

# linux-image-2.6.31-0-chromeos-intel-menlow_2.6.31-0.1_i386.deb
# FULLVERSION has the form "2.6.3x-ABI-MINOR" where x is {1,2}, ABI and MINOR are an integers.
#In this example MAJOR is 2.6.31, ABI is 0, MINOR is 1
MAJOR=$(echo $FULLVERSION | sed -e 's/\(^.*\)-.*$/\1/')
ABI=$(echo $FULLVERSION | sed 's/^.*-\(.*\)\..*$/\1/')
MINOR=$(echo $FULLVERSION | sed -e 's/^.*\.\([0-9]*$\)/\1/')
PACKAGE="linux-image-${MAJOR}-${ABI}-${FLAGS_flavour}_${MAJOR}-${ABI}.${MINOR}_${ARCH}.deb"

echo MAJOR $MAJOR
echo ABI $ABI
echo MINOR $MINOR
echo PACKAGE $PACKAGE


# Remove stale packages. debian/rules will dump the package in the parent
# directory. From there, it will be moved to the output directory.
rm -f "../${PACKAGE}"
rm -f "${FLAGS_output_root}"/linux-image-*.deb

# Build the kernel package.
fakeroot debian/rules binary-debs flavours=${FLAGS_flavour}

# debian/rules dumps the newly created package in the parent directory
if [ -e "../${PACKAGE}" ]
then
    mv "../${PACKAGE}" "${FLAGS_output_root}"
    echo "Kernel build successful, check ${FLAGS_output_root}/${PACKAGE}"
else
    echo "Kernel build failed"
    exit 1
fi
