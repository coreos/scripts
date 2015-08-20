#!/bin/bash

# This script will update the Azure Gallery repo with the specified group and
# version.

set -e

GALLERY_PATH="${1}/CoreOS"
UGROUP="${2^}"
LGROUP="${2,}"
VERSION=$3

MEDIA_PREFIX="2b171e93f07c4903bcad35bda10acf22"

if [[ -z $GALLERY_PATH || -z $UGROUP || -z $VERSION ]]; then
	echo "Usage: $0 <path to gallery repo> <group> <version>"
	exit 2
fi

cd "${GALLERY_PATH}"
git fetch origin
git checkout -b "${LGROUP}-${VERSION}" origin/master

input=$(ls CoreOS_*_${LGROUP}.json)
output="CoreOS_${VERSION}_${LGROUP}.json"
display_name="CoreOS ${UGROUP} (${VERSION})"
media_name="${MEDIA_PREFIX}__CoreOS-${UGROUP}-${VERSION}"

jq --raw-output \
	".displayName = \"${display_name}\" | .MediaName = \"${media_name}\"" \
	< "${input}" > "${output}"

git rm "${input}"
git add "${output}"
git commit --message="CoreOS: Add ${UGROUP} ${VERSION}"
