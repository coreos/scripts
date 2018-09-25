#!/usr/bin/env bash

set -ex

if [[ $# -lt 2 ]]; then
	echo "Usage: $0 DATA_DIR SIGS_DIR [SERVER_ADDR [SERVER_PORT]]"
	exit 1
fi

DATA_DIR="$(readlink -f "$1")"
KEYS_DIR="$(readlink -f "$(dirname "$0")")"
SIGS_DIR="$(readlink -f "$2")"
SERVER_ADDR="${3:-10.7.68.100}"
SERVER_PORT="${4:-50051}"

echo "===     Verifying update payload...     ==="
gpg2 --verify "${DATA_DIR}/coreos_production_update.bin.bz2.sig"
gpg2 --verify "${DATA_DIR}/coreos_production_image.vmlinuz.sig"
gpg2 --verify "${DATA_DIR}/coreos_production_update.zip.sig"
echo "===   Decompressing update payload...   ==="
bunzip2 --keep "${DATA_DIR}/coreos_production_update.bin.bz2"
unzip "${DATA_DIR}/coreos_production_update.zip" -d "${DATA_DIR}"

payload_signature_files=""
for i in ${SIGS_DIR}/update.sig.*; do
	payload_signature_files=${payload_signature_files}:${i}
done
payload_signature_files="${payload_signature_files:1:${#payload_signature_files}}"

pushd "${DATA_DIR}"
./core_sign_update \
	--image "${DATA_DIR}/coreos_production_update.bin" \
	--kernel "${DATA_DIR}/coreos_production_image.vmlinuz" \
	--output "${DATA_DIR}/coreos_production_update.gz" \
	--private_keys "${KEYS_DIR}/devel.key.pem+fero:coreos-image-signing-key" \
	--public_keys  "${KEYS_DIR}/devel.pub.pem+${KEYS_DIR}/prod-2.pub.pem" \
	--keys_separator "+" \
	--signing_server_address "$SERVER_ADDR" \
	--signing_server_port "$SERVER_PORT" \
	--user_signatures "${payload_signature_files}"
popd

echo "===      Signing torcx manifest...      ==="
torcx_signature_arg=""
for torcx_signature in ${SIGS_DIR}/torcx_manifest.json.sig.*; do
	torcx_signature_arg="${torcx_signature_arg} --signature ${torcx_signature}"
done
torcx_signature_arg="${torcx_signature_arg:1:${#torcx_signature_arg}}"

fero-client \
	--address $SERVER_ADDR \
	--port $SERVER_PORT \
	sign \
	--file "${DATA_DIR}/torcx_manifest.json" \
	--output "${DATA_DIR}/torcx_manifest.json.sig-fero" \
	--secret-key coreos-app-signing-key \
	${torcx_signature_arg}
gpg2 --enarmor \
	--output "${DATA_DIR}/torcx_manifest.json.asc" \
	"${DATA_DIR}/torcx_manifest.json.sig-fero"
echo "=== Torcx manifest signed successfully. ==="
rm -f "${DATA_DIR}/torcx_manifest.json.sig-fero"
