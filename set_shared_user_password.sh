#!/bin/bash

# Copyright (c) 2009 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Script to set the password for the shared user account.  Stores the
# MD5crypt'd password to a file, for use by customize_rootfs.sh.

# Load common constants.  This should be the first executable line.
# The path to common.sh should be relative to your script's location.
. "$(dirname "$0")/common.sh"

# Script must be run inside the chroot
assert_inside_chroot

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
