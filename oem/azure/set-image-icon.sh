#!/bin/bash

# This script will set the icon for the specified OS image to the CoreOS logo.
# It needs to be run in an environment where the azure-xplat-cli has been
# installed and configured with the production credentials and (optionally)
# SUBSCRIPTION_ID is defined, containing the subscription GUID.

DIR=$(dirname $0)
. $DIR/common.sh

set -e

# These icon names are effectively magic constants. At some point, these assets
# were given to an Azure team and they uploaded them into their system.
ICON="coreos-globe-color-lg-100px.png"
SMALL_ICON="coreos-globe-color-lg-45px.png"

GROUP="${1^}"
VERSION=$2

if [[ -z $GROUP || -z $VERSION ]]; then
	echo "Usage: $0 <group> <version>"
	exit 2
fi

image_name="CoreOS-${GROUP}-${VERSION}"
label="CoreOS ${GROUP}"
workdir=$(mktemp --directory)

subscription_id=$SUBSCRIPTION_ID
if [ -z $subscription_id ]; then
	subscription_id=$(getSubscriptionId)
fi

requestBody="<OSImage xmlns=\"http://schemas.microsoft.com/windowsazure\"
	xmlns:i=\"http://www.w3.org/2001/XMLSchema-instance\">

	<Label>${label}</Label>
	<Name>${image_name}</Name>
	<IconUri>${ICON}</IconUri>
	<SmallIconUri>${SMALL_ICON}</SmallIconUri>
</OSImage>"

url="$(getManagementEndpoint)/${subscription_id}/services/images/${image_name}"

azure account cert export \
	--file="${workdir}/cert" \
	--subscription="${subscription_id}" > /dev/null

trap "rm --force --recursive ${workdir}" SIGINT SIGTERM EXIT

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
