#!/usr/bin/env bash

set -ex
DATA_DIR="$(readlink -f "$1")"
KEYS_DIR="$(readlink -f "$(dirname "$0")")"

gpg2 --verify "${DATA_DIR}/coreos_production_update.bin.bz2.sig"
gpg2 --verify "${DATA_DIR}/coreos_production_image.vmlinuz.sig"
gpg2 --verify "${DATA_DIR}/coreos_production_update.zip.sig"
bunzip2 --keep "${DATA_DIR}/coreos_production_update.bin.bz2"
unzip "${DATA_DIR}/coreos_production_update.zip" -d "${DATA_DIR}"

export PATH="${DATA_DIR}:${PATH}"

cd "${DATA_DIR}"
./core_sign_update \
    --image "${DATA_DIR}/coreos_production_update.bin" \
    --kernel "${DATA_DIR}/coreos_production_image.vmlinuz" \
    --output "${DATA_DIR}/coreos_production_update.gz" \
    --private_keys "${KEYS_DIR}/devel.key.pem+pkcs11:object=CoreOS_Update_Signing_Key;type=private" \
    --public_keys  "${KEYS_DIR}/devel.pub.pem+${KEYS_DIR}/prod-2.pub.pem" \
    --keys_separator "+"
