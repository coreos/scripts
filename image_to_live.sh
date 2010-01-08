#!/bin/bash

# Copyright (c) 2009 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Script to update an image onto a live running ChromiumOS instance.

# Load common constants.  This should be the first executable line.
# The path to common.sh should be relative to your script's location.

. "$(dirname $0)/common.sh"
. "$(dirname $0)/remote_access.sh"

DEFINE_boolean ignore_version ${FLAGS_TRUE} \
  "Ignore existing version on running instance and always update"
DEFINE_boolean ignore_hostname ${FLAGS_TRUE} \
  "Ignore existing AU hostname on running instance use this hostname"
DEFINE_boolean update_known_hosts ${FLAGS_FALSE} \
  "Update your known_hosts with the new remote instance's key"

function kill_all_devservers {
  ! pkill -f 'python devserver.py'
}

function cleanup {
  kill_all_devservers
  rm -rf "${TMP}"
}

function remote_reboot_sh {
  rm -f "${TMP_KNOWN_HOSTS}"
  remote_sh "$@"
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

  if [[ ${FLAGS_ignore_version} -eq ${FLAGS_TRUE} ]]; then
    echo "Forcing update independent of the current version"
    remote_sh "cat /etc/lsb-release |\
        grep -v CHROMEOS_RELEASE_VERSION > /etc/lsb-release~;\
        mv /etc/lsb-release~ /etc/lsb-release; \
        echo 'CHROMEOS_RELEASE_VERSION=0.0.0.0' >> /etc/lsb-release"
  fi

  if [ ${FLAGS_ignore_hostname} -eq ${FLAGS_TRUE} ]; then
    echo "Forcing update from ${HOSTNAME}"
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
  echo "Starting update"
  local update_file=/var/log/softwareupdate.log
  # Clear it out so we don't see a prior run and make sure it
  # exists so the first tail below can't fail if it races the
  # memento updater first write and wins.
  remote_sh "rm -f ${update_file}; touch ${update_file}; \
      /opt/google/memento_updater/memento_updater.sh</dev/null>&/dev/null&"

  local update_error
  local output_file
  local progress

  update_error=1
  output_file="${TMP}/output"

  while true; do
    # The softwareupdate.log gets pretty bit with download progress
    # lines so only look in the last 100 lines for status.
    remote_sh "tail -100 ${update_file}"
    echo "${REMOTE_OUT}" > "${output_file}"
    progress=$(tail -4 "${output_file}" | grep 0K | head -1)
    if [ -n "${progress}" ]; then
      echo "Image fetching progress: ${progress}"
    fi
    if grep -q 'updatecheck status="noupdate"' "${output_file}"; then
      echo "devserver is claiming there is no update available."
      echo "Consider setting --ignore_version."
      break
    fi
    if grep -q 'Autoupdate applied. You should now reboot' "${output_file}"
    then
      echo "Autoupdate was successful."
      update_error=0
    fi
    if grep -q 'Memento AutoUpdate terminating' "${output_file}"; then
      break
    fi
    # Sleep for a while so that ssh handling doesn't slow down the install
    sleep 2
  done
  
  return ${update_error}
}

function remote_reboot {
  echo "Rebooting."
  remote_sh "touch /tmp/awaiting_reboot; reboot"
  local output_file
  output_file="${TMP}/output"

  while true; do
    REMOTE_OUT=""
    # This may fail while the machine is done so generate output and a 
    # boolean result to distinguish between down/timeout and real failure
    ! remote_sh_allow_changed_host_key \
      "echo 0; [ -e /tmp/awaiting_reboot ] && echo '1'; true"
    echo "${REMOTE_OUT}" > "${output_file}"
    if grep -q "0" "${output_file}"; then
      if grep -q "1" "${output_file}"; then
        echo "Not yet rebooted"
      else
        echo "Rebooted and responding"
        break
      fi
    fi
    sleep .5
  done
}

function main() {
  assert_outside_chroot

  cd $(dirname "$0")

  FLAGS "$@" || exit 1
  eval set -- "${FLAGS_ARGV}"

  set -e

  trap cleanup EXIT

  TMP=$(mktemp -d /tmp/image_to_live.XXXX)

  remote_access_init

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

  if [[ ${FLAGS_update_hostkey} -eq ${FLAGS_TRUE} ]]; then
    local known_hosts="${HOME}/.ssh/known_hosts"
    cp "${known_hosts}" "${known_hosts}~"
    grep -v "^${FLAGS_remote} " "${known_hosts}" > "${TMP}/new_known_hosts"
    cat "${TMP}/new_known_hosts" "${TMP_KNOWN_HOSTS}" > "${known_hosts}"
    chmod 0640 "${known_hosts}"
    echo "New updated in ${known_hosts}, backup made."
  fi

  remote_sh "grep ^CHROMEOS_RELEASE_DESCRIPTION= /etc/lsb-release"
  local release_description=$(echo $REMOTE_OUT | cut -d '=' -f 2)
  echo "Update was successful and rebooted to $release_description"
  
  return 0
}

main $@
