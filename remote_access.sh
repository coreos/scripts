# Copyright (c) 2009 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Library for setting up remote access and running remote commands.

DEFAULT_PRIVATE_KEY="${GCLIENT_ROOT}/src/scripts/mod_for_test_scripts/\
ssh_keys/testing_rsa"

DEFINE_string remote "" "remote hostname/IP of running Chromium OS instance"
DEFINE_string private_key "$DEFAULT_PRIVATE_KEY" \
  "Private key of root account on remote host"
DEFINE_integer ssh_port 22 \
  "SSH port of the remote machine running Chromium OS instance"

# Copies $1 to $2 on remote host
function remote_cp_to() {
  REMOTE_OUT=$(scp -P ${FLAGS_ssh_port} -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=$TMP_KNOWN_HOSTS -o ConnectTimeout=120 \
    -i $TMP_PRIVATE_KEY $1 root@$FLAGS_remote:$2)
  return ${PIPESTATUS[0]}
}

# Copies a list of remote files specified in file $1 to local location
# $2.  Directory paths in $1 are collapsed into $2.
function remote_rsync_from() {
  rsync -e "ssh -p ${FLAGS_ssh_port} -o StrictHostKeyChecking=no \
             -o UserKnownHostsFile=$TMP_KNOWN_HOSTS -o ConnectTimeout=120 \
             -i $TMP_PRIVATE_KEY" \
    --no-R --files-from=$1 root@${FLAGS_remote}:/ $2
}

function _verbose_remote_sh() {
  REMOTE_OUT=$(ssh -vp ${FLAGS_ssh_port} -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=$TMP_KNOWN_HOSTS -o ConnectTimeout=120 \
    -i $TMP_PRIVATE_KEY root@$FLAGS_remote "$@")
  return ${PIPESTATUS[0]}
}

function _non_verbose_remote_sh() {
  REMOTE_OUT=$(ssh -p ${FLAGS_ssh_port} -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=$TMP_KNOWN_HOSTS -o ConnectTimeout=120 \
    -i $TMP_PRIVATE_KEY root@$FLAGS_remote "$@")
  return ${PIPESTATUS[0]}
}

# Wrapper for ssh that runs the commmand given by the args on the remote host
# If an ssh error occurs, re-runs the ssh command with verbose flag set.
function remote_sh() {
  local ssh_status=0
  _non_verbose_remote_sh "$@" || ssh_status=$?
  # 255 indicates an ssh error.
  if [ ${ssh_status} -eq 255 ]; then
    _verbose_remote_sh "$@"
  else
    return ${ssh_status}
  fi
}

function remote_sh_raw() {
  ssh -p ${FLAGS_ssh_port} -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=$TMP_KNOWN_HOSTS -o ConnectTimeout=120 \
    -i $TMP_PRIVATE_KEY $EXTRA_REMOTE_SH_ARGS root@$FLAGS_remote "$@"
  return $?
}

function remote_sh_allow_changed_host_key() {
  rm -f $TMP_KNOWN_HOSTS
  remote_sh "$@"
}

function set_up_remote_access() {
  cp $FLAGS_private_key $TMP_PRIVATE_KEY
  chmod 0400 $TMP_PRIVATE_KEY

  # Verify the client is reachable before continuing
  local output
  local status=0
  if output=$(remote_sh "true" 2>&1); then
    :
  else
    status=$?
    echo "Could not initiate first contact with remote host"
    echo "$output"
  fi
  return $status
}

# Ask the target what board it is
function learn_board() {
  [ -n "${FLAGS_board}" ] && return
  remote_sh grep CHROMEOS_RELEASE_BOARD /etc/lsb-release
  FLAGS_board=$(echo "${REMOTE_OUT}" | cut -d '=' -f 2)
  if [ -z "${FLAGS_board}" ]; then
    error "Board required"
    exit 1
  fi
  info "Target reports board is ${FLAGS_board}"
}

function learn_arch() {
  [ -n "${FLAGS_arch}" ] && return
  remote_sh uname -m
  FLAGS_arch=$(echo "${REMOTE_OUT}" | sed -e s/armv7l/arm/ -e s/i686/x86/ )
  if [ -z "${FLAGS_arch}" ]; then
    error "Arch required"
    exit 1
  fi
  info "Target reports arch is ${FLAGS_arch}"
}

# Checks to see if pid $1 is running.
function is_pid_running() {
  ps -p ${1} 2>&1 > /dev/null
}

# Wait function given an additional timeout argument.
# $1 - pid to wait on.
# $2 - timeout to wait for.
function wait_with_timeout() {
  local pid=$1
  local timeout=$2
  local -r TIMEOUT_INC=1
  local current_timeout=0
  while is_pid_running ${pid} && [ ${current_timeout} -lt ${timeout} ]; do
    sleep ${TIMEOUT_INC}
    current_timeout=$((current_timeout + TIMEOUT_INC))
  done
  ! is_pid_running ${pid}
}

# Checks to see if a machine has rebooted using the presence of a tmp file.
function check_if_rebooted() {
  local output_file="${TMP}/output"
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
        sleep .5
      else
        info "Rebooted and responding"
        break
      fi
    fi
  done
}

function remote_reboot() {
  info "Rebooting."
  remote_sh "touch /tmp/awaiting_reboot; reboot"
  while true; do
    check_if_rebooted &
    local pid=$!
    wait_with_timeout ${pid} 30 && break
    ! kill -9 ${pid} 2> /dev/null
  done
}

# Called by clients before exiting.
# Part of the remote_access.sh interface but now empty.
function cleanup_remote_access() {
  true
}

function remote_access_init() {
  TMP_PRIVATE_KEY=$TMP/private_key
  TMP_KNOWN_HOSTS=$TMP/known_hosts
  if [ -z "$FLAGS_remote" ]; then
    echo "Please specify --remote=<IP-or-hostname> of the Chromium OS instance"
    exit 1
  fi
  set_up_remote_access
}
