#!/bin/bash

# Copyright (c) 2009 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Script to run client or server tests on a live remote image.

# Load common constants.  This should be the first executable line.
# The path to common.sh should be relative to your script's location.

. "$(dirname $0)/common.sh"
. "$(dirname $0)/remote_access.sh"

get_default_board

DEFINE_string args "" "Command line arguments for test, separated with comma" a
DEFINE_string board "$DEFAULT_BOARD" \
    "The board for which you are building autotest"
DEFINE_string chroot "${DEFAULT_CHROOT_DIR}" "alternate chroot location" c
DEFINE_boolean cleanup ${FLAGS_FALSE} "Clean up temp directory"
DEFINE_integer iterations 1 "Iterations to run every top level test" i
DEFINE_string prepackaged_autotest "" "Use this prepackaged autotest dir"
DEFINE_string results_dir_root "" "alternate root results directory"
DEFINE_boolean verbose ${FLAGS_FALSE} "Show verbose autoserv output" v

RAN_ANY_TESTS=${FLAGS_FALSE}

# Check if our stdout is a tty
function is_a_tty() {
  local stdout=$(readlink /proc/$$/fd/1)
  [[ "${stdout#/dev/tty}" != "${stdout}" ]] && return 0
  [[ "${stdout#/dev/pts}" != "${stdout}" ]] && return 0
  return 1
}

# Writes out text in specified color if stdout is a tty
# Arguments:
#   $1 - color
#   $2 - text to color
#   $3 - text following colored text (default colored)
# Returns:
#   None
function echo_color() {
  local color=0
  [[ "$1" == "red" ]] && color=31
  [[ "$1" == "green" ]] && color=32
  [[ "$1" == "yellow" ]] && color=33
  if is_a_tty; then
    echo -e "\033[1;${color}m$2\033[0m$3"
  else
    echo "$2$3"
  fi
}

