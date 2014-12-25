AZURE_ENVIRONMENT=AzureCloud

getManagementEndpoint() {
	azure account env show --environment=$AZURE_ENVIRONMENT --json | \
		jq '.managementEndpointUrl' --raw-output
}

getSubscriptionId() {
	azure account show --json | \
		jq '.id' --raw-output
}
