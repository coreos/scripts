#!/bin/bash

set -ex
BOARD="$1"
VERSION="$2"
GS="gs://builds.release.core-os.net/unsigned/boards/$BOARD/$VERSION"

cd "${3:-.}"

# The shim only exists for amd64 boards.
[ "x${BOARD}" = xamd64-usr ] && shim=1 || shim=

gsutil cp \
    "${GS}/coreos_production_image.vmlinuz" \
    "${GS}/coreos_production_image.vmlinuz.sig" \
    "${GS}/coreos_production_image.grub" \
    "${GS}/coreos_production_image.grub.sig" \
    ${shim:+
    "${GS}/coreos_production_image.shim"
    "${GS}/coreos_production_image.shim.sig"
    } \
    "${GS}/coreos_production_update.bin.bz2" \
    "${GS}/coreos_production_update.bin.bz2.sig" \
    "${GS}/coreos_production_update.zip" \
    "${GS}/coreos_production_update.zip.sig" ./

gpg --verify "coreos_production_image.vmlinuz.sig"
gpg --verify "coreos_production_image.grub.sig"
[ -z "$shim" ] || gpg --verify "coreos_production_image.shim.sig"
gpg --verify "coreos_production_update.bin.bz2.sig"
gpg --verify "coreos_production_update.zip.sig"
