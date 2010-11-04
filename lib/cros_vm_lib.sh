# Copyright (c) 2010 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.
#
# Common vm functions for use in crosutils.

DEFINE_string kvm_pid "" \
  "Use this pid file.  If it exists and is set, use the vm specified by pid."
DEFINE_boolean no_graphics ${FLAGS_FALSE} "Runs the KVM instance silently."
DEFINE_boolean persist "${FLAGS_FALSE}" "Persist vm."
DEFINE_boolean snapshot ${FLAGS_FALSE} "Don't commit changes to image."
DEFINE_integer ssh_port 9222 "Port to tunnel ssh traffic over."

KVM_PID_FILE=/tmp/kvm.$$.pid
LIVE_VM_IMAGE=

function get_pid() {
  sudo cat "${KVM_PID_FILE}"
}

# TODO(rtc): These flags assume that we'll be using KVM on Lucid and won't work
# on Hardy.
# $1: Path to the virtual image to start.
function start_kvm() {
  # Override default pid file.
  [ -n "${FLAGS_kvm_pid}" ] && KVM_PID_FILE=${FLAGS_kvm_pid}
  if [ -e "${KVM_PID_FILE}" ]; then
    local pid=$(get_pid)
    # Check if the process exists.
    if ps -p ${pid} > /dev/null ; then
      echo "Using a pre-created KVM instance specified by ${FLAGS_kvm_pid}." >&2
    else
      # Let's be safe in case they specified a file that isn't a pid file.
      echo "File ${KVM_PID_FILE} exists but specified pid doesn't." >&2
      exit 1
    fi
  else
    # No pid specified by PID file.  Let's create a VM instance in this case.
    echo "Starting a KVM instance" >&2
    local nographics=""
    local usesnapshot=""
    if [ ${FLAGS_no_graphics} -eq ${FLAGS_TRUE} ]; then
      nographics="-nographic -serial none"
    fi

    if [ ${FLAGS_snapshot} -eq ${FLAGS_TRUE} ]; then
      snapshot="-snapshot"
    fi

    sudo kvm -m 1024 \
      -vga std \
      -pidfile "${KVM_PID_FILE}" \
      -daemonize \
      -net nic,model=e1000 \
      ${nographics} \
      ${snapshot} \
      -net user,hostfwd=tcp::${FLAGS_ssh_port}-:22 \
      -hda "${1}"

    LIVE_VM_IMAGE="${1}"
  fi
}

# Checks to see if we can access the target virtual machine with ssh.
function ssh_ping() {
  "$(dirname $0)"/../ssh_test.sh \
    --ssh_port=${FLAGS_ssh_port} \
    --remote=127.0.0.1 >&2
}

# Tries to ssh into live image $1 times.  After first failure, a try involves
# shutting down and restarting kvm.
function retry_until_ssh() {
  local can_ssh_into=1
  local retries=0
  ssh_ping && can_ssh_into=0

  while [ ${can_ssh_into} -eq 1 ] && [ ${retries} -lt ${1} ]; do
    echo "Failed to connect to virtual machine, retrying ... " >&2
    stop_kvm || echo "Could not stop kvm.  Retrying anyway." >&2
    start_kvm "${LIVE_VM_IMAGE}"
    ssh_ping && can_ssh_into=0
    retries=$((retries + 1))
  done
  return ${can_ssh_into}
}

function stop_kvm() {
  if [ "${FLAGS_persist}" -eq "${FLAGS_TRUE}" ]; then
    echo "Persist requested.  Use --ssh_port ${FLAGS_ssh_port} " \
      "--kvm_pid ${KVM_PID_FILE} to re-connect to it." >&2
  else
    echo "Stopping the KVM instance" >&2
    local pid=$(get_pid)
    if [ -n "${pid}" ]; then
      echo "Killing ${pid}" >&2
      sudo kill ${pid}
      sudo rm "${KVM_PID_FILE}"
    else
      echo "No kvm pid found to stop." >&2
      return 1
    fi
  fi
}
