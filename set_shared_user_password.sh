#!/bin/bash

# Copyright (c) 2009 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Script to set the password for the shared user account.  Stores the
# MD5crypt'd password to a file, for use by customize_rootfs.sh.

# --- BEGIN COMMON.SH BOILERPLATE ---
# Load common CrOS utilities.  Inside the chroot this file is installed in
# /usr/lib/crosutils.  Outside the chroot we find it relative to the script's
# location.
find_common_sh() {
  local common_paths=(/usr/lib/crosutils $(dirname "$(readlink -f "$0")"))
  local path

  SCRIPT_ROOT=
  for path in "${common_paths[@]}"; do
    if [ -r "${path}/common.sh" ]; then
      SCRIPT_ROOT=${path}
      break
    fi
  done
}

find_common_sh
. "${SCRIPT_ROOT}/common.sh" || (echo "Unable to load common.sh" && exit 1)
# --- END COMMON.SH BOILERPLATE ---

# Script must be run inside the chroot
restart_in_chroot_if_needed "$@"

FLAGS_HELP="USAGE: $0 [flags]"

# Parse command line
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

# Die on any errors.
set -e

# Get password
read -p "Enter password for shared user account: " PASSWORD

CRYPTED_PASSWD_FILE=$SCRIPTS_DIR/shared_user_passwd.txt
CRYPTED_PASSWD="$(echo "$PASSWORD" | openssl passwd -1 -stdin)"
PASSWORD="gone now"

echo "$CRYPTED_PASSWD" > $CRYPTED_PASSWD_FILE

echo "Shared user password set in $CRYPTED_PASSWD_FILE"
