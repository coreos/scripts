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
  REMOTE_OUT=$(scp -P ${FLAGS_ssh_port} -o StrictHostKeyChecking=no -o \
    UserKnownHostsFile=$TMP_KNOWN_HOSTS $1 root@$FLAGS_remote:$2)
  return ${PIPESTATUS[0]}
}

# Copies a list of remote files specified in file $1 to local location
# $2.  Directory paths in $1 are collapsed into $2.
function remote_rsync_from() {
  rsync -e "ssh -p ${FLAGS_ssh_port} -o StrictHostKeyChecking=no -o \
            UserKnownHostsFile=$TMP_KNOWN_HOSTS" --no-R \
    --files-from=$1 root@${FLAGS_remote}:/ $2
}

function remote_sh() {
  REMOTE_OUT=$(ssh -p ${FLAGS_ssh_port} -o StrictHostKeyChecking=no -o \
    UserKnownHostsFile=$TMP_KNOWN_HOSTS root@$FLAGS_remote "$@")
  return ${PIPESTATUS[0]}
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
  is_pid_running ${pid}
}

# Robust ping that will monitor ssh and not hang even if ssh hangs.
function ping_ssh() {
  remote_sh "true" &
  local pid=$!
  wait_with_timeout ${pid} 5
  ! kill -9 ${pid} 2> /dev/null
}

function remote_sh_allow_changed_host_key() {
  rm -f $TMP_KNOWN_HOSTS
  ping_ssh
  remote_sh "$@"
}

function set_up_remote_access() {
  if [ -z "$SSH_AGENT_PID" ]; then
    eval $(ssh-agent)
    OWN_SSH_AGENT=1
  else
    OWN_SSH_AGENT=0
  fi
  cp $FLAGS_private_key $TMP_PRIVATE_KEY
  chmod 0400 $TMP_PRIVATE_KEY
  ssh-add $TMP_PRIVATE_KEY

  # Verify the client is reachable before continuing
  echo "Initiating first contact with remote host"
  remote_sh "true"
  echo "Connection OK"
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

function cleanup_remote_access() {
  # Call this function from the exit trap of the main script.
  # Iff we started ssh-agent, be nice and clean it up.
  # Note, only works if called from the main script - no subshells.
  if [[ 1 -eq ${OWN_SSH_AGENT} ]]
  then
    kill ${SSH_AGENT_PID} 2>/dev/null
    unset SSH_AGENT_PID SSH_AUTH_SOCK
  fi
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
