#!/bin/bash

# Copyright (c) 2009 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Script to run client or server tests on a live remote image.

# Load common constants.  This should be the first executable line.
# The path to common.sh should be relative to your script's location.

# --- BEGIN COMMON.SH BOILERPLATE ---
# Load common CrOS utilities.  Inside the chroot this file is installed in
# /usr/lib/crosutils.  Outside the chroot we find it relative to the script's
# location.
find_common_sh() {
  local common_paths=(/usr/lib/crosutils $(dirname "$(readlink -f "$0")"))
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

. "${SCRIPT_ROOT}/remote_access.sh" || die "Unable to load remote_access.sh"

get_default_board

DEFINE_string args "" \
    "Command line arguments for test. Quoted and space separated if multiple." a
DEFINE_string board "$DEFAULT_BOARD" \
    "The board for which you are building autotest"
DEFINE_boolean build ${FLAGS_FALSE} "Build tests while running" b
DEFINE_string chroot "${DEFAULT_CHROOT_DIR}" "alternate chroot location" c
DEFINE_boolean cleanup ${FLAGS_FALSE} "Clean up temp directory"
DEFINE_integer iterations 1 "Iterations to run every top level test" i
DEFINE_string results_dir_root "" "alternate root results directory"
DEFINE_boolean verbose ${FLAGS_FALSE} "Show verbose autoserv output" v
DEFINE_boolean use_emerged ${FLAGS_FALSE} \
    "Force use of emerged autotest packages"

RAN_ANY_TESTS=${FLAGS_FALSE}

function stop_ssh_agent() {
  # Call this function from the exit trap of the main script.
  # Iff we started ssh-agent, be nice and clean it up.
  # Note, only works if called from the main script - no subshells.
  if [[ 1 -eq ${OWN_SSH_AGENT} ]]; then
    kill ${SSH_AGENT_PID} 2>/dev/null
    unset OWN_SSH_AGENT SSH_AGENT_PID SSH_AUTH_SOCK
  fi
}

function start_ssh_agent() {
  local tmp_private_key=$TMP/autotest_key
  if [ -z "$SSH_AGENT_PID" ]; then
    eval $(ssh-agent)
    OWN_SSH_AGENT=1
  else
    OWN_SSH_AGENT=0
  fi
  cp $FLAGS_private_key $tmp_private_key
  chmod 0400 $tmp_private_key
  ssh-add $tmp_private_key
}

function cleanup() {
  # Always remove the build path in case it was used.
  [[ -n "${BUILD_DIR}" ]] && sudo rm -rf "${BUILD_DIR}"
  if [[ $FLAGS_cleanup -eq ${FLAGS_TRUE} ]] || \
     [[ ${RAN_ANY_TESTS} -eq ${FLAGS_FALSE} ]]; then
    rm -rf "${TMP}"
  else
    ln -sf "${TMP}" /tmp/run_remote_tests.latest
    echo ">>> Details stored under ${TMP}"
  fi
  stop_ssh_agent
  cleanup_remote_access
}

# Determine if a control is for a client or server test.  Echos
# either "server" or "client".
# Arguments:
#   $1 - control file path
function read_test_type() {
  local control_file=$1
  # Assume a line starts with TEST_TYPE =
  local test_type=$(egrep -m1 \
                    '^[[:space:]]*TEST_TYPE[[:space:]]*=' "${control_file}")
  if [[ -z "${test_type}" ]]; then
    die "Unable to find TEST_TYPE line in ${control_file}"
  fi
  test_type=$(python -c "${test_type}; print TEST_TYPE.lower()")
  if [[ "${test_type}" != "client" ]] && [[ "${test_type}" != "server" ]]; then
    die "Unknown type of test (${test_type}) in ${control_file}"
  fi
  echo ${test_type}
}

function create_tmp() {
  # Set global TMP for remote_access.sh's sake
  # and if --results_dir_root is specified,
  # set TMP and create dir appropriately
  if [[ -n "${FLAGS_results_dir_root}" ]]; then
    TMP=${FLAGS_results_dir_root}
    mkdir -p -m 777 ${TMP}
  else
    TMP=$(mktemp -d /tmp/run_remote_tests.XXXX)
  fi
}

function prepare_build_env() {
  info "Pilfering toolchain shell environment from Portage."
  local ebuild_dir="${TMP}/chromeos-base/autotest-build"
  mkdir -p "${ebuild_dir}"
  local E_only="autotest-build-9999.ebuild"
  cat > "${ebuild_dir}/${E_only}" <<EOF
inherit toolchain-funcs
SLOT="0"
EOF
  local E="chromeos-base/autotest-build/${E_only}"
  "ebuild-${FLAGS_board}" --skip-manifest "${ebuild_dir}/${E_only}" \
      clean unpack 2>&1 > /dev/null
  local P_tmp="/build/${FLAGS_board}/tmp/portage/"
  local E_dir="${E%%/*}/${E_only%.*}"
  export BUILD_ENV="${P_tmp}/${E_dir}/temp/environment"
}

function autodetect_build() {
  if [ ${FLAGS_use_emerged} -eq ${FLAGS_TRUE} ]; then
    AUTOTEST_DIR="/build/${FLAGS_board}/usr/local/autotest"
    FLAGS_build=${FLAGS_FALSE}
    if [ ! -d "${AUTOTEST_DIR}" ]; then
      die \
"Could not find pre-installed autotest, you need to emerge-${FLAGS_board} \
autotest autotest-tests (or use --build)."
    fi
    info \
"As requested, using emerged autotests already installed at ${AUTOTEST_DIR}."
    return
  fi

  if [ ${FLAGS_build} -eq ${FLAGS_FALSE} ] &&
      cros_workon --board=${FLAGS_board} list |
      grep -q autotest; then
    AUTOTEST_DIR="${SRC_ROOT}/third_party/autotest/files"
    FLAGS_build=${FLAGS_TRUE}
    if [ ! -d "${AUTOTEST_DIR}" ]; then
      die \
"Detected cros_workon autotest but ${AUTOTEST_DIR} does not exist. Run \
repo sync autotest."
    fi
    info \
"Detected cros_workon autotests. Building and running your autotests from \
${AUTOTEST_DIR}. To use emerged autotest, pass --use_emerged."
    return
  fi

  # flag use_emerged should be false once the code reaches here.
  if [ ${FLAGS_build} -eq ${FLAGS_TRUE} ]; then
    AUTOTEST_DIR="${SRC_ROOT}/third_party/autotest/files"
    if [ ! -d "${AUTOTEST_DIR}" ]; then
      die \
"Build flag was turned on but ${AUTOTEST_DIR} is not found. Run cros_workon \
start autotest and repo sync to continue."
    fi
    info "Build and run autotests from ${AUTOTEST_DIR}."
  else
    AUTOTEST_DIR="/build/${FLAGS_board}/usr/local/autotest"
    if [ ! -d "${AUTOTEST_DIR}" ]; then
      die \
"Autotest was not emerged. Run emerge-${FLAGS_board} autotest \
autotest-tests to continue."
    fi
    info "Using emerged autotests already installed at ${AUTOTEST_DIR}."
  fi
}

function main() {
  cd "${SCRIPTS_DIR}"

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

  create_tmp

  trap cleanup EXIT

  remote_access_init
  # autotest requires that an ssh-agent already be running
  start_ssh_agent

  learn_board
  autodetect_build

  local control_files_to_run=""
  local chrome_autotests="${CHROME_ROOT}/src/chrome/test/chromeos/autotest/files"
  # Now search for tests which unambiguously include the given identifier
  local search_path=$(echo {client,server}/{tests,site_tests})
  # Include chrome autotest in the search path
  if [ -n "${CHROME_ROOT}" ]; then
    search_path="${search_path} ${chrome_autotests}/client/site_tests"
  fi

  pushd ${AUTOTEST_DIR} > /dev/null
  for test_request in $FLAGS_ARGV; do
    test_request=$(remove_quotes "${test_request}")
    ! finds=$(find ${search_path} -maxdepth 2 -type f \( -name control.\* -or \
      -name control \) | egrep -v "~$" | egrep "${test_request}")
    if [[ -z "${finds}" ]]; then
      die "Cannot find match for \"${test_request}\""
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

  echo ""

  if [[ -z "${control_files_to_run}" ]]; then
    die "Found no control files"
  fi

  [ ${FLAGS_build} -eq ${FLAGS_TRUE} ] && prepare_build_env

  info "Running the following control files:"
  for control_file in ${control_files_to_run}; do
    info " * ${control_file}"
  done

  for control_file in ${control_files_to_run}; do
    # Assume a line starts with TEST_TYPE =
    control_file=$(remove_quotes "${control_file}")
    local test_type=$(read_test_type "${AUTOTEST_DIR}/${control_file}")
    # Check if the control file is an absolute path (i.e. chrome autotests case)
    if [[ ${control_file:0:1} == "/" ]]; then
      test_type=$(read_test_type "${control_file}")
    fi
    local option
    if [[ "${test_type}" == "client" ]]; then
      option="-c"
    else
      option="-s"
    fi
    echo ""
    info "Running ${test_type} test ${control_file}"
    local control_file_name=$(basename "${control_file}")
    local short_name=$(basename "$(dirname "${control_file}")")

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
    local results_dir="${TMP}/${results_dir_name}"
    rm -rf "${results_dir}"
    local verbose=""
    if [[ ${FLAGS_verbose} -eq $FLAGS_TRUE ]]; then
      verbose="--verbose"
    fi

    RAN_ANY_TESTS=${FLAGS_TRUE}

    # Remove chrome autotest location prefix from control_file if needed
    if [[ ${control_file:0:${#chrome_autotests}} == \
          "${chrome_autotests}" ]]; then
      control_file="${control_file:${#chrome_autotests}+1}"
      info "Running chrome autotest ${control_file}"
    fi

    local autoserv_args="-m ${FLAGS_remote} --ssh-port ${FLAGS_ssh_port} \
        ${option} ${control_file} -r ${results_dir} ${verbose}"
    if [ -n "${FLAGS_args}" ]; then
      autoserv_args="${autoserv_args} --args=${FLAGS_args}"
    fi

    sudo chmod a+w ./server/{tests,site_tests}
    echo ./server/autoserv ${autoserv_args}

    if [ ${FLAGS_build} -eq ${FLAGS_TRUE} ]; then
      # run autoserv in subshell
      (. ${BUILD_ENV} && tc-export CC CXX PKG_CONFIG &&
       ./server/autoserv ${autoserv_args})
    else
      ./server/autoserv ${autoserv_args}
    fi
  done
  popd > /dev/null

  echo ""
  info "Test results:"
  ./generate_test_report "${TMP}" --strip="${TMP}/"

  print_time_elapsed
}

restart_in_chroot_if_needed "$@"
main "$@"
