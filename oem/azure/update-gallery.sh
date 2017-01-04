#!/bin/bash

# This script will update the Azure Gallery repo with the specified group and
# version.

set -e

GALLERY_PATH="${1}/CoreOS"
UGROUP="${2^}"
LGROUP="${2,}"
VERSION=$3

MEDIA_PREFIX_PUBLICAZURE="2b171e93f07c4903bcad35bda10acf22"
MEDIA_PREFIX_BLACKFOREST="ac384aecd6d24eaca1268cedd335f2a9"
MEDIA_PREFIX_MOONCAKE="a54f4e2924a249fd94ad761b77c3e83d"

if [[ -z $GALLERY_PATH || -z $UGROUP || -z $VERSION ]]; then
	echo "Usage: $0 <path to gallery repo> <group> <version>"
	exit 2
fi

cd "${GALLERY_PATH}"
git fetch origin
git checkout -b "${LGROUP}-${VERSION}" origin/master

input=$(ls Container_Linux_*_${LGROUP}.json)
output="Container_Linux_${VERSION}_${LGROUP}.json"
media_name_publicazure="${MEDIA_PREFIX_PUBLICAZURE}__Container-Linux-${UGROUP}-${VERSION}"
media_name_blackforest="${MEDIA_PREFIX_BLACKFOREST}__Container-Linux-${UGROUP}-${VERSION}"
media_name_mooncake="${MEDIA_PREFIX_MOONCAKE}__Container-Linux-${UGROUP}-${VERSION}"
publish_date="$(date +'%m/%d/%Y')"

jq --raw-output \
	".mediaReferences.PublicAzure.mediaName = \"${media_name_publicazure}\" |
	.mediaReferences.Blackforest.mediaName = \"${media_name_blackforest}\" |
	.mediaReferences.Mooncake.mediaName = \"${media_name_mooncake}\"" \
	< "${input}" > "${output}"

git rm "${input}"
git add "${output}"
git commit --message="CoreOS: Add Container Linux ${UGROUP} ${VERSION}"
