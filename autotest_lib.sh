# Copyright (c) 2010 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.
#
# Provides common commands for dealing running/building autotest

. "$(dirname "$0")/common.sh"

get_default_board

DEFINE_string board "$DEFAULT_BOARD" \
    "The board for which you are building autotest"

function check_board() {
  local board_names=""
  local index=1
  local found=0
  for board in ../overlays/overlay-*
  do
    board_names[index]=${board:20}
    index+=1
    if [ "${FLAGS_board}" == "${board:20}" ]
    then
      found=1
    fi
  done

  if [ ${found} -eq 0 ]
  then
    echo "You are required to specify a supported board from the command line."
    echo "Supported boards are:"
    for board in ${board_names[@]}
    do
      echo ${board}
    done
  exit 0
  fi
}


# Populates the chroot's /usr/local/autotest/$FLAGS_board directory based on
# the given source directory.
# args:
#   $1 - original source directory
#   $2 - target directory
function update_chroot_autotest() {
  local original=$1
  local target=$2
  echo "Updating chroot Autotest from ${original} to ${target}..."
  sudo mkdir -p "${target}"
  sudo chmod 777 "${target}"
  cp -fpru ${original}/{client,conmux,server,tko,utils,global_config.ini,shadow_config.ini} ${target}
}
