#!/bin/bash

# Copyright (c) 2009 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Wrapper script around run_remote_tests.sh that knows how to find
# device test cells.

# --- BEGIN COMMON.SH BOILERPLATE ---
# Load common CrOS utilities.  Inside the chroot this file is installed in
# /usr/lib/crosutils.  Outside the chroot we find it relative to the script's
# location.
find_common_sh() {
  local common_paths=(/usr/lib/crosutils "$(dirname "$(readlink -f "$0")")/..")
  local path

  SCRIPT_ROOT=
  for path in "${common_paths[@]}"; do
    if [ -r "${path}/common.sh" ]; then
      SCRIPT_ROOT=${path}
      break
    fi
  done
}

find_common_sh
. "${SCRIPT_ROOT}/common.sh" || (echo "Unable to load common.sh" && exit 1)
# --- END COMMON.SH BOILERPLATE ---

# Figure out the default chromelab server name.  In order for this to
# work correctly, you have to:
#
#  - Put the hostname into "scripts/.default_wifi_test_lab"
#  - Create an /etc/hosts entry in your chroot for that hostname
#    (if it isn't findable via DNS)
#  - Make sure you have created a wifi_testbed_${lab} file in the
#    ${autotest}/files/client/config/ directory
if [ -f "$GCLIENT_ROOT/src/scripts/.default_wifi_test_lab" ] ; then
  DEFAULT_LAB=`cat "$GCLIENT_ROOT/src/scripts/.default_wifi_test_lab"`
fi

# TODO(pstew) Since this is a wrapper script, we need to accept all
# arguments run_remote_tests does, plus a few more of our own.  This
# can lead to version skew issues

DEFINE_string args "" "Command line arguments for test, separated with comma" a
DEFINE_string board "" "The board for which you are building autotest"
DEFINE_string chroot "" "alternate chroot location" c
DEFINE_boolean cleanup ${FLAGS_FALSE} "Clean up temp directory"
DEFINE_string iterations "" "Iterations to run every top level test" i
DEFINE_string prepackaged_autotest "" "Use this prepackaged autotest dir"
DEFINE_string results_dir_root "" "alternate root results directory"
DEFINE_boolean verbose ${FLAGS_FALSE} "Show verbose autoserv output" v

# These flags are specific to run_wifi_tests
DEFINE_string cell "" "Cell number to perform test on"
DEFINE_string client "" "Host name or IP of device to perform test"
DEFINE_string lab "${DEFAULT_LAB}" "Lab machine to perform test on"
DEFINE_string url "" "URL to lab server config server"

FLAGS "$@" || exit 1

run_remote_flags=""
run_remote_args=${FLAGS_args}

append_flag () {
    local delim=''
    [ -n "${run_remote_flags}" ] && delim=' '
    run_remote_flags="${run_remote_flags}${delim}$*"
}

append_arg () {
    local delim=''
    [ -n "${run_remote_args}" ] && delim=' '
    run_remote_args="${run_remote_args}${delim}$*"
}

if [ -n "${FLAGS_board}" ]; then
  append_flag --board "'${FLAGS_board}'"
fi

if [ -n "${FLAGS_chroot}" ]; then
  append_flag --chroot "'${FLAGS_chroot}'"
fi

if [ "${FLAGS_cleanup}" -eq ${FLAGS_TRUE} ]; then
  append_flag --cleanup
fi

if [ -n "${FLAGS_iterations}" ]; then
  append_flag --iterations ${FLAGS_iterations}
fi

if [ -n "${FLAGS_prepackaged_autotest}" ]; then
  append_flag --prepackaged_autotest "'${FLAGS_prepackaged_autotest}'"
fi

if [ -n "${FLAGS_results_dir_root}" ]; then
  append_flag --results_dir_root "'${FLAGS_results_dir_root}'"
fi

if [ "${FLAGS_verbose}" -eq ${FLAGS_TRUE} ]; then
  append_flag --verbose
fi

# Parse our local args
if [ -n "${FLAGS_lab}" ] ; then
  # Add a config file for the lab if one isn't already set
  if ! expr "${run_remote_args}" : '.*config_file=' >/dev/null; then
    append_arg "config_file=wifi_testbed_${FLAGS_lab}"
  fi
fi

if [ -n "${FLAGS_url}" ] ; then
  lab_url=${FLAGS_url}
elif [ -n "${FLAGS_lab}" ] ; then
  lab_url="http://${FLAGS_lab}:8080/cells"
else
  echo ">>> No lab server specified.  Please use --lab or --url options"
  exit 1
fi

cell_no=0

# Retrieve the testbed config from the server and match either the client
# or the cell number to one of the entries
ret=$(curl -s $lab_url | \
while read line; do
  # Each line from the server is made up of:
  # client_name router_name server_name client_addr router_addr server_addr
  set $line
  if [ "${FLAGS_cell}" = "$cell_no" -o "${FLAGS_client}" = "$1" -o \
       "${FLAGS_client}" = "$4" ] ; then
    if [ "$5" = "0.0.0.0" -o "$4" = "0.0.0.0" ]; then
      # Error -- these should never be zeroes
      break
    fi
    echo "$4"
    echo "router_addr=$5"
    if [ "$6" != "0.0.0.0" ] ; then
      echo "server_addr=$6"
    fi
    break
  fi
  cell_no=$[cell_no + 1]
done)

if [ -z "$ret" ] ; then
  echo ">>> Cell or host not found at $lab_url"
  exit 1
fi

set $ret
remote=$1
shift
for arg in "$@"; do
    append_arg $arg
done

eval "exec ${SCRIPTS_DIR}/run_remote_tests.sh \
      --args=\"${run_remote_args}\" --remote=${remote} $run_remote_flags \
      $FLAGS_ARGV"
