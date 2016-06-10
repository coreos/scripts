#!/bin/bash

# This script will copy the Azure image from the CoreOS build bucket into
# Azure storage, create an Azure VM image, and replicate it to all regions. It
# to be run in an environment where the azure-xplat-cli has been installed and
# configured with the production credentials and (optionally) SUBSCRIPTION_ID
# is defined, containing the subscription GUID.

DIR=$(dirname $0)
. $DIR/common.sh

set -e

WORKDIR=$(mktemp --directory --tmpdir=/var/tmp)
trap "rm --force --recursive ${WORKDIR}" SIGINT SIGTERM EXIT

IMAGE_PATH="${WORKDIR}/coreos_production_azure_image.vhd"

UGROUP="${1^}"
LGROUP="${1,}"
VERSION=$2
DATE=$3
GS_BUCKET_URL="gs://builds.release.core-os.net/${LGROUP}/boards/amd64-usr/${VERSION}/coreos_production_azure_image.vhd"

if [[ -z $UGROUP || -z $VERSION ]]; then
	echo "Usage: $0 <group> <version> [<published date>]"
	exit 2
fi

echo "Downloading image from CoreOS build bucket..."
gsutil cp "${GS_BUCKET_URL}.bz2" "${IMAGE_PATH}.bz2"
gsutil cp "${GS_BUCKET_URL}.bz2.sig" "${IMAGE_PATH}.bz2.sig"
gpg --verify "${IMAGE_PATH}.bz2.sig"

echo "Unzipping image..."
bunzip2 "${IMAGE_PATH}.bz2"

echo "Inflating image..."
qemu-img convert -f vpc -O raw "${IMAGE_PATH}" "${IMAGE_PATH}.bin"
qemu-img convert -f raw -o subformat=fixed -O vpc "${IMAGE_PATH}.bin" "${IMAGE_PATH}"

echo "Fetching Azure storage account key..."
ACCOUNT_KEY=$(azure storage account keys list coreos --json | \
	jq '.primaryKey' --raw-output)

echo "Uploading image as page blob into Azure..."
azure storage blob upload \
	--account-name="coreos" \
	--account-key="${ACCOUNT_KEY}" \
	--file="${IMAGE_PATH}" \
	--container="publish" \
	--blob="coreos-${VERSION}-${LGROUP}.vhd" \
	--blobtype="Page"

azure storage blob copy start \
	--account-name="coreos" \
	--account-key="${ACCOUNT_KEY}" \
	--source-blob="coreos-${VERSION}-${LGROUP}.vhd" \
	--source-container="publish" \
	--dest-container="pre-publish"

echo "Creating Azure image from blob..."
azure vm image create \
	--blob-url="https://coreos.$(getBlobStorageEndpoint)/publish/coreos-${VERSION}-${LGROUP}.vhd" \
	--os="linux" \
	--label="CoreOS ${UGROUP}" \
	"CoreOS-${UGROUP}-${VERSION}"

echo "Setting image metadata..."
$DIR/set-image-metadata.sh "${UGROUP}" "${VERSION}" "${DATE}"

echo "Requesting image replication..."
$DIR/replicate-image.sh "${UGROUP}" "${VERSION}"
