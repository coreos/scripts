#!/bin/bash

# Copyright (c) 2009 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# This script makes autotest client tests inside a chroot environment.  The idea
# is to compile any platform-dependent autotest client tests in the build
# environment, since client systems under test lack the proper toolchain.
#
# The user can later run autotest against an ssh enabled test client system, or
# install the compiled client tests directly onto the rootfs image.

# Includes common already
. "$(dirname $0)/autotest_lib.sh"

# Script must be run inside the chroot
assert_inside_chroot

DEFAULT_TESTS_LIST="all"

DEFINE_string build "${DEFAULT_TESTS_LIST}" \
  "a comma seperated list of autotest client tests to be prebuilt." b
DEFINE_boolean prompt $FLAGS_TRUE "Prompt user when building all tests."
DEFINE_boolean autox $FLAGS_TRUE "Build autox along with autotest"
DEFINE_boolean buildcheck $FLAGS_TRUE "Fail if tests fail to build"
DEFINE_integer jobs -1 "How many packages to build in parallel at maximum."

# More useful help
FLAGS_HELP="usage: $0 [flags]"

# parse the command-line
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"
set -e

check_board

if [[ "${FLAGS_jobs}" -ne -1 ]]; then
  EMERGE_JOBS="--jobs=${FLAGS_jobs}"
fi

# build default pre-compile client tests list.
ALL_TESTS="compilebench,dbench,disktest,ltp,netperf2,unixbench"
CLIENT_TEST_PATH="../third_party/autotest/files/client/site_tests"
for SITE_TEST in ${CLIENT_TEST_PATH}/*
do
  if [ -d ${SITE_TEST} ]
  then
    ALL_TESTS="${ALL_TESTS},${SITE_TEST##${CLIENT_TEST_PATH}/}"
  fi
done

# Load the overlay specific blacklist and remove any matching tests.
BOARD_BASENAME=$(echo "${FLAGS_board}" |cut -d '_' -f 1)
PRIMARY_BOARD_OVERLAY="${SRC_ROOT}/overlays/overlay-${BOARD_BASENAME}"
BLACKLIST_FILE="${PRIMARY_BOARD_OVERLAY}/autotest-blacklist"
if [ -r "${BLACKLIST_FILE}" ]
then
  BLACKLISTED_TESTS=$(cat ${BLACKLIST_FILE})

  for TEST in ${BLACKLISTED_TESTS}
  do
    ALL_TESTS=${ALL_TESTS/#${TEST},/}     # match first test (test,...)
    ALL_TESTS=${ALL_TESTS/,${TEST},/,}    # match middle tests (...,test,...)
    ALL_TESTS=${ALL_TESTS/%,${TEST}/}     # match last test (...,test)
  done
fi

if [ ${FLAGS_build} == ${DEFAULT_TESTS_LIST} ]
then
  if [ ${FLAGS_prompt} -eq ${FLAGS_TRUE} ]
  then
    echo -n "You want to pre-build all client tests and it may take a long time"
    echo " to finish. "
    read -p "Are you sure you want to continue?(N/y)" answer
    answer=${answer:0:1}
    if [ "${answer}" != "Y" ] && [ "${answer}" != "y" ]
    then
      echo "Use --build to specify tests you like to pre-compile."
      echo -n "E.g.: ./enter_chroot.sh \"./build_autotest.sh "
      echo "--build=system_SAT\""
      exit 0
    fi
  fi
  TEST_LIST=${ALL_TESTS}
else
  TEST_LIST=${FLAGS_build}
fi

# Decide on USE flags based on options
USE=
[ $FLAGS_autox -eq "$FLAGS_FALSE" ] && USE="${USE} -autox"
[ $FLAGS_buildcheck -eq "$FLAGS_TRUE" ] && USE="${USE} buildcheck"

GCLIENT_ROOT="${GCLIENT_ROOT}" TEST_LIST=${TEST_LIST} \
  FEATURES="${FEATURES} -buildpkg -collision-protect" \
  USE="$USE" "emerge-${FLAGS_board}" \
  chromeos-base/autotest ${EMERGE_JOBS}
