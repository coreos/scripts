#!/bin/bash

set -ex
BOARD="$1"
VERSION="$2"
GS="gs://builds.release.core-os.net/stable/boards/$BOARD/$VERSION"

cd "${3:-.}"

gsutil cp \
    "${GS}/coreos_production_image.vmlinuz" \
    "${GS}/coreos_production_image.vmlinuz.sig" \
    "${GS}/coreos_production_update.bin.bz2" \
    "${GS}/coreos_production_update.bin.bz2.sig" \
    "${GS}/coreos_production_update.zip" \
    "${GS}/coreos_production_update.zip.sig" ./

gpg --verify "coreos_production_image.vmlinuz.sig"
gpg --verify "coreos_production_update.bin.bz2.sig"
gpg --verify "coreos_production_update.zip.sig"
