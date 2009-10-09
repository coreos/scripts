#!/bin/bash

# Copyright (c) 2009 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Print a list of installed packages
#
# This list is used by make_local_repo.sh to construct a local repository 
# with only those packages.
#
# Usage:
#    list_installed_packages.sh > package_list.txt

# Die on error
set -e

USAGE='usage: '"$0"' [options]

options:
  -v    Print verbose output.
  -?    Print this help.
'

# Handle command line options.
# Note: Can't use shflags, since this must run inside the rootfs image.
VERBOSE=0
# Option processing using getopts
while getopts "v?" OPTVAR
do
  case $OPTVAR in 
    "v") 
      VERBOSE=1 
      ;;
    "?") 
      echo "$USAGE"; 
      exit 1
      ;;
  esac
done
shift `expr $OPTIND - 1`

# Print information on a single package
function print_deb {
  # Positional parameters from calling script.  :? means "fail if unset".
  DEB_NAME=${1:?}

  # Get the installed version of the package.
  DEB_VER=`dpkg-query --show -f='${Version}' $DEB_NAME`

  # Get information on package from apt-cache.  Use a temporary file since
  # we need to extract multiple fields.
  rm -f /tmp/print_deb
  apt-cache show $DEB_NAME > /tmp/print_deb
  # The apt cache may have more than one version of the package available.
  # For example, if the user has added another repository to 
  # /etc/apt/sources.list to install/upgrade packages.  Use bash arrays to 
  # hold all the results until we can find information on the version we want.
  # TODO: Is there a way to do this using only awk, so we can use /bin/sh
  # instead of /bin/bash?
  ALL_VER=( `grep '^Version: ' < /tmp/print_deb | awk '{print $2}'` )
  ALL_PRIO=( `grep '^Priority: ' < /tmp/print_deb | awk '{print $2}'` )
  ALL_SECTION=( `grep '^Section: ' < /tmp/print_deb | awk '{print $2}'` )
  ALL_FILENAME=( `grep '^Filename: ' < /tmp/print_deb | awk '{print $2}'` )
  rm -f /tmp/print_deb

  # Find only the package version the user has installed.
  NUM_VER=${#ALL_VER[@]}
  FOUND_MATCH=0
  for ((I=0; I<$NUM_VER; I++));
  do
    if [ "${ALL_VER[$I]}" = "$DEB_VER" ]
    then
      FOUND_MATCH=1
      DEB_PRIO="${ALL_PRIO[$I]}"
      DEB_SECTION="${ALL_SECTION[$I]}"
      DEB_FILENAME="${ALL_FILENAME[$I]}"
    fi
  done

  # Determine if the package filename appears to be from a locally-built
  # repository (as created in build_image.sh).  Use ! to ignore non-zero
  # exit code, since grep exits 1 if no match.
  ! DEB_FILENAME_IS_LOCAL=`echo $DEB_FILENAME | grep 'local_packages'`
  
  if [ $FOUND_MATCH -eq 0 ]
  then
    # Can't find information on package in apt cache
    if [ $VERBOSE -eq 1 ]
    then
      echo "Unable to locate package $DEB_NAME version $DEB_VER" 1>&2
      echo "in apt cache.  It may have been installed directly, or the" 1>&2
      echo "cache has been updated since installation and no longer" 1>&2
      echo "contains information on that version.  Omitting it in the" 1>&2
      echo "list, since we can't determine where it came from." 1>&2
    fi
    echo "# Skipped $DEB_NAME $DEB_VER: not in apt cache"
  elif [ "x$DEB_FILENAME" = "x" ]
  then
    # No filename, so package was installed via dpkg -i.
    if [ $VERBOSE -eq 1 ]
    then
      echo "Package $DEB_NAME appears to have been installed directly" 1>&2
      echo "(perhaps using 'dpkg -i').  Omitting it in the list, since we" 1>&2
      echo "can't determine where it came from." 1>&2
    fi
    echo "# Skipped $DEB_NAME $DEB_VER: installed directly"
  elif [ "x$DEB_FILENAME_IS_LOCAL" != "x" ]
  then
    # Package was installed from a local_packages directory.
    # For example, chromeos-wm
    if [ $VERBOSE -eq 1 ]
    then
      echo "Package $DEB_NAME appears to have been installed from a local" 1>&2
      echo "package repository.  Omitting it in the list, since future" 1>&2
      echo "installs will also need to be local." 1>&2
    fi
    echo "# Skipped $DEB_NAME $DEB_VER $DEB_FILENAME: local install"
  else
    # Package from external repository.
    # Don't change the order of these fields; make_local_repo.sh depends
    # upon this order.
    echo "$DEB_NAME $DEB_VER $DEB_PRIO $DEB_SECTION $DEB_FILENAME"
  fi
}

# Header
echo "# Copyright (c) 2009 The Chromium Authors. All rights reserved."
echo "# Use of this source code is governed by a BSD-style license that can be"
echo "# found in the LICENSE file."
echo
echo "# Package list created by list_installed_packages.sh"
echo "# Creation time: `date`"
echo "#"
echo "# Contents of /etc/apt/sources.list:"
cat /etc/apt/sources.list | sed 's/^/#   /'
echo "#"
echo "# package_name version priority section repo_filename"

# List all installed packages
for DEB in `dpkg-query --show -f='${Package}\n'`
do
  print_deb $DEB
done
