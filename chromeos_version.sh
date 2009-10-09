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

# Major/minor versions.  
# Primarily for product marketing.
export CHROMEOS_VERSION_MAJOR=0
export CHROMEOS_VERSION_MINOR=2

# Branch number.
# Increment by 1 in a new release branch.
# Increment by 2 in trunk after making a release branch.
# Does not reset on a major/minor change (always increases).
# (Trunk is always odd; branches are always even).
export CHROMEOS_VERSION_BRANCH=13

# Patch number.
# Increment by 1 each release on a branch.
# Reset to 0 when increasing branch number.
export CHROMEOS_VERSION_PATCH=0

# Codename of this version
export CHROMEOS_VERSION_CODENAME="Indy"

# Version string
export CHROMEOS_VERSION_STRING=\
"${CHROMEOS_VERSION_MAJOR}.${CHROMEOS_VERSION_MINOR}"\
".${CHROMEOS_VERSION_BRANCH}.${CHROMEOS_VERSION_PATCH}"

# Official builds must set 
#   CHROMEOS_OFFICIAL=1 
#   CHROMEOS_REVISION=(the subversion revision being built).  
# Note that ${FOO:-0} means default-to-0-if-unset; ${FOO:?} means die-if-unset.
if [ ${CHROMEOS_OFFICIAL:-0} -eq 1 ]
then
  # Official builds (i.e., buildbot)
  export CHROMEOS_VERSION_NAME="Chrome OS"
  export CHROMEOS_VERSION_TRACK="dev-channel"
  # CHROMEOS_REVISION must be set in the environment for official builds
  export CHROMEOS_VERSION_DESCRIPTION="${CHROMEOS_VERSION_STRING} (Official Build ${CHROMEOS_REVISION:?})" 
else
  # Continuous builds and developer hand-builds
  export CHROMEOS_VERSION_NAME="Chromium OS"
  export CHROMEOS_VERSION_TRACK="developer-build"
  export CHROMEOS_VERSION_DESCRIPTION="${CHROMEOS_VERSION_STRING} (Developer Build - $(date))"
fi

# Print version info
echo "ChromeOS version information:"
set | grep "CHROMEOS_VERSION" | sed 's/^/    /'
