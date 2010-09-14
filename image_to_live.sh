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
DEFINE_boolean verbose ${FLAGS_FALSE} \
  "Whether to output verbose information for debugging."
DEFINE_integer devserver_port 8080 \
  "Port to use for devserver"
DEFINE_string update_url "" "Full url of an update image"

UPDATER_BIN='/usr/bin/update_engine_client'
UPDATER_IDLE='UPDATE_STATUS_IDLE'
UPDATER_NEED_REBOOT='UPDATE_STATUS_UPDATED_NEED_REBOOT'

function kill_all_devservers {
  # Using ! here to avoid exiting with set -e is insufficient, so use
  # || true instead.
  sudo pkill -f devserver\.py || true
}

function cleanup {
  if [ -z "${FLAGS_update_url}" ]; then
    kill_all_devservers
  fi
  cleanup_remote_access
  rm -rf "${TMP}"
}

function remote_reboot_sh {
  rm -f "${TMP_KNOWN_HOSTS}"
  remote_sh "$@"
}

function start_dev_server {
  kill_all_devservers
  if [ ${FLAGS_verbose} -eq ${FLAGS_FALSE} ]; then
    ./enter_chroot.sh "sudo ./start_devserver ${FLAGS_devserver_port} \
         --client_prefix=ChromeOSUpdateEngine > dev_server.log 2>&1" &
  else
    ./enter_chroot.sh "sudo ./start_devserver ${FLAGS_devserver_port} \
        --client_prefix=ChromeOSUpdateEngine &"
  fi
  echo -n "Waiting on devserver to start"
  until netstat -anp 2>&1 | grep 0.0.0.0:${FLAGS_devserver_port} > /dev/null
  do
    sleep .5
    echo -n "."
  done
  echo ""
}

# Copys stateful update script which fetches the newest stateful update
# from the dev server and prepares the update. chromeos_startup finishes
# the update on next boot.
function copy_stateful_update {
  local dev_url=$(get_devserver_url)
  local stateful_url=""

  # Assume users providing an update url are using an archive_dir path.
  if [ -n "${FLAGS_update_url}" ]; then
    stateful_url=$(echo ${dev_url} | sed -e "s/update/static\/archive/")
  else
    stateful_url=$(echo ${dev_url} | sed -e "s/update/static/")
  fi

  info "Starting stateful update using URL ${stateful_url}"

  # Copy over update script and run update.
  local dev_dir="$(dirname $0)/../platform/dev"
  remote_cp_to "${dev_dir}/stateful_update" "/tmp"
  remote_sh "/tmp/stateful_update ${stateful_url}"
}

function get_update_args {
  if [ -z ${1} ]; then
    die "No url provided for update."
  fi
  local update_args="--omaha_url ${1}"
  if [[ ${FLAGS_ignore_version} -eq ${FLAGS_TRUE} ]]; then
    info "Forcing update independent of the current version"
    update_args="--update ${update_args}"
  fi

  echo "${update_args}"
}

function get_devserver_url {
  local devserver_url=""
  if [ ${FLAGS_ignore_hostname} -eq ${FLAGS_TRUE} ]; then
    if [ -z ${FLAGS_update_url} ]; then
      devserver_url="http://$HOSTNAME:${FLAGS_devserver_port}/update"
    else
      devserver_url="${FLAGS_update_url}"
    fi
  fi
  echo "${devserver_url}"
}

function get_update_status {
  remote_sh "${UPDATER_BIN} -status |
      grep CURRENT_OP |
      cut -f 2 -d ="
  echo "${REMOTE_OUT}"
}

function run_auto_update {
  local update_args="$(get_update_args "$(get_devserver_url)")"
  info "Starting update using args ${update_args}"
  remote_sh "${UPDATER_BIN} ${update_args}"

  local update_status="$(get_update_status)"
  if [ "${update_status}" = ${UPDATER_NEED_REBOOT} ]; then
    info "Autoupdate was successful."
    return 0
  else
    warn "Autoupdate was unsuccessful.  Status returned was ${update_status}."
    return 1
  fi
}

function remote_reboot {
  info "Rebooting."
  remote_sh "touch /tmp/awaiting_reboot; reboot"
  local output_file
  output_file="${TMP}/output"

  while true; do
    REMOTE_OUT=""
    # This may fail while the machine is down so generate output and a
    # boolean result to distinguish between down/timeout and real failure
    ! remote_sh_allow_changed_host_key \
        "echo 0; [ -e /tmp/awaiting_reboot ] && echo '1'; true"
    echo "${REMOTE_OUT}" > "${output_file}"
    if grep -q "0" "${output_file}"; then
      if grep -q "1" "${output_file}"; then
        info "Not yet rebooted"
      else
        info "Rebooted and responding"
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

  if [ "$(get_update_status)" = "${UPDATER_NEED_REBOOT}" ]; then
    warn "Machine has been updated but not yet rebooted.  Rebooting it now."
    warn "Rerun this script if you still wish to update it."
    remote_reboot
    exit 1
  fi

  if [ -z "${FLAGS_update_url}" ]; then
    # only start local devserver if no update url specified.
    start_dev_server
  fi

  if ! run_auto_update; then
    die "Update was not successful."
  fi

  if ! copy_stateful_update; then
    warn "Stateful update was not successful."
  fi

  remote_reboot

  if [[ ${FLAGS_update_hostkey} -eq ${FLAGS_TRUE} ]]; then
    local known_hosts="${HOME}/.ssh/known_hosts"
    cp "${known_hosts}" "${known_hosts}~"
    grep -v "^${FLAGS_remote} " "${known_hosts}" > "${TMP}/new_known_hosts"
    cat "${TMP}/new_known_hosts" "${TMP_KNOWN_HOSTS}" > "${known_hosts}"
    chmod 0640 "${known_hosts}"
    info "New updated in ${known_hosts}, backup made."
  fi

  remote_sh "grep ^CHROMEOS_RELEASE_DESCRIPTION= /etc/lsb-release"
  local release_description=$(echo ${REMOTE_OUT} | cut -d '=' -f 2)
  info "Update was successful and rebooted to $release_description"

  return 0
}

main $@
