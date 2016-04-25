AZURE_ENVIRONMENT=AzureCloud
REGIONS=(
	"West Europe"
	"North Europe"
	"East Asia"
	"Southeast Asia"
	"East US"
	"West US"
	"Japan East"
	"Japan West"
	"Central US"
	"East US 2"
	"Brazil South"
	"North Central US"
	"South Central US"
	"Australia East"
	"Australia Southeast"
	"Central India"
	"West India"
	"South India"
	"Canada Central"
	"Canada East"
	"UK North"
	"UK South 2"
)

getManagementEndpoint() {
	azure account env show --environment=$AZURE_ENVIRONMENT --json | \
		jq '.managementEndpointUrl' --raw-output
}

getSubscriptionId() {
	azure account show --json | \
		jq '.[0].id' --raw-output
}
