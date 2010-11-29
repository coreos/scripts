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

function cleanup() {
  # Always remove the build path in case it was used.
  [[ -n "${BUILD_DIR}" ]] && sudo rm -rf "${BUILD_DIR}"
  if [[ $FLAGS_cleanup -eq ${FLAGS_TRUE} ]] || \
     [[ ${RAN_ANY_TESTS} -eq ${FLAGS_FALSE} ]]; then
    rm -rf "${TMP}"
  else
    echo ">>> Details stored under ${TMP}"
  fi
  cleanup_remote_access
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
    die "Unable to find TEST_TYPE line in ${control_file}"
  fi
  type=$(python -c "${type}; print TEST_TYPE.lower()")
  if [[ "${type}" != "client" ]] && [[ "${type}" != "server" ]]; then
    die "Unknown type of test (${type}) in ${control_file}"
  fi
  echo ${type}
}

function create_tmp() {
  # Set global TMP for remote_access.sh's sake
  # and if --results_dir_root is specified,
  # set TMP and create dir appropriately
  if [[ ${INSIDE_CHROOT} -eq 0 ]]; then
    if [[ -n "${FLAGS_results_dir_root}" ]]; then
      TMP=${FLAGS_chroot}${FLAGS_results_dir_root}
      mkdir -p -m 777 ${TMP}
    else
      TMP=$(mktemp -d ${FLAGS_chroot}/tmp/run_remote_tests.XXXX)
    fi
    TMP_INSIDE_CHROOT=$(echo ${TMP#${FLAGS_chroot}})
  else
    if [[ -n "${FLAGS_results_dir_root}" ]]; then
      TMP=${FLAGS_results_dir_root}
      mkdir -p -m 777 ${TMP}
    else
      TMP=$(mktemp -d /tmp/run_remote_tests.XXXX)
    fi
    TMP_INSIDE_CHROOT=${TMP}
  fi
}

function prepare_build_dir() {
  local autotest_dir="$1"
  INSIDE_BUILD_DIR="${TMP_INSIDE_CHROOT}/build"
  BUILD_DIR="${TMP}/build"
  info "Copying autotest tree into ${BUILD_DIR}."
  sudo mkdir -p "${BUILD_DIR}"
  sudo rsync -rl --chmod=ugo=rwx "${autotest_dir}"/ "${BUILD_DIR}"
  info "Pilfering toolchain shell environment from Portage."
  local outside_ebuild_dir="${TMP}/chromeos-base/autotest-build"
  local inside_ebuild_dir="${TMP_INSIDE_CHROOT}/chromeos-base/autotest-build"
  mkdir -p "${outside_ebuild_dir}"
  local E_only="autotest-build-9999.ebuild"
  cat > "${outside_ebuild_dir}/${E_only}" <<EOF
inherit toolchain-funcs
SLOT="0"
EOF
  local E="chromeos-base/autotest-build/${E_only}"
  ${ENTER_CHROOT} "ebuild-${FLAGS_board}" "${inside_ebuild_dir}/${E_only}" \
      clean unpack 2>&1 > /dev/null
  local P_tmp="${FLAGS_chroot}/build/${FLAGS_board}/tmp/portage/"
  local E_dir="${E%%/*}/${E_only%.*}"
  sudo cp "${P_tmp}/${E_dir}/temp/environment" "${BUILD_DIR}"
}

function autodetect_build() {
  if [ ${FLAGS_use_emerged} -eq ${FLAGS_TRUE} ]; then
    info \
"As requested, using emerged autotests already installed in your sysroot."
    FLAGS_build=${FLAGS_FALSE}
    return
  fi
  if ${ENTER_CHROOT} ./cros_workon --board=${FLAGS_board} list | \
    grep -q autotest; then
    info \
"Detected cros_workon autotests, building your sources instead of emerged \
autotest.  To use installed autotest, pass --use_emerged."
    FLAGS_build=${FLAGS_TRUE}
  else
    info \
"Using emerged autotests already installed in your sysroot.  To build \
autotests directly from your source directory instead, pass --build."
    FLAGS_build=${FLAGS_FALSE}
  fi
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

  create_tmp

  trap cleanup EXIT

  remote_access_init

  learn_board
  autotest_dir="${FLAGS_chroot}/build/${FLAGS_board}/usr/local/autotest"

  ENTER_CHROOT=""
  if [[ ${INSIDE_CHROOT} -eq 0 ]]; then
    ENTER_CHROOT="./enter_chroot.sh --chroot ${FLAGS_chroot} --"
  fi

  if [ ${FLAGS_build} -eq ${FLAGS_FALSE} ]; then
    autodetect_build
  fi

  if [ ${FLAGS_build} -eq ${FLAGS_TRUE} ]; then
    autotest_dir="${SRC_ROOT}/third_party/autotest/files"
  else
    if [ ! -d "${autotest_dir}" ]; then
      die "You need to emerge autotest-tests (or use --build)"
    fi
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
  popd > /dev/null

  echo ""

  if [[ -z "${control_files_to_run}" ]]; then
    die "Found no control files"
  fi

  [ ${FLAGS_build} -eq ${FLAGS_TRUE} ] && prepare_build_dir "${autotest_dir}"

  info "Running the following control files:"
  for CONTROL_FILE in ${control_files_to_run}; do
    info " * ${CONTROL_FILE}"
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
    info "Running ${type} test ${control_file}"
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

    # Remove chrome autotest location prefix from control_file if needed
    if [[ ${control_file:0:${#chrome_autotests}} == \
          "${chrome_autotests}" ]]; then
      control_file="${control_file:${#chrome_autotests}+1}"
      info "Running chrome autotest ${control_file}"
    fi

    local autoserv_test_args="${FLAGS_args}"
    if [ -n "${autoserv_test_args}" ]; then
      autoserv_test_args="-a \"${autoserv_test_args}\""
    fi
    local autoserv_args="-m ${FLAGS_remote} --ssh-port ${FLAGS_ssh_port} \
        ${option} ${control_file} -r ${results_dir} ${verbose}"
    if [ ${FLAGS_build} -eq ${FLAGS_FALSE} ]; then
      cat > "${TMP}/run_test.sh" <<EOF
cd /build/${FLAGS_board}/usr/local/autotest
sudo chmod a+w ./server/{tests,site_tests}
echo ./server/autoserv ${autoserv_args} ${autoserv_test_args}
./server/autoserv ${autoserv_args} ${autoserv_test_args}
EOF
      chmod a+rx "${TMP}/run_test.sh"
      ${ENTER_CHROOT} ${TMP_INSIDE_CHROOT}/run_test.sh >&2
    else
      cp "${BUILD_DIR}/environment" "${TMP}/run_test.sh"
      GRAPHICS_BACKEND=${GRAPHICS_BACKEND:-OPENGL}
      cat >> "${TMP}/run_test.sh" <<EOF
export GCLIENT_ROOT=/home/${USER}/trunk
export GRAPHICS_BACKEND=${GRAPHICS_BACKEND}
export SSH_AUTH_SOCK=${SSH_AUTH_SOCK} TMPDIR=/tmp SSH_AGENT_PID=${SSH_AGENT_PID}
export SYSROOT=/build/${FLAGS_board}
tc-export CC CXX PKG_CONFIG
cd ${INSIDE_BUILD_DIR}
echo ./server/autoserv ${autoserv_args} ${autoserv_test_args}
./server/autoserv ${autoserv_args} ${autoserv_test_args}
EOF
      sudo cp "${TMP}/run_test.sh" "${BUILD_DIR}"
      sudo chmod a+rx "${BUILD_DIR}/run_test.sh"
      ${ENTER_CHROOT} sudo bash -c "${INSIDE_BUILD_DIR}/run_test.sh" >&2
    fi
  done

  echo ""
  info "Test results:"
  ./generate_test_report "${TMP}" --strip="${TMP}/"

  print_time_elapsed
}

main "$@"
