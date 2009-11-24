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

# Sets up a version number for release builds.
export_release_version() {
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
}

# Sets up a version for developer builds.
export_developer_version() {
  # Use an arbitrarily high number to indicate that this is a dev build.
  export CHROMEOS_VERSION_MAJOR=999

  # Use the SVN revision number of the tree here.
  # TODO(rtc): Figure out how to do this.
  export CHROMEOS_VERSION_MINOR=999

  # Use the day of year and two digit year.
  export CHROMEOS_VERSION_BRANCH=$(date +"%j%y")

  export CHROMEOS_VERSION_PATCH=$(date +"%H%M%S")

  # Sets the codename to the user who built the image. This
  # will help us figure out who did the build if a different
  # person is debugging the system.
  export CHROMEOS_VERSION_CODENAME="$USER"
}

export_version_string() {
# Version string. Not indentied to appease bash.
export CHROMEOS_VERSION_STRING=\
"${CHROMEOS_VERSION_MAJOR}.${CHROMEOS_VERSION_MINOR}"\
".${CHROMEOS_VERSION_BRANCH}.${CHROMEOS_VERSION_PATCH}"
}

# Official builds must set 
#   CHROMEOS_OFFICIAL=1 
#   CHROMEOS_REVISION=(the subversion revision being built).  
# Note that ${FOO:-0} means default-to-0-if-unset; ${FOO:?} means die-if-unset.
if [ ${CHROMEOS_OFFICIAL:-0} -eq 1 ]
then
  # Official builds (i.e., buildbot)
  export_release_version
  export_version_string
  export CHROMEOS_VERSION_NAME="Chrome OS"
  export CHROMEOS_VERSION_TRACK="dev-channel"
  export CHROMEOS_VERSION_AUSERVER="https://tools.google.com/service/update2"
  export CHROMEOS_VERSION_DEVSERVER=""
else
  # Continuous builds and developer hand-builds
  export_developer_version
  export_version_string
  export CHROMEOS_VERSION_NAME="Chromium OS"
  export CHROMEOS_VERSION_TRACK="developer-build"
  HOSTNAME=$(hostname)
  export CHROMEOS_VERSION_AUSERVER="http://$HOSTNAME:8080/update"
  export CHROMEOS_VERSION_DEVSERVER="http://$HOSTNAME:8080"
fi

# Print version info.
echo "ChromeOS version information:"
env | grep "^CHROMEOS_VERSION" | sed 's/^/    /'
