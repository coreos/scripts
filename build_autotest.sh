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
DEFINE_boolean prompt $FLAGS_TRUE "Prompt user when building all tests"

# More useful help
FLAGS_HELP="usage: $0 [flags]"

# parse the command-line
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"
set -e

check_board

# build default pre-compile client tests list.
ALL_TESTS="compilebench,dbench,disktest,ltp,netperf2,netpipe,unixbench"
for SITE_TEST in ../third_party/autotest/files/client/site_tests/*
do
  if [ -d ${SITE_TEST} ]
  then
    ALL_TESTS="${ALL_TESTS},${SITE_TEST:48}"
  fi
done

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

GCLIENT_ROOT="${GCLIENT_ROOT}" TEST_LIST=${TEST_LIST} \
"emerge-${FLAGS_board}" chromeos-base/autotest
