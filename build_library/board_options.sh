# Copyright (c) 2011 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

if [ -z "${FLAGS_board}" ]; then
  error "--board is required."
  exit 1
fi

BOARD="${FLAGS_board}"
BOARD_ROOT="/build/${BOARD}"
ARCH=$(get_board_arch ${BOARD})

# What cross-build are we targeting?
. "${BOARD_ROOT}/etc/portage/make.conf"

# check if any of the given use flags are enabled for a pkg
pkg_use_enabled() {
  local pkg="$1"
  shift
  # for every flag argument, turn it into `-e ^+flag` for grep
  local grep_args="${@/#/-e ^+}"

  equery-"${BOARD}" -q uses "${pkg}" | grep -q ${grep_args}
  return $?
}

# get a package's SONAMEs in soname.provided format
pkg_soname_provides() {
  local provides p
  # We could run this command but it ugly and silly slow:
  # portageq-"${BOARD}" metadata "${BOARD_ROOT}" installed "$1" PROVIDES
  provides=$(<"${BOARD_ROOT}/var/db/pkg/$1/PROVIDES")

  if [[ -z "$provides" ]]; then
    return
  fi

  # convert:
  #  x86_32: libcom_err.so.2 libss.so.2 x86_64: libcom_err.so.2 libss.so.2
  # into:
  #  x86_32 libcom_err.so.2 libss.so.2
  #  x86_64 libcom_err.so.2 libss.so.2
  echo -n "# $1:"
  for p in ${provides}; do
    if [[ "$p" == *: ]]; then
      echo
      echo -n "${p%:}"
    else
      echo -n " $p"
    fi
  done
  echo
}
