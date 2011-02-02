#!/bin/bash
# Copyright (c) 2010 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.
set -e

if [ -z $1 ]; then
  echo "Usage: $0 localaccount_username [chroot_path]"
  exit 1
fi

# Default chroot_path to its standard location
chroot_path=${2:-"../../chroot"}

echo "Enabling local account $1@gmail.com."

# Add CHROMEOS_LOCAL_ACCOUNT var to /etc/make.conf.user
echo "Setting CHROMEOS_LOCAL_ACCOUNT in $chroot_path/etc/make.conf.user..."
VAR_NAME=CHROMEOS_LOCAL_ACCOUNT
if grep -q ${VAR_NAME} $chroot_path/etc/make.conf.user; then
   regex="s/${VAR_NAME}=.*/${VAR_NAME}=$1@gmail.com/"
   sudo sed -i -e "${regex}"  $chroot_path/etc/make.conf.user
else
   sudo sh -c "echo ""${VAR_NAME}=$1@gmail.com"" >> \
               $chroot_path/etc/make.conf.user"
fi
