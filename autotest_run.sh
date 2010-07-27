#!/bin/bash

# Copyright (c) 2010 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# This script is intended as a wrapper to execute autotest tests for a given
# board.

# Load common constants.  This should be the first executable line.
# The path to common.sh should be relative to your script's location.
. "$(dirname "$0")/common.sh"

# Script must be run inside the chroot
restart_in_chroot_if_needed $*
get_default_board

DEFINE_string board "${DEFAULT_BOARD}" \
  "The board to run tests for."

FLAGS_HELP="usage: $0 <flags>"
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

# Define a directory which will not be cleaned by portage automatically. So we
# could achieve incremental build between two autoserv runs.
BUILD_RUNTIME="/build/${FLAGS_board}/usr/local/autotest/"

# Hack: set the CHROMEOS_ROOT variable by hand here
CHROMEOS_ROOT=/home/${USER}/trunk/

# Ensure the configures run by autotest pick up the right config.site
CONFIG_SITE=/usr/share/config.site
AUTOTEST_SRC="${CHROMEOS_ROOT}/src/third_party/autotest/files"

[ -z "${FLAGS_board}" ] && \
  die "You must specify --board="

function setup_ssh() {
  eval $(ssh-agent) > /dev/null
  ssh-add \
    ${CHROMEOS_ROOT}/src/scripts/mod_for_test_scripts/ssh_keys/testing_rsa
}

function teardown_ssh() {
  ssh-agent -k > /dev/null
}

function copy_src() {
  local dst=$1
  mkdir -p "${dst}"
  cp -fpru "${AUTOTEST_SRC}"/{client,conmux,server,tko,utils} "${dst}" || die
  cp -fpru "${AUTOTEST_SRC}/shadow_config.ini" "${dst}" || die
}

src_test() {
  # claim ownership of the staging area
  sudo chown -R ${USER} "${BUILD_RUNTIME}"
  sudo chmod -R 755 "${BUILD_RUNTIME}"

  local third_party="${CHROMEOS_ROOT}/src/third_party"
  copy_src "${BUILD_RUNTIME}"
  cp -fpru "${AUTOTEST_SRC}/global_config.ini" "${BUILD_RUNTIME}"

  # ensure that no tests are ever built
  sed -e 's/enable_server_prebuild: .*/enable_server_prebuild: False/' -i \
    "${BUILD_RUNTIME}"/global_config.ini

  setup_ssh
  cd "${BUILD_RUNTIME}"

  local args=()
  if [[ -n ${AUTOSERV_TEST_ARGS} ]]; then
    args=("-a" "${AUTOSERV_TEST_ARGS}")
  fi

  local timestamp=$(date +%Y-%m-%d-%H.%M.%S)

  # Do not use sudo, it'll unset all your environment
  LOGNAME=${USER} ./server/autoserv -r /tmp/results.${timestamp} \
    ${AUTOSERV_ARGS} "${args[@]}"

  teardown_ssh
}

src_test
