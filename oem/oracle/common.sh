# Get the tenancy ID, which is also the ID of the root compartment.
# Unconditionally uses the first profile in the conffile.
get_tenancy_id() {
    local line=$(grep -m 1 "^tenancy=" "$HOME/.oraclebmc/config")
    echo "${line#*=}"
}

# Pick an availability domain by listing them and choosing the first one.
get_availability_domain() {
    local compartment="$1"
    bmcs iam availability-domain list \
        -c "${compartment}" | jq -r ".data[0].name"
}

# Pick a subnet ID by picking the first VCN and then the first subnet in the
# specified availability domain.
get_subnet_id() {
    local compartment="$1"
    local availability_domain="$2"
    local vcn=$(bmcs network vcn list \
        -c "${compartment}" | jq -r ".data[0].id")
    bmcs network subnet list \
        -c "${compartment}" \
        --vcn-id "${vcn}" | jq -r ".data[] | select(.[\"availability-domain\"] == \"${availability_domain}\").id"
}

# Get the object storage namespace ID.
get_namespace_id() {
    bmcs os ns get | jq -r ".data"
}

# Get the ID of some arbitrary image.  Useful for iPXE boot, which requires
# an image ID but doesn't seem to use it.
get_an_image_id() {
    local compartment="$1"
    bmcs compute image list \
        -c "${compartment}" \
        --operating-system "CentOS" \
        --operating-system-version 7 | jq -r '.data[0].id'
}
