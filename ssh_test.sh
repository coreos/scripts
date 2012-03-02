#!/bin/bash

# Copyright (c) 2010 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Run remote access test to ensure ssh access to a host is working. Exits with
# a code of 0 if successful and non-zero otherwise. Used by test infrastructure
# scripts.

SCRIPT_ROOT=$(dirname $(readlink -f "$0"))
. "${SCRIPT_ROOT}/common.sh" || { echo "Unable to load common.sh"; exit 1; }
. "${SCRIPT_ROOT}/remote_access.sh" || die "Unable to load remote_access.sh"

function cleanup {
  cleanup_remote_access
  rm -rf "${TMP}"
}

function main() {
  cd "${SCRIPTS_DIR}"

  FLAGS "$@" || exit 1
  eval set -- "${FLAGS_ARGV}"

  switch_to_strict_mode

  trap cleanup EXIT

  TMP=$(mktemp -d /tmp/ssh_test.XXXX)

  remote_access_init
}

main $@
