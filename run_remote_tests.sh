#!/bin/bash

# Copyright (c) 2009 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Script to run client or server tests on a live remote image.

# Load common constants.  This should be the first executable line.
# The path to common.sh should be relative to your script's location.

. "$(dirname $0)/common.sh"
. "$(dirname $0)/autotest_lib.sh"
. "$(dirname $0)/remote_access.sh"

DEFAULT_OUTPUT_FILE=test-output-$(date '+%Y%m%d.%H%M%S')

DEFINE_boolean cleanup ${FLAGS_TRUE} "Clean up temp directory"
DEFINE_integer iterations 1 "Iterations to run every top level test" i
DEFINE_string output_file "${DEFAULT_OUTPUT_FILE}" "Test run output" o
DEFINE_boolean verbose ${FLAGS_FALSE} "Show verbose autoserv output" v
DEFINE_boolean update_db ${FLAGS_FALSE} "Put results in autotest database" u
DEFINE_string machine_desc "" "Machine description used in database"
DEFINE_string build_desc "" "Build description used in database"
DEFINE_string chroot_dir "${DEFAULT_CHROOT_DIR}" "alternate chroot location" c
DEFINE_string results_dir_root "" "alternate root results directory"

function cleanup() {
  if [[ $FLAGS_cleanup -eq ${FLAGS_TRUE} ]]; then
    rm -rf "${TMP}"
  else
    echo "Left temporary files at ${TMP}"
  fi
  cleanup_remote_access
}

# Returns an error if the test_result_file has text which indicates
# the test was not run successfully.
# Arguments:
#   $1 - file name of autotest status for to check for success
# Returns:
#   None
function is_successful_test() {
  local file="$1"
  # To be successful, must not have FAIL or BAD in the file.
  if egrep -q "(BAD|FAIL)" "${file}"; then
    return 1
  fi
  # To be successful, must have GOOD in the file.
  if ! grep -q GOOD "${file}"; then
    return 1
  fi
  return 0
}

# Removes single quotes around parameter
# Arguments:
#   $1 - string which optionally has surrounding quotes
# Returns:
#   None, but prints the string without quotes.
function remove_quotes() {
  echo "$1" | sed -e "s/^'//; s/'$//"
}

