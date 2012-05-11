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

SSH_CONNECT_SETTINGS="-o Protocol=2 -o ConnectTimeout=30 \
  -o ConnectionAttempts=4 -o ServerAliveInterval=10 \
  -o ServerAliveCountMax=3 -o StrictHostKeyChecking=no"

# Copies $1 to $2 on remote host
remote_cp_to() {
  REMOTE_OUT=$(scp -P ${FLAGS_ssh_port} $SSH_CONNECT_SETTINGS \
    -o UserKnownHostsFile=$TMP_KNOWN_HOSTS -i $TMP_PRIVATE_KEY $1 \
    root@$FLAGS_remote:$2)
  return ${PIPESTATUS[0]}
}

# Copies a list of remote files specified in file $1 to local location
# $2.  Directory paths in $1 are collapsed into $2.
remote_rsync_from() {
  rsync -e "ssh -p ${FLAGS_ssh_port} $SSH_CONNECT_SETTINGS \
             -o UserKnownHostsFile=$TMP_KNOWN_HOSTS -i $TMP_PRIVATE_KEY" \
    --no-R --files-from=$1 root@${FLAGS_remote}:/ $2
}

_remote_sh() {
  REMOTE_OUT=$(ssh -p ${FLAGS_ssh_port} $SSH_CONNECT_SETTINGS \
    -o UserKnownHostsFile=$TMP_KNOWN_HOSTS -i $TMP_PRIVATE_KEY \
    root@$FLAGS_remote "$@")
  return ${PIPESTATUS[0]}
}

# Wrapper for ssh that runs the commmand given by the args on the remote host
# If an ssh error occurs, re-runs the ssh command.
remote_sh() {
  local ssh_status=0
  _remote_sh "$@" || ssh_status=$?
  # 255 indicates an ssh error.
  if [ ${ssh_status} -eq 255 ]; then
    _remote_sh "$@"
  else
    return ${ssh_status}
  fi
}

remote_sh_raw() {
  ssh -p ${FLAGS_ssh_port} $SSH_CONNECT_SETTINGS \
    -o UserKnownHostsFile=$TMP_KNOWN_HOSTS -i $TMP_PRIVATE_KEY \
    $EXTRA_REMOTE_SH_ARGS root@$FLAGS_remote "$@"
  return $?
}

remote_sh_allow_changed_host_key() {
  rm -f $TMP_KNOWN_HOSTS
  remote_sh "$@"
}

set_up_remote_access() {
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
learn_board() {
  [ -n "${FLAGS_board}" ] && return
  remote_sh grep CHROMEOS_RELEASE_BOARD /etc/lsb-release
  FLAGS_board=$(echo "${REMOTE_OUT}" | cut -d '=' -f 2)
  if [ -z "${FLAGS_board}" ]; then
    error "Board required"
    exit 1
  fi
  info "Target reports board is ${FLAGS_board}"
}

learn_arch() {
  [ -n "${FLAGS_arch}" ] && return
  remote_sh uname -m
  FLAGS_arch=$(echo "${REMOTE_OUT}" | sed -e s/armv7l/arm/ -e s/i686/x86/ )
  if [ -z "${FLAGS_arch}" ]; then
    error "Arch required"
    exit 1
  fi
  info "Target reports arch is ${FLAGS_arch}"
}

# Checks whether a remote device has rebooted successfully.
#
# This uses a rapidly-retried SSH connection, which will wait for at most
# about ten seconds. If the network returns an error (e.g. host unreachable)
# the actual delay may be shorter.
#
# Return values:
#   0: The device has rebooted successfully
#   1: The device has not yet rebooted
#   255: Unable to communicate with the device
_check_if_rebooted() {
  (
    # In my tests SSH seems to be waiting rather longer than would be expected
    # from these parameters. These values produce a ~10 second wait.
    # (in a subshell to avoid clobbering the global settings)
    SSH_CONNECT_SETTINGS="$(sed \
      -e 's/\(ConnectTimeout\)=[0-9]*/\1=2/' \
      -e 's/\(ConnectionAttempts\)=[0-9]*/\1=2/' \
      <<<"${SSH_CONNECT_SETTINGS}")"
    remote_sh_allow_changed_host_key -q -- '[ ! -e /tmp/awaiting_reboot ]'
  )
}

# Triggers a reboot on a remote device and waits for it to complete.
#
# This function will not return until the SSH server on the remote device
# is available after the reboot.
#
remote_reboot() {
  info "Rebooting ${FLAGS_remote}..."
  remote_sh "touch /tmp/awaiting_reboot; reboot"
  local start_time=${SECONDS}

  # Wait for five seconds before we start polling
  sleep 5

  # Add a hard timeout of 5 minutes before giving up.
  local timeout=300
  local timeout_expiry=$(( start_time + timeout ))
  while [ ${SECONDS} -lt ${timeout_expiry} ]; do
    # Used to throttle the loop -- see step_remaining_time at the bottom.
    local step_start_time=${SECONDS}

    local status=0
    _check_if_rebooted || status=$?

    local elapsed=$(( SECONDS - start_time ))
    case ${status} in
      0) printf '   %4ds: reboot complete\n' ${elapsed} >&2 ; return 0 ;;
      1) printf '   %4ds: device has not yet shut down\n' ${elapsed} >&2 ;;
      255) printf '   %4ds: can not connect to device\n' ${elapsed} >&2 ;;
      *) die "  internal error" ;;
    esac

    # To keep the loop from spinning too fast, delay until it has taken at
    # least five seconds. When we are actively trying SSH connections this
    # should never happen.
    local step_remaining_time=$(( step_start_time + 5 - SECONDS ))
    if [ ${step_remaining_time} -gt 0 ]; then
      sleep ${step_remaining_time}
   fi
  done
  die "Reboot has not completed after ${timeout} seconds; giving up."
}

# Called by clients before exiting.
# Part of the remote_access.sh interface but now empty.
cleanup_remote_access() {
  true
}

remote_access_init() {
  TMP_PRIVATE_KEY=$TMP/private_key
  TMP_KNOWN_HOSTS=$TMP/known_hosts
  if [ -z "$FLAGS_remote" ]; then
    echo "Please specify --remote=<IP-or-hostname> of the Chromium OS instance"
    exit 1
  fi
  set_up_remote_access
}
