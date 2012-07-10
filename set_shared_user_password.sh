#!/bin/bash

# Copyright (c) 2011 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Script to set the password for the shared user account. Stores the MD5crypt'd
# password to a file inside chroot, for use by build_image.

# This can only run inside the chroot.
. "$(dirname "$0")/common.sh" || exit 1

# Die on any errors.
switch_to_strict_mode

SHARED_USER_PASSWD_FILE="/etc/shared_user_passwd.txt"

# Get password
read -p "Enter password for shared user account: " PASSWORD

CRYPTED_PASSWD="$(echo "$PASSWORD" | openssl passwd -1 -stdin)"
PASSWORD="gone now"

echo "${CRYPTED_PASSWD}" | sudo_clobber "${SHARED_USER_PASSWD_FILE}"
echo "Password set in ${SHARED_USER_PASSWD_FILE}"
