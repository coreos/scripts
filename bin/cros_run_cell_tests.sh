#!/bin/bash

# Copyright (c) 2011 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Wrapper script around run_remote_tests.sh that knows how to find
# device test cells.

# Right now this is mostly a modified copy of cros_run_wifi_tests.sh.

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
#  - Put the hostname into "scripts/.default_cell_test_lab"
#  - Create an /etc/hosts entry in your chroot for that hostname
#    (if it isn't findable via DNS)
if [ -f "$GCLIENT_ROOT/src/scripts/.default_cell_test_lab" ] ; then
  DEFAULT_LAB=`cat "$GCLIENT_ROOT/src/scripts/.default_cell_test_lab"`
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

# These flags are specific to run_cell_tests
DEFINE_string cell "" "Cell name to perform test on"
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

if [ -n "${FLAGS_url}" ]; then
  lab_url=${FLAGS_url}
elif [ -n "${FLAGS_lab}" ]; then
  lab_url="http://${FLAGS_lab}:8080/cells.json"
else
  echo ">>> No lab server specified.  Please use --lab or --url options"
  exit 1
fi

if [ -a "${FLAGS_cell}" ]; then
  echo ">>> No cell specified.  Please use --cell option"
  exit 1
fi

append_arg "config_url=$lab_url";
append_arg "config_cell=$FLAGS_cell";

remote=$1
shift
for arg in "$@"; do
    append_arg $arg
done

eval "exec ${SCRIPTS_DIR}/run_remote_tests.sh \
      --args=\"${run_remote_args}\" --remote=${remote} $run_remote_flags \
      $FLAGS_ARGV"
