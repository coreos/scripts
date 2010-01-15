#!/bin/bash

# Copyright (c) 2009 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Script to install and launch autotest.

. "$(dirname "$0")/common.sh"

# Script must be run inside the chroot
assert_inside_chroot

DEFINE_string client_control "" "client test case to execute" "c"
DEFINE_boolean force false "force reinstallation of autotest" "f"
DEFINE_string machine "" "if present, execute autotest on this host." "m"
DEFINE_string test_key "${GCLIENT_ROOT}/src/platform/testing/testing_rsa" \
"rsa key to use for autoserv" "k"

# More useful help
FLAGS_HELP="usage: $0 [flags]"

# parse the command-line
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"
set -e

AUTOTEST_CHROOT_DEST="/usr/local/autotest"
AUTOTEST_SRC="${GCLIENT_ROOT}/src/third_party/autotest/files"

CHROOT_AUTHSOCK_PREFIX="/tmp/chromiumos_test_agent"

function cleanup {
  if [ "${TEST_AUTH_SOCKET:0:26}" == ${CHROOT_AUTHSOCK_PREFIX} ]
  then
    echo "cleaning up chrooted ssh-agent."
    kill ${SSH_AGENT_PID}
  fi
}

trap cleanup EXIT

# If ssh-agent isn't already running, start one (possibly inside the chroot)
if [ ! -n "${SSH_AGENT_PID}" ]
then
  echo "Setting up ssh-agent in chroot for testing."
  TEST_AUTH_SOCKET=$(mktemp -u ${CHROOT_AUTHSOCK_PREFIX}.XXXX)
  eval $(/usr/bin/ssh-agent -a ${TEST_AUTH_SOCKET})
fi

# Install authkey for testing
chmod 400 $FLAGS_test_key
/usr/bin/ssh-add $FLAGS_test_key 

if [ -n "${FLAGS_machine}" ]
then
  # run only a specific test/suite if requested
  if [ ! -n "${FLAGS_client_control}" ]
  then
    # Generate meta-control file to run all existing site tests.
    CLIENT_CONTROL_FILE=\
      "${AUTOTEST_CHROOT_DEST}/client/site_tests/accept_Suite/control"
    echo "No control file specified. Running all tests."
  else
    CLIENT_CONTROL_FILE=${AUTOTEST_CHROOT_DEST}/${FLAGS_client_control}
  fi
  # Kick off autosrv for specified test
  autoserv_cmd="${AUTOTEST_CHROOT_DEST}/server/autoserv \
    -m ${FLAGS_machine} \
    -c ${CLIENT_CONTROL_FILE}"
  echo "running autoserv: " ${autoserv_cmd}
  pushd ${AUTOTEST_CHROOT_DEST} 1> /dev/null
  ${autoserv_cmd}
  popd 1> /dev/null
else
  echo "To execute autotest manually:
  eval \$(ssh-agent)        # start ssh-agent
  ssh-add $FLAGS_test_key  # add test key to agent
  # Then execute autoserv:
  $autoserv_cmd"
fi

