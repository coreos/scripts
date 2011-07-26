# Copyright (c) 2011 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Common library file to be sourced by build_image,
# mod_image_for_test.sh, and mod_image_for_recovery.sh.  This
# file ensures that library source files needed by all the scripts
# are included once, and also takes care of certain bookeeping tasks
# common to all the scripts.

# SCRIPT_ROOT must be set prior to sourcing this file
. "${SCRIPT_ROOT}/common.sh" || exit 1

# All scripts using this file must be run inside the chroot.
restart_in_chroot_if_needed "$@"

INSTALLER_ROOT=/usr/lib/installer
. "${INSTALLER_ROOT}/chromeos-common.sh" || exit 1

BUILD_LIBRARY_DIR=${SCRIPTS_DIR}/build_library
locate_gpt
get_default_board
