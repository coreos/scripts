#!/usr/bin/env bash

# This script will set the icon, recommended VM size, and optionally the
# publication date for the specified OS image to the CoreOS logo. It needs to
# be run in an environment where the azure-xplat-cli has been installed and
# configured with the production credentials and (optionally) SUBSCRIPTION_ID
# is defined, containing the subscription GUID.

DIR=$(dirname $0)
. $DIR/common.sh

set -e

# These icon names are effectively magic constants. At some point, these assets
# were given to an Azure team and they uploaded them into their system.
ICON="coreos-globe-color-lg-100px.png"
SMALL_ICON="coreos-globe-color-lg-45px.png"

RECOMMENDED_VM_SIZE="Medium"

GROUP="${1^}"
VERSION=$2
DATE=$3

if [[ -z $GROUP || -z $VERSION ]]; then
	echo "Usage: $0 <group> <version> [<published date>]"
	exit 2
fi

image_name="CoreOS-${GROUP}-${VERSION}"
label="CoreOS ${GROUP}"
image_family=$label
published_date=$(date --date="${DATE}" --rfc-3339=date)
description=""
case $GROUP in
	Alpha)
		description="The Alpha channel closely tracks current development work and is released frequently. The newest versions of docker, etcd and fleet will be available for testing."
		;;
	Beta)
		description="The Beta channel consists of promoted Alpha releases. Mix a few Beta machines into your production clusters to catch any bugs specific to your hardware or configuration."
		;;
	Stable)
		description="The Stable channel should be used by production clusters. Versions of CoreOS are battle-tested within the Beta and Alpha channels before being promoted."
		;;
	*)
		echo "Invalid group \"${1}\""
		exit 2
		;;
esac

subscription_id=$SUBSCRIPTION_ID
if [ -z $subscription_id ]; then
	subscription_id=$(getSubscriptionId)
fi

requestBody="<OSImage xmlns=\"http://schemas.microsoft.com/windowsazure\"
	xmlns:i=\"http://www.w3.org/2001/XMLSchema-instance\">

	<Label>${label}</Label>
	<Name>${image_name}</Name>
	<Description>${description}</Description>
	<ImageFamily>${image_family}</ImageFamily>
	<PublishedDate>${published_date}</PublishedDate>
	<IconUri>${ICON}</IconUri>
	<RecommendedVMSize>${RECOMMENDED_VM_SIZE}</RecommendedVMSize>
	<SmallIconUri>${SMALL_ICON}</SmallIconUri>
</OSImage>"

url="$(getManagementEndpoint)/${subscription_id}/services/images/${image_name}"

workdir=$(mktemp --directory)
trap "rm --force --recursive ${workdir}" SIGINT SIGTERM EXIT

azure account cert export \
	--file="${workdir}/cert" \
	--subscription="${subscription_id}" > /dev/null

result=$(echo "${requestBody}" | curl \
	--silent \
	--request PUT \
	--header "x-ms-version: 2013-08-01" \
	--header "Content-Type: application/xml" \
	--cert "${workdir}/cert" \
	--url "${url}" \
	--write-out "%{http_code}" \
	--output "${workdir}/out" \
	--data-binary @-)

if [[ $result != 200 ]]; then
	echo "${result} - $(< ${workdir}/out)"
	exit 1
fi