function cleanup() {
  if [[ $FLAGS_cleanup -eq ${FLAGS_TRUE} ]] || \
     [[ ${RAN_ANY_TESTS} -eq ${FLAGS_FALSE} ]]; then
    rm -rf "${TMP}"
  else
    echo ">>> Details stored under ${TMP}"
  fi
  cleanup_remote_access
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


# Determine if a control is for a client or server test.  Echos
# either "server" or "client".
# Arguments:
#   $1 - control file path
function read_test_type() {
  local control_file=$1
  # Assume a line starts with TEST_TYPE =
  local type=$(egrep -m1 \
               '^[[:space:]]*TEST_TYPE[[:space:]]*=' "${control_file}")
  if [[ -z "${type}" ]]; then
    echo_color "red" ">>> Unable to find TEST_TYPE line in ${control_file}"
    exit 1
  fi
  type=$(python -c "${type}; print TEST_TYPE.lower()")
  if [[ "${type}" != "client" ]] && [[ "${type}" != "server" ]]; then
    echo_color "red" ">>> Unknown type of test (${type}) in ${control_file}"
    exit 1
  fi
  echo ${type}
}

function main() {
  cd $(dirname "$0")

  FLAGS "$@" || exit 1

  if [[ -z "${FLAGS_ARGV}" ]]; then
    echo "Usage: $0 --remote=[hostname] [regexp...]:"
    echo "Each regexp pattern must uniquely match a control file. For example:"
    echo "  $0 --remote=MyMachine BootPerfServer"
    exit 1
  fi

  # Check the validity of the user-specified result directory
  # It must be within the /tmp directory
  if [[ -n "${FLAGS_results_dir_root}" ]]; then
    SUBSTRING=${FLAGS_results_dir_root:0:5}
    if [[ ${SUBSTRING} != "/tmp/" ]]; then
      echo "User-specified result directory must be within the /tmp directory"
      echo "ex: --results_dir_root=/tmp/<result_directory>"
      exit 1
    fi
  fi

  set -e

  # Set global TMP for remote_access.sh's sake
  # and if --results_dir_root is specified,
  # set TMP and create dir appropriately
  if [[ ${INSIDE_CHROOT} -eq 0 ]]; then
    if [[ -n "${FLAGS_results_dir_root}" ]]; then
      TMP=${FLAGS_chroot}${FLAGS_results_dir_root}
      mkdir -m 777 ${TMP}
    else
      TMP=$(mktemp -d ${FLAGS_chroot}/tmp/run_remote_tests.XXXX)
    fi
    TMP_INSIDE_CHROOT=$(echo ${TMP#${FLAGS_chroot}})
  else
    if [[ -n "${FLAGS_results_dir_root}" ]]; then
      TMP=${FLAGS_results_dir_root}
      mkdir -m 777 ${TMP}
    else
      TMP=$(mktemp -d /tmp/run_remote_tests.XXXX)
    fi
    TMP_INSIDE_CHROOT=${TMP}
  fi

  trap cleanup EXIT

  remote_access_init

  local autotest_dir=""
  if [[ -z "${FLAGS_prepackaged_autotest}" ]]; then
    learn_board
    if [[ -n "${CROS_WORKON_SRCROOT}" ]]; then
      autotest_dir="/build/${FLAGS_board}/usr/local/autotest"
    else
      autotest_dir="${GCLIENT_ROOT}/src/third_party/autotest/files"
    fi
  else
    autotest_dir="${FLAGS_prepackaged_autotest}"
  fi

  local control_files_to_run=""
  local chrome_autotests="${CHROME_ROOT}/src/chrome/test/chromeos/autotest/files"
  # Now search for tests which unambiguously include the given identifier
  local search_path=$(echo {client,server}/{tests,site_tests})
  # Include chrome autotest in the search path
  if [ -n "${CHROME_ROOT}" ]; then
    search_path="${search_path} ${chrome_autotests}/client/site_tests"
  fi
  pushd ${autotest_dir} > /dev/null
  for test_request in $FLAGS_ARGV; do
    test_request=$(remove_quotes "${test_request}")
    ! finds=$(find ${search_path} -maxdepth 2 -type f \( -name control.\* -or \
      -name control \) | egrep -v "~$" | egrep "${test_request}")
    if [[ -z "${finds}" ]]; then
      echo_color "red" ">>> Cannot find match for \"${test_request}\""
      exit 1
    fi
    local matches=$(echo "${finds}" | wc -l)
    if [[ ${matches} -gt 1 ]]; then
      echo ">>> \"${test_request}\" is an ambiguous pattern.  Disambiguate by" \
           "passing one of these patterns instead:"
      for FIND in ${finds}; do
        echo "   ^${FIND}\$"
      done
      exit 1
    fi
    for i in $(seq 1 $FLAGS_iterations); do
      control_files_to_run="${control_files_to_run} '${finds}'"
    done
  done
  popd > /dev/null

  echo ""

  if [[ -z "${control_files_to_run}" ]]; then
    echo_color "red" ">>> Found no control files"
    exit 1
  fi

  echo_color "yellow" ">>> Running the following control files:"
  for CONTROL_FILE in ${control_files_to_run}; do
    echo_color "yellow" " * " "${CONTROL_FILE}"
  done

  for control_file in ${control_files_to_run}; do
    # Assume a line starts with TEST_TYPE =
    control_file=$(remove_quotes "${control_file}")
    local type=$(read_test_type "${autotest_dir}/${control_file}")
    # Check if the control file is an absolute path (i.e. chrome autotests case)
    if [[ ${control_file:0:1} == "/" ]]; then
      type=$(read_test_type "${control_file}")
    fi
    local option
    if [[ "${type}" == "client" ]]; then
      option="-c"
    else
      option="-s"
    fi
    echo ""
    echo_color "yellow" ">>> Running ${type} test " ${control_file}
    local control_file_name=$(basename "${control_file}")
    local short_name=$(basename $(dirname "${control_file}"))

    # testName/control --> testName
    # testName/control.bvt --> testName.bvt
    # testName/control.regression --> testName.regression
    # testName/some_control --> testName.some_control
    if [[ "${control_file_name}" != control ]]; then
      if [[ "${control_file_name}" == control.* ]]; then
        short_name=${short_name}.${control_file_name/control./}
      else
        short_name=${short_name}.${control_file_name}
      fi
    fi

    local results_dir_name="${short_name}"
    local results_dir="${TMP_INSIDE_CHROOT}/${results_dir_name}"
    rm -rf "${results_dir}"
    local verbose=""
    if [[ ${FLAGS_verbose} -eq $FLAGS_TRUE ]]; then
      verbose="--verbose"
    fi

    RAN_ANY_TESTS=${FLAGS_TRUE}

    # HACK: Temporary hack for cros-workon conversion
    [[ -n "${CROS_WORKON_SRCROOT}" ]] && WORKON_SUFFIX=_workon

    local enter_chroot=""
    local autotest="${GCLIENT_ROOT}/src/scripts/autotest${WORKON_SUFFIX}"
    if [[ ${INSIDE_CHROOT} -eq 0 ]]; then
      enter_chroot="./enter_chroot.sh --chroot ${FLAGS_chroot} --"
      autotest="./autotest${WORKON_SUFFIX}"
    fi

    # Remove chrome autotest location prefix from control_file if needed
    if [[ ${control_file:0:${#chrome_autotests}} == \
          "${chrome_autotests}" ]]; then
      control_file="${control_file:${#chrome_autotests}+1}"
      echo_color "yellow" ">>> Running chrome autotest " ${control_file}
    fi
    if [[ -n "${FLAGS_args}" ]]; then
      passthrough_args="--args=${FLAGS_args}"
    fi

    ${enter_chroot} ${autotest} --board "${FLAGS_board}" -m "${FLAGS_remote}" \
      --ssh-port ${FLAGS_ssh_port} \
      "${option}" "${control_file}" -r "${results_dir}" ${verbose} \
      "${passthrough_args}" >&2
  done

  echo ""
  echo_color "yellow" ">>> Test results:"
  ./generate_test_report "${TMP}" --strip="${TMP}/"

  print_time_elapsed
}

main "$@"
