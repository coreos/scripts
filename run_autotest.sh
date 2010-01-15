#!/bin/bash

# Copyright (c) 2009 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Script to install and launch autotest.

. "$(dirname "$0")/common.sh"

# Script must be run inside the chroot
assert_inside_chroot

set -e

TEST_RSA_KEY="${GCLIENT_ROOT}/src/platform/testing/testing_rsa"
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
chmod 400 $TEST_RSA_KEY
/usr/bin/ssh-add $TEST_RSA_KEY

autoserv_cmd="./server/autoserv $@"
echo "running: " ${autoserv_cmd}
AUTOTEST_ROOT="/usr/local/autotest"
pushd ${AUTOTEST_ROOT} 1> /dev/null
${autoserv_cmd}
popd 1> /dev/null

