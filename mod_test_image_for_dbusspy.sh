#!/bin/bash

# Copyright (c) 2012 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Script to modify a keyfob-based chromeos test image to log all dbus
# activity from boot-time forward in a machine-readable replay format.
# This is not part of the main "mod-for-test" for several reasons:
# * it is overly invasive to the boot sequence,
# * it has major run-time performance downsides,
# * it consumes potentially huge amounts of disk space over time.
# Any one of these are too-great of a depature from "normal" Chrome OS
# to be appropriate for a "faithful" test-system. Note that dbus-monitor(1)
# is available for casual/interactive use in normal mod-for-test systems.
# Dbusspy-instrumented systems are only intended for narrow use cases, like
# corpus collection for fuzzing, where the above trade-offs are acceptable.

. "$(dirname "$0")/common.sh" || exit 1

assert_inside_chroot

DEFINE_string image "$FLAGS_image" "Location of the test image file" i

# Parse command line
FLAGS "$@" || exit 1
eval set -- "$FLAGS_ARGV"

FLAGS_image=$(eval readlink -f "${FLAGS_image}")

IMAGE_DIR=$(dirname "${FLAGS_image}")
IMAGE_NAME=$(basename "${FLAGS_image}")
ROOT_FS_DIR="${IMAGE_DIR}/rootfs"
DBUS_CONF="$(dirname "$0")/mod_for_dbusspy/dbus.conf"
SYSTEM_LOCAL_CONF="$(dirname "$0")/mod_for_dbusspy/system-local.conf"
DEVKEYS_DIR="/usr/share/vboot/devkeys"
VBOOT_DIR="${CHROOT_TRUNK_DIR}/src/platform/vboot_reference/scripts/"\
"image_signing"

cleanup() {
  "${SCRIPTS_DIR}/mount_gpt_image.sh" -u -r "$ROOT_FS_DIR"
}

if [ ! -d "$VBOOT_DIR" ]; then
  die_notrace \
      "The required path: $VBOOT_DIR does not exist.  This directory needs"\
      "to be sync'd into your chroot.\n $ cros_workon start vboot_reference"
fi

trap cleanup EXIT

# Mounts gpt image and sets up var, /usr/local and symlinks.
"$SCRIPTS_DIR/mount_gpt_image.sh" --image="$IMAGE_NAME" --from="$IMAGE_DIR" \
  --rootfs_mountpt="$ROOT_FS_DIR"

# A bunch of existing stuff is set to start up as soon as dbus is considered
# to have started. Instead of modifying all of those things to instead
# wait for dbus-spy to be started, drop dbus-spy in as "dbus" which,
# in turn, waits on "realdbus." This way we don't race other services
# and are guaranteed to capture all dbus events from boot onward.
sudo cp -a "${ROOT_FS_DIR}/etc/init/dbus.conf" \
  "${ROOT_FS_DIR}/etc/init/realdbus.conf"
sudo cp "${DBUS_CONF}" "${ROOT_FS_DIR}/etc/init/dbus.conf"
sudo cp "${SYSTEM_LOCAL_CONF}" "${ROOT_FS_DIR}/etc/dbus-1/system-local.conf"

# Unmount and re-sign. See crosbug.com/18709 for why this isn't using
# cros_make_image_bootable.
cleanup
TMP_BIN_PATH="${FLAGS_image}.new"
"${VBOOT_DIR}/sign_official_build.sh" usb "${FLAGS_image}" \
                                     "${DEVKEYS_DIR}" \
                                     "${TMP_BIN_PATH}"
mv "${TMP_BIN_PATH}" "${FLAGS_image}"
