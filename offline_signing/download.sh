#!/usr/bin/env bash

set -eux

BOARD="${1?Must provide a board (e.g. amd64-usr)}"
VERSION="${2?Must provide a version (e.g. 1234.0.0)}"
CHANNEL="${3?Must provide a channel (e.g. alpha)}"

if ! [[ "${CHANNEL}" =~ alpha|beta|stable ]]; then
    echo "Invalid channel ${CHANNEL}"
    echo "Usage: $0 <BOARD> <VERSION> <CHANNEL> [OUTPUT DIR]"
    exit 1
fi

GS="gs://builds.release.core-os.net/${CHANNEL}/boards/$BOARD/$VERSION"

cd "${4:-.}"

gsutil cp \
    "${GS}/coreos_production_image.vmlinuz" \
    "${GS}/coreos_production_image.vmlinuz.sig" \
    "${GS}/coreos_production_update.bin.bz2" \
    "${GS}/coreos_production_update.bin.bz2.sig" \
    "${GS}/coreos_production_update.zip" \
    "${GS}/coreos_production_update.zip.sig" ./

gpg2 --verify "coreos_production_image.vmlinuz.sig"
gpg2 --verify "coreos_production_update.bin.bz2.sig"
gpg2 --verify "coreos_production_update.zip.sig"
