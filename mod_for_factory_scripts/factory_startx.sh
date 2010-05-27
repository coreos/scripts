#!/bin/sh

# Copyright (c) 2010 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

XAUTH=/usr/bin/xauth
XAUTH_FILE="/var/run/factory_ui.auth"
SERVER_READY=
DISPLAY=":0"

user1_handler () {
  echo "X server ready..." 1>&2
  SERVER_READY=y
}

trap user1_handler USR1
MCOOKIE=$(head -c 8 /dev/urandom | openssl md5)
${XAUTH} -q -f ${XAUTH_FILE} add ${DISPLAY} . ${MCOOKIE}

/sbin/xstart.sh ${XAUTH_FILE} &

while [ -z ${SERVER_READY} ]; do
  sleep .1
done

/sbin/initctl emit factory-ui-started
cat /proc/uptime > /tmp/uptime-x-started

echo "DISPLAY=${DISPLAY}; export DISPLAY"
echo "XAUTHORITY=${XAUTH_FILE}; export XAUTHORITY"
