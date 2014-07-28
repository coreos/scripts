#!/bin/bash
#
# This expects to run on an EC2 instance.
#
# mad props to Eric Hammond for the initial script
#  https://github.com/alestic/alestic-hardy-ebs/blob/master/bin/alestic-hardy-ebs-build-ami

# AKI ids from:
#  http://docs.aws.amazon.com/AWSEC2/latest/UserGuide/UserProvidedkernels.html
# we need pv-grub-hd00 x86_64

# Set pipefail along with -e in hopes that we catch more errors
set -e -o pipefail

declare -A AKI
AKI["us-east-1"]=aki-b4aa75dd 
AKI["us-west-1"]=aki-eb7e26ae
AKI["us-west-2"]=aki-f837bac8 
AKI["eu-west-1"]=aki-8b655dff
AKI["ap-southeast-1"]=aki-fa1354a8
AKI["ap-southeast-2"]=aki-3d990e07
AKI["ap-northeast-1"]=aki-40992841
AKI["sa-east-1"]=aki-c88f51d5
# AKI["gov-west-1"]=aki-75a4c056

USAGE="Usage: $0 -a ami-id
    -a ami-id   ID of the AMI to be coppied.
    -V VERSION  Find AMI by CoreOS version.
    -b BOARD    Set to the board name, default is amd64-usr
    -g GROUP    Set the update group, default is alpha
    -h          this ;-)
    -v          Verbose, see all the things!

This script must be run from an ec2 host with the ec2 tools installed.
"

AMI=
VER=
BOARD="amd64-usr"
GROUP="alpha"
REGIONS=()

add_region() {
    if [[ -z "${AKI[$1]}" ]]; then
        echo "Invalid region '$1'" >&2;
        exit 1
    fi
    REGIONS+=( "$1" )
}

clean_version() {
    sed -e 's%[^A-Za-z0-9()\\./_-]%_%g' <<< "$1"
}

while getopts "a:V:b:g:r:hv" OPTION
do
    case $OPTION in
        a) AMI="$OPTARG";;
        V) VER="$OPTARG";;
        b) BOARD="$OPTARG";;
        g) GROUP="$OPTARG";;
        r) add_region "$OPTARG";;
        h) echo "$USAGE"; exit;;
        v) set -x;;
        *) exit 1;;
    esac
done

if [[ $(id -u) -eq 0 ]]; then
    echo "$0: This command should not be ran run as root!" >&2
    exit 1
fi

if [[ -z "$VER" ]]; then
    echo "$0: Providing the verison via -V is required." >&2
    exit 1
fi

zoneurl=http://instance-data/latest/meta-data/placement/availability-zone
zone=$(curl --fail -s $zoneurl)
region=$(echo $zone | sed 's/.$//')
export EC2_URL="http://ec2.${region}.amazonaws.com"

if [[ -z "$AMI" ]]; then
    search_name=$(clean_version "CoreOS-$GROUP-$VER")
    AMI=$(ec2-describe-images -F name="${search_name}" | grep -m1 ^IMAGE \
        | cut -f2) || true # Don't die silently, error messages are good
    if [[ -z "$AMI" ]]; then
        echo "$0: Cannot find an AMI named $search_name" >&2
        exit 1
    fi
    HVM=$(ec2-describe-images -F name="${search_name}-hvm" \
        | grep -m1 ^IMAGE | cut -f2) || true
    if [[ -z "$HVM" ]]; then
        echo "$0: Cannot find an AMI named ${search_name}-hvm" >&2
        exit 1
    fi
else
    # check to make sure this is a valid image
    if ! ec2-describe-images -F image-id="$AMI" | grep -q "$AMI"; then
        echo "$0: Unknown image: $AMI" >&2
        exit 1
    fi
fi

if [[ ${#REGIONS[@]} -eq 0 ]]; then
    REGIONS=( "${!AKI[@]}" )
fi

# The name has a limited set of allowed characterrs
name=$(clean_version "CoreOS-$GROUP-$VER")
description="CoreOS $GROUP $VER"

do_copy() {
    local r="$1"
    local virt_type="$2"
    local local_amiid="$3"
    local r_amiid r_name r_desc

    # run in a subshell, the -e flag doesn't get inherited
    set -e

    echo "Starting copy of $virt_type $local_amiid from $region to $r"
    if [[ "$virt_type" == "hvm" ]]; then
        r_name="${name}-hvm"
        r_desc="${description} (HVM)"
    else
        r_name="${name}"
        r_desc="${description} (PV)"
    fi
    r_amiid=$(ec2-copy-image \
        --source-region "$region" --source-ami-id "$local_amiid" \
        --name "$r_name" --description "$r_desc" --region "$r" |
        cut -f2)
    echo "AMI $virt_type copy to $r as $r_amiid in progress"

    while ec2-describe-images "$r_amiid" --region="$r" | grep -q pending; do
        sleep 30
    done
    echo "AMI $virt_type copy to $r as $r_amiid in complete"
}

WAIT_PIDS=()
for r in "${REGIONS[@]}"
do
    [ "${r}" == "${region}" ] && continue
    do_copy "$r" pv "$AMI" &
    WAIT_PIDS+=( $! )
    if [[ -n "$HVM" ]]; then
        do_copy "$r" hvm "$HVM" &
        WAIT_PIDS+=( $! )
    fi
done

# wait for each subshell individually to report errors
WAIT_FAILED=0
for wait_pid in "${WAIT_PIDS[@]}"; do
    if ! wait ${wait_pid}; then
        : $(( WAIT_FAILED++ ))
    fi
done

if [[ ${WAIT_FAILED} -ne 0 ]]; then
    echo "${WAIT_FAILED} jobs failed :(" >&2
    exit ${WAIT_FAILED}
fi

echo "Done"
