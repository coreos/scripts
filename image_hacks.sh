#!/bin/bash

# Copyright (c) 2009 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# This script is a wrapper around every part of the build system that corrupts
# the pristine image for various purposes.

# The purpose of this script is to allow a smooth transition from the old
# build system, where random corruptions of the pipelined approach to image
# creation happen in random places, to the new build system, where we keep all
# of them in one place.

# To avoid code duplication and preservation of the old build system until the
# release of chromite, we need to import all the "corrupting" code into here,
# but provide "legacy" interfaces to this code so that it can be used in
# exactly identical way. This is done in 2 phases:
# 1) Wrapping around various other scripts, providing a way to call them from
# this script.
# 2) Make this script consume the wrapped scripts and provide legacy symlinks,
# that do exactly the same thing as the old scripts.

#------ These are the scripts we're trying to kill --------#

function mod_image_for_test() {
  $(dirname ${0})/mod_image_for_test.sh $* || return $?
}

function mod_image_for_recovery() {
  $(dirname ${0})/mod_image_for_recovery.sh $* || return $?
}

function mod_image_for_dev_recovery() {
  $(dirname ${0})/mod_image_for_dev_recovery.sh $* || return $?
}

function customize_rootfs() {
  $(dirname ${0})/customize_rootfs $* || return $?
}

#-------------------------- Tools -------------------------#

function board_to_arch() {
  . "/build/${1}/etc/make.conf.board_setup" || return 1
  TC_ARCH=$(echo "${CHOST}" | awk -F'-' '{ print $1 }')
  case "${TC_ARCH}" in
    (arm*) echo "arm";;
    (*86) echo "x86";;
    (*) error "Unable to determine ARCH from toolchain: ${CHOST}"; return 1;;
  esac
}

#--------------------------- Main -------------------------#

function corrupt_for_recovery() {
 :
}
function corrupt_for_dev_recovery() {
 :
}
function corrupt_for_dev_install() {
 :
}
function corrupt_for_factory_installer_shim() {
 :
}
function corrupt_for_factory_test() {
 :
}
function corrupt_for_test() {
 :
}

function main() {
  . "$(dirname "$0")/common.sh"
  get_default_board

  # Flag definitions:
  DEFINE_string corruption_type "" \
    "The type of corruption to invoke upon the slashfs."
  DEFINE_string board "${DEFAULT_BOARD}" \
    "The board to build an image for."
  DEFINE_string slashfs "" \
    "The path to root file system to corrupt."

  # Parse command line.
  FLAGS "$@" || return 1

  # Sanity checking.
  if [ -z "${FLAGS_corruption_type}" ]; then
    echo "Please specify corruption type"; return 1
  fi
  if [ -z "${FLAGS_board}" ]; then
    echo "You must specify board"; return 1
  fi

  # Customize_rootfs needs arch, we need to get it somehow.
  ARCH="$(board_to_arch ${FLAGS_board})" || return 1

  ###################################################
  # Parametric corruption of the slashfs starts here.
  ###################################################
  #customize_rootfs --board="${FLAGS_board}" --target="${ARCH}" \
  #  --root="${FLAGS_slashroot}"

  case ${FLAGS_corruption_type} in
    (recovery) corrupt_for_recovery ;;
    (dev_recovery) corrupt_for_dev_recovery ;;
    (dev_install) corrupt_for_dev_install ;;
    (factory_installer_shim) corrupt_for_factory_installer_shim ;;
    (factory_test) corrupt_for_factory_test ;;
    (test) corrupt_for_test ;;
  esac
  return $?
}

case "$(basename $0)" in
#  (mod_image_for_test.sh) mod_image_for_test $* || return $?;;
#  (mod_image_for_recovery.sh) mod_image_for_recovery $* || return $?;;
#  (mod_image_for_dev_recovery.sh) mod_image_for_dev_recovery $* || return $?;;
#  (customize_rootfs) customize_rootfs $* || return $?;;
  (image_hacks.sh) main $* || return $?;; # normal invocation
  (*) echo "$0: Unknown invocation!"; exit 1 ;;
esac
