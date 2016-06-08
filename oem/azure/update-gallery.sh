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
media_name="${MEDIA_PREFIX}__CoreOS-${UGROUP}-${VERSION}"
publish_date="$(date +'%m/%d/%Y')"

jq --raw-output \
	".mediaReferences.PublicAzure.imageVersions |= [{ \
		version: \"${VERSION}\", \
		publishedDate: \"${publish_date}\", \
		mediaName: \"${media_name}\" \
	}] + .[0:4] | \
	.mediaReferences.PublicAzure.mediaName = \"${media_name}\"" \
	< "${input}" > "${output}"

git rm "${input}"
git add "${output}"
git commit --message="CoreOS: Add ${UGROUP} ${VERSION}"
