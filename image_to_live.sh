#!/bin/bash

# Copyright (c) 2009 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Script to convert the output of build_image.sh to a usb image.

# Load common constants.  This should be the first executable line.
# The path to common.sh should be relative to your script's location.
. "$(dirname "$0")/common.sh"

assert_outside_chroot

cd $(dirname "$0")

DEFAULT_PRIVATE_KEY="$SRC_ROOT/platform/testing/testing_rsa"

DEFINE_string ip "" "IP address of running Chromium OS instance"
DEFINE_boolean ignore_version $FLAGS_TRUE \
  "Ignore existing version on running instance and always update"
DEFINE_boolean ignore_hostname $FLAGS_TRUE \
  "Ignore existing AU hostname on running instance use this hostname"
DEFINE_string private_key "$DEFAULT_PRIVATE_KEY" \
  "Private key of root account on instance"

FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

set -e

if [ -z "$FLAGS_ip" ]; then
  echo "Please specify the IP of the Chromium OS instance"
  exit 1
fi

TMP=$(mktemp -d /tmp/image_to_live.XXXX)
TMP_PRIVATE_KEY=$TMP/private_key
TMP_KNOWN_HOSTS=$TMP/known_hosts

function kill_all_devservers {
  ! pkill -f 'python devserver.py'
}

function cleanup {
  kill_all_devservers
  rm -rf $TMP
}

trap cleanup EXIT

function remote_sh {
  # Disable strict host checking so that we don't prompt the user when
  # the host key file is removed and just go ahead and add it.
  REMOTE_OUT=$(ssh -o StrictHostKeyChecking=no -o \
    UserKnownHostsFile=$TMP_KNOWN_HOSTS root@$FLAGS_ip "$@")
  return ${PIPESTATUS[0]}
}

function remote_reboot_sh {
  rm -f $TMP_KNOWN_HOSTS
  remote_sh "$@"
}

function set_up_remote_access {
  if [ -z "$SSH_AGENT_PID" ]; then
    eval `ssh-agent`
  fi
  cp $FLAGS_private_key $TMP_PRIVATE_KEY
  chmod 0400 $TMP_PRIVATE_KEY
  ssh-add $TMP_PRIVATE_KEY

  # Verify the client is reachable before continuing
  remote_sh "true"
}

function start_dev_server {
  kill_all_devservers
  sudo -v
  ./enter_chroot.sh "cd ../platform/dev; ./start-devserver.sh>/dev/null 2>&1" &
  echo -n "Waiting on devserver to start"
  until netstat -anp 2>&1 | grep 8080 > /dev/null; do
    sleep .5
    echo -n "."
  done
  echo ""
}

function prepare_update_metadata {
  remote_sh "mount -norw,remount /"

  if [ $FLAGS_ignore_version -eq $FLAGS_TRUE ]; then
    echo "Forcing update independent of the current version"
    remote_sh "cat /etc/lsb-release |\
        grep -v CHROMEOS_RELEASE_VERSION > /etc/lsb-release~;\
        mv /etc/lsb-release~ /etc/lsb-release; \
        echo 'CHROMEOS_RELEASE_VERSION=0.0.0.0' >> /etc/lsb-release"
  fi

  if [ $FLAGS_ignore_hostname -eq $FLAGS_TRUE ]; then
    echo "Forcing update from $HOSTNAME"
    remote_sh "cat /etc/lsb-release |\
        grep -v '^CHROMEOS_AUSERVER=' |\
        grep -v '^CHROMEOS_DEVSERVER=' > /etc/lsb-release~;\
        mv /etc/lsb-release~ /etc/lsb-release; \
        echo 'CHROMEOS_AUSERVER=http://$HOSTNAME:8080/update' >> \
          /etc/lsb-release; \
        echo 'CHROMEOS_DEVSERVER=http://$HOSTNAME:8080' >> /etc/lsb-release"
  fi

  remote_sh "mount -noro,remount /"
}

function run_auto_update {
  echo "Starting update and clear away prior"
  UPDATE_FILE=/var/log/softwareupdate.log
  # Clear it out so we don't see a prior run and make sure it
  # exists so the first tail below can't fail if it races the
  # memento updater first write and wins.
  remote_sh "rm -f $UPDATE_FILE; touch $UPDATE_FILE; \
      /opt/google/memento_updater/memento_updater.sh</dev/null>&/dev/null&"

  local update_error
  local output_file
  local progress

  update_error=1
  output_file=$TMP/output

  while true; do
    # The softwareupdate.log gets pretty bit with download progress
    # lines so only look in the last 100 lines for status.
    remote_sh "tail -100 $UPDATE_FILE"
    echo "$REMOTE_OUT" > $output_file
    progress=$(tail -4 $output_file | grep 0K | head -1)
    if [ -n "$progress" ]; then
      echo "Image fetching progress: $progress"
    fi
    if grep -q 'updatecheck status="noupdate"' $output_file; then
      echo "devserver is claiming there is no update available."
      echo "Consider setting --ignore_version."
      break
    fi
    if grep -q 'Autoupdate applied. You should now reboot' $output_file; then
      echo "Autoupdate was successful."
      update_error=0
    fi
    if grep -q 'Memento AutoUpdate terminating' $output_file; then
      break
    fi
    # Sleep for a while so that ssh handling doesn't slow down the install
    sleep 2
  done
  
  return $update_error
}

function remote_reboot {
  echo "Rebooting."
  remote_sh "touch /tmp/awaiting_reboot; reboot"
  local output_file
  output_file=$TMP/output

  while true; do
    REMOTE_OUT=""
    # This may fail while the machine is done so generate output and a 
    # boolean result to distinguish between down/timeout and real failure
    ! remote_reboot_sh "echo 0; [ -e /tmp/awaiting_reboot ] && echo '1'; true"
    echo "$REMOTE_OUT" > $output_file
    if grep -q "0" $output_file; then
      if grep -q "1" $output_file; then
        echo "Not yet rebooted"
      else
        echo "Rebooted and responding"
        break
      fi
    fi
    sleep .5
  done
}

set_up_remote_access

if remote_sh [ -e /tmp/memento_autoupdate_completed ]; then
  echo "Machine has been updated but not yet rebooted.  Rebooting it now."
  echo "Rerun this script if you still wish to update it."
  remote_reboot
  exit 1
fi

start_dev_server

prepare_update_metadata

if ! run_auto_update; then
  echo "Update was not successful."
  exit
fi

remote_reboot

remote_sh "grep ^CHROMEOS_RELEASE_DESCRIPTION= /etc/lsb-release"
RELEASE_DESCRIPTION=$(echo $REMOTE_OUT | cut -d '=' -f 2)
echo "Update was successful and rebooted to $RELEASE_DESCRIPTION"
