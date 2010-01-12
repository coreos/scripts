#!/bin/bash

# Copyright (c) 2009 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# This script can be used to replace the "dpkg" binary as far as the
# "apt-get install" command is concerned. When "apt-get install foo"
# runs it will make two calls to dpkg like:
#   dpkg --status-fd ## --unpack --auto-deconfigure /path/to/foo.deb
#   dpkg --status-fd ## --configure foo
# This script will extract the .deb file and make it appear to be installed
# successfully. It will skip the maintainer scripts and configure steps.
#
# As a one-off test, you can run like:
#  apt-get -o="Dir::Bin::dpkg=/path/to/this" install foo

# Load common constants.  This should be the first executable line.
# The path to common.sh should be relative to your script's location.
. "$(dirname "$0")/common.sh"

# Flags
DEFINE_string root "" \
  "The target rootfs directory in which to install packages."
DEFINE_boolean dpkg_fallback $FLAGS_TRUE \
  "Run normal dpkg if maintainer scripts are not whitelisted."
DEFINE_string status_fd "" \
  "The file descriptor to report status on; ignored."
DEFINE_boolean unpack $FLAGS_FALSE "Is the action 'unpack'?"
DEFINE_boolean configure $FLAGS_FALSE "Is the action 'configure'?"
DEFINE_boolean remove $FLAGS_FALSE "Is the action 'remove'?"
DEFINE_boolean auto_deconfigure $FLAGS_FALSE "Ignored"
DEFINE_boolean force_depends $FLAGS_FALSE "Ignored"
DEFINE_boolean force_remove_essential $FLAGS_FALSE "Ignored"

# Fix up the command line and parse with shflags.
FIXED_FLAGS="$@"
FIXED_FLAGS=${FIXED_FLAGS/status-fd/status_fd}
FIXED_FLAGS=${FIXED_FLAGS/auto-deconfigure/auto_deconfigure}
FIXED_FLAGS=${FIXED_FLAGS/force-depends/force_depends}
FIXED_FLAGS=${FIXED_FLAGS/force-remove-essential/force_remove_essential}
FLAGS $FIXED_FLAGS || exit 1
eval set -- "${FLAGS_ARGV}"

# Die on any errors.
set -e

# Returns true if the input file is whitelisted.
#
# $1 - The file to check
is_whitelisted() {
  local whitelist="${SRC_ROOT}/package_scripts/package.whitelist"
  test -f "$whitelist" || return

  local checksum=$(md5sum "$1" | awk '{ print $1 }')
  local count=$(grep -c "$checksum" "${whitelist}" || /bin/true)
  test $count -ne 0
}

# Returns true if either of the two given files exist and are not whitelisted.
#
# $1 - The package name.
# $2 - The path to the preinst file if it were to exist.
# $3 - The path to the postinst file if it were to exist.
has_missing_whitelist() {
  local package=$1
  local preinst=$2
  local postinst=$3
  local missing_whitelist=0

  if [ -f "$preinst" ]; then
    if ! is_whitelisted "$preinst"; then
      missing_whitelist=1
      echo "Warning: Missing whitelist entry for ${package}.preinst"
    fi
  fi
  if [ -f "$postinst" ]; then
    if ! is_whitelisted "$postinst"; then
      missing_whitelist=1
      echo "Warning: Missing whitelist entry for ${package}.postinst"
    fi
  fi
  test $missing_whitelist -ne 0
}

do_configure() {
  local dpkg_info="$FLAGS_root/var/lib/dpkg/info/"
  local fallback_packages=""

  for p in "$@"; do
    echo "Configuring: $p"

    # Make sure that any .preinst or .postinst files are whitelisted.
    local preinst="${dpkg_info}/${p}.preinst"
    local postinst="${dpkg_info}/${p}.postinst"
    if has_missing_whitelist "$p" "$preinst" "$postinst"; then
      if [ $FLAGS_dpkg_fallback -eq $FLAGS_TRUE ]; then
        echo "** Warning: Will run full maintainer scripts for ${p}."
        fallback_packages="$fallback_packages $p"
        continue
      else
        # TODO: Eventually should be upgraded to a full error.
        echo "** Warning: Ignoring missing whitelist for ${p}."
      fi
    fi

    # Run our maintainer script for this package if we have one.
    local chromium_postinst="${SRC_ROOT}/package_scripts/${p}.postinst"
    if [ -f "$chromium_postinst" ]; then
      echo "Running: $chromium_postinst"
      ROOT="$FLAGS_root" SRC_ROOT="$SRC_ROOT" sh -x $chromium_postinst
    fi
  done

  if [ -n "$fallback_packages" ]; then
    dpkg --root="$FLAGS_root" --configure $fallback_packages
  fi
}

do_unpack() {
  local dpkg_status="$FLAGS_root/var/lib/dpkg/status"
  local dpkg_info="$FLAGS_root/var/lib/dpkg/info/"

  for p in "$@"; do
    local package=$(dpkg-deb --field "$p" Package)
    local tmpdir=$(mktemp -d)

    dpkg-deb --control "$p" "$tmpdir"

    local preinst="${tmpdir}/preinst"
    local postinst="${tmpdir}/postinst"
    if has_missing_whitelist "$package" "$preinst" "$postinst"; then
      if [ $FLAGS_dpkg_fallback -eq $FLAGS_TRUE ]; then
        echo "** Warning: Running full maintainer scripts for ${package}."
        dpkg --root="$FLAGS_root" --unpack --auto-deconfigure "$p"
        rm -rf "$tmpdir"
        continue
      else
        # TODO: Eventually should be upgraded to a full error.
        echo "** Warning: Ignoring missing whitelist for ${p}."
      fi
    fi

    # Copy the info files
    local files=$(ls "$tmpdir" | grep -v control)
    for f in $files; do
      cp "${tmpdir}/${f}" "${dpkg_info}/${package}.${f}"
    done
    touch "${dpkg_info}/${package}.list"  # TODO: Proper .list files.

    # Mark the package as installed successfully.
    echo "Status: install ok installed" >> "$dpkg_status"
    cat "${tmpdir}/control" >> "$dpkg_status"
    echo "" >> "$dpkg_status"

    rm -rf "$tmpdir"

    # Run our maintainer script for this package if we have one.
    local chromium_postinst="${SRC_ROOT}/package_scripts/${package}.preinst"
    if [ -f "$chromium_preinst" ]; then
      echo "Running: ${chromium_preinst}"
      ROOT="$FLAGS_root" SRC_ROOT="$SRC_ROOT" $chromium_preinst
    fi

    echo "Unpacking: $p"
    dpkg-deb --extract "$p" "$FLAGS_root"
  done
}

# This script requires at least "--root="
if [ -z "$FLAGS_root" ]; then
  echo "dpkg_no_scripts: Missing root directory."
  exit 1
fi

if [ $FLAGS_configure -eq $FLAGS_TRUE ]; then
  do_configure $@
elif [ $FLAGS_unpack -eq $FLAGS_TRUE ]; then
  do_unpack $@
elif [ $FLAGS_remove -eq $FLAGS_TRUE ]; then
  # We log but ignore remove requests.
  echo "Ignoring remove: $@"
else
  echo "dpkg_no_scripts.sh: Unknown or missing command."
  exit 1
fi

exit 0
