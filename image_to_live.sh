#!/bin/bash

# Copyright (c) 2009-2010 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Script to update an image onto a live running ChromiumOS instance.

# Load common constants.  This should be the first executable line.
# The path to common.sh should be relative to your script's location.

. "$(dirname $0)/common.sh"
. "$(dirname $0)/remote_access.sh"

# Flags to control image_to_live.
DEFINE_boolean ignore_hostname ${FLAGS_TRUE} \
  "Ignore existing AU hostname on running instance use this hostname."
DEFINE_boolean ignore_version ${FLAGS_TRUE} \
  "Ignore existing version on running instance and always update."
DEFINE_string server_log "dev_server.log" \
  "Path to log for the devserver."
DEFINE_boolean update "${FLAGS_TRUE}" \
  "Perform update of root partition."
DEFINE_boolean update_known_hosts ${FLAGS_FALSE} \
  "Update your known_hosts with the new remote instance's key."
DEFINE_string update_log "update_engine.log" \
  "Path to log for the update_engine."
DEFINE_boolean verify ${FLAGS_TRUE} "Verify image on device after update."

# Flags for devserver.
DEFINE_string archive_dir "" \
  "Update using the test image in the image.zip in this directory." a
DEFINE_integer devserver_port 8080 \
  "Port to use for devserver."
DEFINE_boolean for_vm ${FLAGS_FALSE} "Image is for a vm."
DEFINE_string image "" \
  "Update with this image path that is in this source checkout." i
DEFINE_string src_image "" \
  "Create a delta update by passing in the image on the remote machine."
DEFINE_boolean update_stateful ${FLAGS_TRUE} \
  "Perform update of stateful partition e.g. /var /usr/local."
DEFINE_string update_url "" "Full url of an update image."

# Flags for stateful update.
DEFINE_string stateful_update_flag "" \
  "Flag to pass to stateful update e.g. old, clean, etc." s

UPDATER_BIN="/usr/bin/update_engine_client"
UPDATER_IDLE="UPDATE_STATUS_IDLE"
UPDATER_NEED_REBOOT="UPDATE_STATUS_UPDATED_NEED_REBOOT"
UPDATER_UPDATE_CHECK="UPDATE_STATUS_CHECKING_FOR_UPDATE"
UPDATER_DOWNLOADING="UPDATE_STATUS_DOWNLOADING"

IMAGE_PATH=""

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

# Returns the hostname of this machine.
# It tries to find the ipaddress using ifconfig, however, it will
# default to $HOSTNAME on failure.  We try to use the ip address first as
# some targets may have dns resolution issues trying to contact back
# to us.
function get_hostname {
  local hostname
  # Try to parse ifconfig for ip address
  hostname=$(ifconfig eth0 \
      | grep 'inet addr' \
      | sed 's/.\+inet addr:\(\S\+\).\+/\1/') || hostname=${HOSTNAME}
  echo ${hostname}
}

# Reinterprets path from outside the chroot for use inside.
# Returns "" if "" given.
# $1 - The path to reinterpret.
function reinterpret_path_for_chroot() {
  if [ -z "${1}" ]; then
    echo ""
  else
    local path_abs_path=$(readlink -f "${1}")
    local gclient_root_abs_path=$(readlink -f "${GCLIENT_ROOT}")

    # Strip the repository root from the path.
    local relative_path=$(echo ${path_abs_path} \
        | sed s:${gclient_root_abs_path}/::)

    if [ "${relative_path}" = "${path_abs_path}" ]; then
      die "Error reinterpreting path.  Path ${1} is not within source tree."
    fi

    # Prepend the chroot repository path.
    echo "/home/${USER}/trunk/${relative_path}"
  fi
}

function start_dev_server {
  kill_all_devservers
  local devserver_flags="--pregenerate_update"
  # Parse devserver flags.
  if [ -n "${FLAGS_image}" ]; then
    devserver_flags="${devserver_flags} \
        --image $(reinterpret_path_for_chroot ${FLAGS_image})"
    IMAGE_PATH="${FLAGS_image}"
  elif [ -n "${FLAGS_archive_dir}" ]; then
    devserver_flags="${devserver_flags} \
        --archive_dir $(reinterpret_path_for_chroot ${FLAGS_archive_dir}) -t"
    IMAGE_PATH="${FLAGS_archive_dir}/chromiumos_test_image.bin"
  else
    # IMAGE_PATH should be the newest image and learn the board from
    # the target.
    FLAGS_board=""
    learn_board
    IMAGE_PATH="$($(dirname "$0")/get_latest_image.sh --board="${FLAGS_board}")"
    IMAGE_PATH="${IMAGE_PATH}/chromiumos_image.bin"
  fi

  [ ${FLAGS_for_vm} -eq ${FLAGS_TRUE} ] && \
      devserver_flags="${devserver_flags} --for_vm"

  devserver_flags="${devserver_flags} \
      --src_image=\"$(reinterpret_path_for_chroot ${FLAGS_src_image})\""

  info "Starting devserver with flags ${devserver_flags}"
  ./enter_chroot.sh "sudo ./start_devserver ${devserver_flags} \
       --client_prefix=ChromeOSUpdateEngine \
       --board=${FLAGS_board} \
       --port=${FLAGS_devserver_port} > ${FLAGS_server_log} 2>&1" &

  info "Waiting on devserver to start"
  info "note: be patient as the server generates the update before starting."
  until netstat -anp 2>&1 | grep 0.0.0.0:${FLAGS_devserver_port} > /dev/null
  do
    sleep 5
    echo -n "."
  done
  echo ""
}