# Adds attributes to all tests run
# Arguments:
#   $1 - results directory
#   $2 - attribute name (key)
#   $3 - attribute value (value)
function add_test_attribute() {
  local results_dir="$1"
  local attribute_name="$2"
  local attribute_value="$3"
  if [[ -z "$attribute_value" ]]; then
    return;
  fi

  for status_file in $(echo "${results_dir}"/*/status); do
    local keyval_file=$(dirname $status_file)/keyval
    echo "Updating ${keyval_file}"
    echo "${attribute_name}=${attribute_value}" >> "${keyval_file}"
  done
}

function main() {
  assert_outside_chroot

  cd $(dirname "$0")

  FLAGS "$@" || exit 1

  if [[ -z "${FLAGS_ARGV}" ]]; then
    echo "Please specify tests to run, like:"
    echo "  $0 --remote=MyMachine SystemBootPerf"
    exit 1
  fi

  local parse_cmd="$(dirname $0)/../third_party/autotest/files/tko/parse.py"

  if [[ ${FLAGS_update_db} -eq ${FLAGS_TRUE} && ! -x "${parse_cmd}" ]]; then
    echo "Cannot find parser ${parse_cmd}"
    exit 1
  fi

  set -e

  local autotest_dir="${DEFAULT_CHROOT_DIR}/usr/local/autotest"

  # Set global TMP for remote_access.sh's sake
  TMP=$(mktemp -d /tmp/run_remote_tests.XXXX)

  rm -f "${FLAGS_output_file}"

  trap cleanup EXIT

  # Always copy into installed autotest directory.  This way if a user
  # is just modifying scripts, they take effect without having to wait
  # for the laborious build_autotest.sh command.
  local original="${GCLIENT_ROOT}/src/third_party/autotest/files"
  update_chroot_autotest "${original}"

  local autoserv="${autotest_dir}/server/autoserv"

  local control_files_to_run=""

  # Now search for tests which unambiguously include the given identifier
  local search_path=$(echo ${autotest_dir}/{client,server}/{tests,site_tests})
  for test_request in $FLAGS_ARGV; do
    test_request=$(remove_quotes "${test_request}")
    ! finds=$(find ${search_path} -type f -name control | \
      egrep "${test_request}")
    if [[ -z "${finds}" ]]; then
      echo "Can not find match for ${test_request}"
      exit 1
    fi
    local matches=$(echo "${finds}" | wc -l)
    if [[ ${matches} -gt 1 ]]; then
      echo "${test_request} is ambiguous:"
      echo "${finds}"
      exit 1
    fi
    for i in $(seq 1 $FLAGS_iterations); do
      control_files_to_run="${control_files_to_run} '${finds}'"
    done
  done

  echo "Running the following control files: ${control_files_to_run}"

  remote_access_init

  # Set the default machine description to the machine's IP
  if [[ -z "${FLAGS_machine_desc}" ]]; then
    FLAGS_machine_desc="${FLAGS_remote}"
  fi

  if [[ -z "${FLAGS_results_dir_root}" ]]; then
    FLAGS_results_dir_root="${TMP}"
  fi

  mkdir -p "${FLAGS_results_dir_root}"

  for control_file in ${control_files_to_run}; do
    # Assume a line starts with TEST_TYPE =
    control_file=$(remove_quotes "${control_file}")
    local type=$(egrep '^\s*TEST_TYPE\s*=' "${control_file}" | head -1)
    type=$(python -c "${type}; print TEST_TYPE.lower()")
    local option
    if [ "${type}" == "client" ]; then
      option="-c"
    elif [ "${type}" == "server" ]; then
     option="-s"
    else
      echo "Unknown type of test (${type}) in ${control_file}"
      exit 1
    fi
    echo "Running ${type} test ${control_file}"
    local short_name=$(basename $(dirname "${control_file}"))
    local start_time=$(date '+%s')
    local results_dir_name="${short_name},${FLAGS_machine_desc},${start_time}"
    local results_dir="${FLAGS_results_dir_root}/${results_dir_name}"
    rm -rf "${results_dir}"
    local verbose=""
    if [[ ${FLAGS_verbose} -eq $FLAGS_TRUE ]]; then
      verbose="--verbose"
    fi

    ${autoserv} -m "${FLAGS_remote}" "${option}" "${control_file}" \
      -r "${results_dir}" ${verbose}
    local test_status="${results_dir}/status"
    local test_result_dir="${results_dir}/${short_name}"
    local keyval_file="${test_result_dir}/results/keyval"
    if is_successful_test "${test_status}"; then
      echo "${control_file} succeeded." | tee -a "${FLAGS_output_file}"
      if [[ -f "${keyval_file}" ]]; then
        echo "Keyval was:" | tee -a "${FLAGS_output_file}"
        cat "${keyval_file}" | tee -a "${FLAGS_output_file}"
      fi
    else
      echo "${control_file} failed:" | tee -a "${FLAGS_output_file}"
      cat "${test_status}" | tee -a "${FLAGS_output_file}"
        # Leave around output directory if the test failed.
      FLAGS_cleanup=${FLAGS_FALSE}
    fi
    local end_time=$(date '+%s')

    # Update the database with results.
    if [[ ${FLAGS_update_db} -eq ${FLAGS_TRUE} ]]; then
      add_test_attribute "${results_dir}" machine-desc "${FLAGS_machine_desc}"
      add_test_attribute "${results_dir}" build-desc "${FLAGS_build_desc}"
      add_test_attribute "${results_dir}" server-start-time "${start_time}"
      add_test_attribute "${results_dir}" server-end-time "${end_time}"
      if ! "${parse_cmd}" -o "${results_dir}"; then
        echo "Parse failed." | tee -a "${FLAGS_output_file}"
        FLAGS_cleanup=${FLAGS_FALSE}
      fi
    fi
  done

  echo "Output stored to ${FLAGS_output_file}"
}

main $@
