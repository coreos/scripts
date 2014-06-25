#!/bin/bash

set -ex
DATA_DIR="$1"

gpg --verify "${DATA_DIR}/coreos_production_update.bin.bz2.sig"
gpg --verify "${DATA_DIR}/coreos_production_update.zip.sig"
bunzip2 --keep "${DATA_DIR}/coreos_production_update.bin.bz2"
unzip "${DATA_DIR}/coreos_production_update.zip" -d "${DATA_DIR}"

export PATH="${DATA_DIR}:${PATH}"

core_sign_update \
    --image "${DATA_DIR}/coreos_production_update.bin" \
    --output "${DATA_DIR}/update.gz" \
    --private_keys "devel.key.pem:prod-2.key.pem" \
    --public_keys  "devel.pub.pem:prod-2.pub.pem"
