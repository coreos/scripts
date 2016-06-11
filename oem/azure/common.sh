getAzureEnvironment() {
	azure account show --json | \
		jq '.[0].environmentName' --raw-output
}

getManagementEndpoint() {
	azure account env show --environment=$(getAzureEnvironment) --json | \
		jq '.managementEndpointUrl' --raw-output
}

getStorageEndpointPrefix() {
	prefix=$(azure account env show --environment=$(getAzureEnvironment) --json | \
		jq '.storageEndpointSuffix' --raw-output)
	echo "${prefix##.}"
}

getBlobStorageEndpoint() {
	echo "blob.$(getStorageEndpointPrefix)"
}

getSubscriptionId() {
	azure account show --json | \
		jq '.[0].id' --raw-output
}

getRegions() {
	azure vm location list --json | jq '.[].name' --raw-output
}
