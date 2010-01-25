#!/bin/bash

# Copyright (c) 2010 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Load common constants.  This should be the first executable line.
# The path to common.sh should be relative to your script's location.
. "$(dirname "$0")/common.sh"

assert_inside_chroot
assert_not_root_user

# Flags
DEFINE_string architecture armel "The architecture to fetch." a

# Parse command line
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

# Die on error
set -e

LOCAL_PKG_DIR="${DEFAULT_BUILD_ROOT}/${FLAGS_architecture}/local_packages"

mkdir -p "${LOCAL_PKG_DIR}"
cd "${LOCAL_PKG_DIR}"

DEB_BUILD_ARCH="$(dpkg-architecture -qDEB_BUILD_ARCH)"

DEBS=
for SRC; do
  SRCCACHE="$(apt-cache showsrc "$SRC")"
  BINS="$(echo "$SRCCACHE" | grep -m1 ^Binary: | cut -d' ' -f2- | sed 's/,//g')"
  VER="$(echo "$SRCCACHE" | grep -m1 ^Version: | cut -d' ' -f2)"
  for BIN in $BINS; do
    BINCACHE="$(apt-cache show "$BIN")" || continue # might be a udeb
    DEB="$(echo "$BINCACHE" | grep -m1 ^Filename: | cut -d' ' -f2 | sed "s/_${DEB_BUILD_ARCH}\.deb/_${FLAGS_architecture}.deb/")"
    wget -N "http://ports.ubuntu.com/ubuntu-ports/${DEB}"
    DEBS="$DEBS ${DEB##*/}"
  done
  cat >"${SRC}_${VER#*:}_${FLAGS_architecture}.changes" <<EOF
Version: $VER
Fake: yes
EOF
done

if [ "$DEBS" ]; then
  chromiumos-build --convert -a "${FLAGS_architecture}" $DEBS
fi
