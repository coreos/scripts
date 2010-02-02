# Copyright (c) 2009 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Library for setting up remote access and running remote commands.

DEFAULT_PRIVATE_KEY="${GCLIENT_ROOT}/src/scripts/mod_for_test_scripts/\
ssh_keys/testing_rsa"

DEFINE_string remote "" "remote hostname/IP of running Chromium OS instance"
DEFINE_string private_key "$DEFAULT_PRIVATE_KEY" \
  "Private key of root account on remote host"

function remote_sh() {
  REMOTE_OUT=$(ssh  -o StrictHostKeyChecking=no -o \
    UserKnownHostsFile=$TMP_KNOWN_HOSTS root@$FLAGS_remote "$@")
  return ${PIPESTATUS[0]}
}

function remote_sh_allow_changed_host_key() {
  rm -f $TMP_KNOWN_HOSTS
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
