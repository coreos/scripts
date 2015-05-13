#!/bin/bash

# This script will replicate the given image into all Azure regions. It needs
# to be run in an environment where the azure-xplat-cli has been installed and
# configured with the production credentials and (optionally) SUBSCRIPTION_ID
# is defined, containing the subscription GUID.

DIR=$(dirname $0)
. $DIR/common.sh

set -e

GROUP="${1^}"
VERSION=$2

if [[ -z $GROUP || -z $VERSION ]]; then
	echo "Usage: $0 <group> <version>"
	exit 2
fi

image_name="CoreOS-${GROUP}-${VERSION}"

subscription_id=$SUBSCRIPTION_ID
if [ -z $subscription_id ]; then
	subscription_id=$(getSubscriptionId)
fi

requestBody="<ReplicationInput xmlns=\"http://schemas.microsoft.com/windowsazure\">
	<TargetLocations>"
for region in "${REGIONS[@]}"; do
	requestBody+="\n\t\t<Region>$region</Region>"
done
requestBody+="
	</TargetLocations>
	<ComputeImageAttributes>
		<Offer>CoreOS</Offer>
		<Sku>${GROUP}</Sku>
		<Version>${VERSION}</Version>
	</ComputeImageAttributes>
</ReplicationInput>"

url="$(getManagementEndpoint)/${subscription_id}/services/images/${image_name}/replicate"

workdir=$(mktemp --directory)
trap "rm --force --recursive ${workdir}" SIGINT SIGTERM EXIT

azure account cert export \
	--file="${workdir}/cert" \
	--subscription="${subscription_id}" > /dev/null

result=$(echo -e "${requestBody}" | curl \
	--silent \
	--request PUT \
	--header "x-ms-version: 2015-04-01" \
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
