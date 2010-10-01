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
      echo "Using a pre-created KVM instance specified by ${FLAGS_kvm_pid}."
    else
      # Let's be safe in case they specified a file that isn't a pid file.
      echo "File ${KVM_PID_FILE} exists but specified pid doesn't."
      exit 1
    fi
  else
    # No pid specified by PID file.  Let's create a VM instance in this case.
    echo "Starting a KVM instance"
    local nographics=""
    local usesnapshot=""
    if [ ${FLAGS_no_graphics} -eq ${FLAGS_TRUE} ]; then
      nographics="-nographic"
    fi

    if [ ${FLAGS_snapshot} -eq ${FLAGS_TRUE} ]; then
      snapshot="-snapshot"
    fi

    sudo kvm -m 1024 \
      -vga std \
      -pidfile "${KVM_PID_FILE}" \
      -daemonize \
      -net nic \
      ${nographics} \
      ${snapshot} \
      -net user,hostfwd=tcp::${FLAGS_ssh_port}-:22 \
      -hda "${1}"
  fi
}

function stop_kvm() {
  if [ "${FLAGS_persist}" -eq "${FLAGS_TRUE}" ]; then
    echo "Persist requested.  Use --ssh_port ${FLAGS_ssh_port} " \
      "--kvm_pid ${KVM_PID_FILE} to re-connect to it."
  else
    echo "Stopping the KVM instance"
    local pid=$(get_pid)
    echo "Killing ${pid}"
    sudo kill ${pid}
    sudo rm "${KVM_PID_FILE}"
  fi
}
