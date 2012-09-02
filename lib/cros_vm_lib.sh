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
DEFINE_string vnc "" "VNC Server to display to instead of SDL."

KVM_PID_FILE=/tmp/kvm.$$.pid
LIVE_VM_IMAGE=

if ! KVM_BINARY=$(which kvm 2> /dev/null); then
  if ! KVM_BINARY=$(which qemu-kvm 2> /dev/null); then
    die "no kvm binary found"
  fi
fi

get_pid() {
  sudo cat "${KVM_PID_FILE}"
}

# General purpose blocking kill on a pid.
# This function sends a specified kill signal [0-9] to a pid and waits for it
# die up to a given timeout.  It exponentially backs off it's timeout starting
# at 1 second.
# $1 the process id.
# $2 signal to send (-#).
# $3 max timeout in seconds.
# Returns 0 on success.
blocking_kill() {
  local timeout=1
  sudo kill -$2 $1
  while ps -p $1 > /dev/null && [ ${timeout} -le $3 ]; do
    sleep ${timeout}
    timeout=$((timeout*2))
  done
  ! ps -p ${1} > /dev/null
}

kvm_version_greater_equal() {
  local test_version="${1}"
  local kvm_version=$(kvm --version | sed -E 's/^.*version ([0-9\.]*) .*$/\1/')

  [ $(echo -e "${test_version}\n${kvm_version}" | sort -r -V | head -n 1) = \
    $kvm_version ]
}

# $1: Path to the virtual image to start.
start_kvm() {
  # Override default pid file.
  local start_vm=0
  [ -n "${FLAGS_kvm_pid}" ] && KVM_PID_FILE=${FLAGS_kvm_pid}
  if [ -f "${KVM_PID_FILE}" ]; then
    local pid=$(get_pid)
    # Check if the process exists.
    if ps -p ${pid} > /dev/null ; then
      echo "Using a pre-created KVM instance specified by ${FLAGS_kvm_pid}." >&2
      start_vm=1
    else
      # Let's be safe in case they specified a file that isn't a pid file.
      echo "File ${KVM_PID_FILE} exists but specified pid doesn't." >&2
    fi
  fi

  # No kvm specified by pid file found, start a new one.
  if [ ${start_vm} -eq 0 ]; then
    echo "Starting a KVM instance" >&2
    local nographics=""
    local usesnapshot=""
    if [ ${FLAGS_no_graphics} -eq ${FLAGS_TRUE} ]; then
      nographics="-nographic -serial none"
    fi
    if [ -n "${FLAGS_vnc}" ]; then
      nographics="-vnc ${FLAGS_vnc}"
    fi

    if [ ${FLAGS_snapshot} -eq ${FLAGS_TRUE} ]; then
      snapshot="-snapshot"
    fi

    local net_option="-net nic,model=virtio"
    if [ -f "$(dirname "$1")/.use_e1000" ]; then
      info "Detected older image, using e1000 instead of virtio."
      net_option="-net nic,model=e1000"
    fi

    local cache_type="writeback"
    if kvm_version_greater_equal "0.14"; then
      cache_type="unsafe"
    fi

    sudo "${KVM_BINARY}" -m 2G \
      -smp 4 \
      -vga std \
      -pidfile "${KVM_PID_FILE}" \
      -daemonize \
      ${net_option} \
      ${nographics} \
      ${snapshot} \
      -net user,hostfwd=tcp::${FLAGS_ssh_port}-:22 \
      -drive "file=${1},index=0,media=disk,cache=${cache_type}"

    info "KVM started with pid stored in ${KVM_PID_FILE}"
    LIVE_VM_IMAGE="${1}"
  fi
}

# Checks to see if we can access the target virtual machine with ssh.
ssh_ping() {
  # TODO(sosa): Remove outside chroot use once all callers work inside chroot.
  local cmd
  if [ $INSIDE_CHROOT -ne 1 ]; then
    cmd="${GCLIENT_ROOT}/src/scripts/ssh_test.sh"
  else
    cmd=/usr/lib/crosutils/ssh_test.sh
  fi
  "${cmd}" \
    --ssh_port=${FLAGS_ssh_port} \
    --remote=127.0.0.1 >&2
}

# Tries to ssh into live image $1 times.  After first failure, a try involves
# shutting down and restarting kvm.
retry_until_ssh() {
  local can_ssh_into=1
  local max_retries=3
  local retries=0
  ssh_ping && can_ssh_into=0

  while [ ${can_ssh_into} -eq 1 ] && [ ${retries} -lt ${max_retries} ]; do
    echo "Failed to connect to virtual machine, retrying ... " >&2
    stop_kvm || echo "Could not stop kvm.  Retrying anyway." >&2
    start_kvm "${LIVE_VM_IMAGE}"
    ssh_ping && can_ssh_into=0
    retries=$((retries + 1))
  done
  return ${can_ssh_into}
}

stop_kvm() {
  if [ "${FLAGS_persist}" -eq "${FLAGS_TRUE}" ]; then
    echo "Persist requested.  Use --ssh_port ${FLAGS_ssh_port} " \
      "--kvm_pid ${KVM_PID_FILE} to re-connect to it." >&2
  else
    echo "Stopping the KVM instance" >&2
    local pid=$(get_pid)
    if [ -n "${pid}" ]; then
      blocking_kill ${pid} 1 16 || blocking_kill ${pid} 9 1
      sudo rm "${KVM_PID_FILE}"
    else
      echo "No kvm pid found to stop." >&2
      return 1
    fi
  fi
}
