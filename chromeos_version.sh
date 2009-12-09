#!/bin/sh

# Copyright (c) 2009 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# ChromeOS version information
#
# This file is usually sourced by other build scripts, but can be run 
# directly to see what it would do.
#
# Version numbering scheme is much like Chrome's, with the addition of 
# double-incrementing branch number so trunk is always odd.

HOSTNAME=$(hostname)
#############################################################################
# SET VERSION NUMBERS
#############################################################################
# Major/minor versions.  
# Primarily for product marketing.
export CHROMEOS_VERSION_MAJOR=0
export CHROMEOS_VERSION_MINOR=5

# Branch number.
# Increment by 1 in a new release branch.
# Increment by 2 in trunk after making a release branch.
# Does not reset on a major/minor change (always increases).
# (Trunk is always odd; branches are always even).
export CHROMEOS_VERSION_BRANCH=23

# Patch number.
# Increment by 1 each release on a branch.
# Reset to 0 when increasing branch number.
export CHROMEOS_VERSION_PATCH=0

# Codename of this version.
export CHROMEOS_VERSION_CODENAME=""
 

#############################################################################
# SET VERSION STRINGS
#############################################################################
# Official builds must set 
#   CHROMEOS_OFFICIAL=1 
# Note that ${FOO:-0} means default-to-0-if-unset; ${FOO:?} means die-if-unset.
if [ ${CHROMEOS_OFFICIAL:-0} -eq 1 ]
then
  # Official builds (i.e., buildbot)
  export CHROMEOS_VERSION_NAME="Chrome OS"
  export CHROMEOS_VERSION_TRACK="dev-channel"
  export CHROMEOS_VERSION_AUSERVER="https://tools.google.com/service/update2"
  export CHROMEOS_VERSION_DEVSERVER=""
elif [ "$USER" = "chrome-bot" ]
then
  # Continuous builder
  # Sets the codename to the user who built the image. This
  # will help us figure out who did the build if a different
  # person is debugging the system.
  export CHROMEOS_VERSION_CODENAME="$USER"

  export CHROMEOS_VERSION_NAME="Chromium OS"
  export CHROMEOS_VERSION_TRACK="buildbot-build"
  export CHROMEOS_VERSION_AUSERVER="http://$HOSTNAME:8080/update"
  export CHROMEOS_VERSION_DEVSERVER="http://$HOSTNAME:8080"
else
  # Developer hand-builds
  # Sets the codename to the user who built the image. This
  # will help us figure out who did the build if a different
  # person is debugging the system.
  export CHROMEOS_VERSION_CODENAME="$USER"

  export CHROMEOS_VERSION_NAME="Chromium OS"
  export CHROMEOS_VERSION_TRACK="developer-build"
  export CHROMEOS_VERSION_AUSERVER="http://$HOSTNAME:8080/update"
  export CHROMEOS_VERSION_DEVSERVER="http://$HOSTNAME:8080"
fi

# Version string. Not indentied to appease bash.
export CHROMEOS_VERSION_STRING=\
"${CHROMEOS_VERSION_MAJOR}.${CHROMEOS_VERSION_MINOR}"\
".${CHROMEOS_VERSION_BRANCH}.${CHROMEOS_VERSION_PATCH}"

# Print version info.
echo "ChromeOS version information:"
env | egrep "^CHROMEOS_VERSION" | sed 's/^/    /'