# Copies stateful update script which fetches the newest stateful update
# from the dev server and prepares the update. chromeos_startup finishes
# the update on next boot.
function run_stateful_update {
  local dev_url=$(get_devserver_url)
  local stateful_url=""
  local stateful_update_args=""

  # Parse stateful update flag.
  if [ -n "${FLAGS_stateful_update_flag}" ]; then
    stateful_update_args="${stateful_update_args} \
        --stateful_change ${FLAGS_stateful_update_flag}"
  fi

  # Assume users providing an update url are using an archive_dir path.
  if [ -n "${FLAGS_update_url}" ]; then
    stateful_url=$(echo ${dev_url} | sed -e "s/update/static\/archive/")
  else
    stateful_url=$(echo ${dev_url} | sed -e "s/update/static/")
  fi

  info "Starting stateful update using URL ${stateful_url}"

  # Copy over update script and run update.
  local dev_dir="${SCRIPTS_DIR}/../platform/dev"
  remote_cp_to "${dev_dir}/stateful_update" "/tmp"
  remote_sh "/tmp/stateful_update ${stateful_update_args} ${stateful_url}"
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
      devserver_url="http://$(get_hostname):${FLAGS_devserver_port}/update"
    else
      devserver_url="${FLAGS_update_url}"
    fi
  fi
  echo "${devserver_url}"
}

function truncate_update_log {
  remote_sh "> /var/log/update_engine.log"
}

function get_update_log {
  remote_sh "cat /var/log/update_engine.log"
  echo "${REMOTE_OUT}" > "${FLAGS_update_log}"
}


# Returns ${1} reported by the update client e.g. PROGRESS, CURRENT_OP.
function get_update_var {
  remote_sh "${UPDATER_BIN} --status 2> /dev/null |
      grep ${1} |
      cut -f 2 -d ="
  echo "${REMOTE_OUT}"
}

# Returns the current status / progress of the update engine.
# This is expected to run in its own thread.
function status_thread {
  local timeout=5
  # Let update engine receive call to ping the dev server.
  info "Devserver handling ping.  Check ${FLAGS_server_log} for more info."
  sleep ${timeout}

  # The devserver generates images when the update engine checks for updates.
  while [ $(get_update_var CURRENT_OP) = ${UPDATER_UPDATE_CHECK} ]; do
    echo -n "." && sleep ${timeout}
  done

  info "Update generated.  Update engine downloading update."
  while [ $(get_update_var CURRENT_OP) = ${UPDATER_DOWNLOADING} ]; do
    echo "Download progress $(get_update_var PROGRESS)" && sleep ${timeout}
  done

  info "Download complete."
}


function run_auto_update {
  # Truncate the update log so our log file is clean.
  truncate_update_log

  local update_args="$(get_update_args "$(get_devserver_url)")"
  info "Starting update using args ${update_args}"

  # Sets up a secondary thread to track the update progress.
  status_thread &
  local status_thread_pid=$!
  trap "kill ${status_thread_pid} && cleanup" EXIT

  # Actually run the update.  This is a blocking call.
  remote_sh "${UPDATER_BIN} ${update_args}"

  # Clean up secondary thread.
  ! kill ${status_thread_pid} 2> /dev/null
  trap cleanup EXIT

  # We get the log file now.
  get_update_log

  local update_status="$(get_update_var CURRENT_OP)"
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

function verify_image {
  info "Verifying image."
  "${SCRIPTS_DIR}/mount_gpt_image.sh" --from "$(dirname ${IMAGE_PATH})" \
                     --image "$(basename ${IMAGE_PATH})" \
                     --read_only

  local lsb_release=$(cat /tmp/m/etc/lsb-release)
  info "Verifying image with release:"
  echo ${lsb_release}

  "${SCRIPTS_DIR}/mount_gpt_image.sh" --unmount

  remote_sh "cat /etc/lsb-release"
  info "Remote image reports:"
  echo ${REMOTE_OUT}

  if [ "${lsb_release}" = "${REMOTE_OUT}" ]; then
    info "Update was successful and image verified as ${lsb_release}."
    return 0
  else
    warn "Image verification failed."
    return 1
  fi
}

function main() {
  assert_outside_chroot

  cd $(dirname "$0")

  FLAGS "$@" || exit 1
  eval set -- "${FLAGS_ARGV}"

  set -e

  if [ ${FLAGS_verify} -eq ${FLAGS_TRUE} ] && \
      [ -n "${FLAGS_update_url}" ]; then
    warn "Verify is not compatible with setting an update url."
    FLAGS_verify=${FLAGS_FALSE}
  fi

  trap cleanup EXIT

  TMP=$(mktemp -d /tmp/image_to_live.XXXX)

  remote_access_init

  if [ "$(get_update_var CURRENT_OP)" != "${UPDATER_IDLE}" ]; then
    warn "Machine is in a bad state.  Rebooting it now."
    remote_reboot
  fi

  if [ -z "${FLAGS_update_url}" ]; then
    # Start local devserver if no update url specified.
    start_dev_server
  fi

  if [ ${FLAGS_update} -eq ${FLAGS_TRUE} ] && ! run_auto_update; then
    warn "Dumping update_engine.log for debugging and/or bug reporting."
    tail -n 200 "${FLAGS_update_log}" >&2
    die "Update was not successful."
  fi

  if [ ${FLAGS_update_stateful} -eq ${FLAGS_TRUE} ] && \
      ! run_stateful_update; then
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
  if [ ${FLAGS_verify} -eq ${FLAGS_TRUE} ]; then
    verify_image
  else
    local release_description=$(echo ${REMOTE_OUT} | cut -d '=' -f 2)
    info "Update was successful and rebooted to $release_description"
  fi

  print_time_elapsed

  exit 0
}

main $@
