#!/bin/bash
#
# Set pipefail along with -e in hopes that we catch more errors
set -e -o pipefail

DIR=$(dirname $0)
source $DIR/regions.sh

USAGE="Usage: $0 -V 100.0.0
    -V VERSION  Find AMI by CoreOS version. (required)
    -b BOARD    Set to the board name, default is amd64-usr
    -g GROUP    Set the update group, default is alpha
    -h          this ;-)
    -v          Verbose, see all the things!

This script must be run from an ec2 host with the ec2 tools installed.
"

IMAGE="coreos_production_ami"
AMI=
VER=
BOARD="amd64-usr"
GROUP="alpha"

clean_version() {
    sed -e 's%[^A-Za-z0-9()\\./_-]%_%g' <<< "$1"
}

while getopts "V:b:g:s:hv" OPTION
do
    case $OPTION in
        V) VER="$OPTARG";;
        b) BOARD="$OPTARG";;
        g) GROUP="$OPTARG";;
        h) echo "$USAGE"; exit;;
        v) set -x;;
        *) exit 1;;
    esac
done

if [[ $(id -u) -eq 0 ]]; then
    echo "$0: This command should not be ran run as root!" >&2
    exit 1
fi

if [[ ! -n "$VER" ]]; then
    echo "$0: AMI version required via -V" >&2
    echo "$USAGE" >&2
    exit 1
fi

search_name=$(clean_version "CoreOS-$GROUP-$VER")
declare -A PV_AMIS HVM_AMIS IS_PV_AMIS IS_HVM_AMIS
for r in "${ALL_REGIONS[@]}"; do
    # Hacky but avoids writing an indirection layer to handle auth...
    if [[ "${r}" == "us-gov-west-1" ]]; then
        source $DIR/ami-builder-us-gov-auth.sh
    else
        source $DIR/marineam-auth.sh
    fi

    AMI=$(ec2-describe-images --region=${r} -F name="${search_name}-pv" \
        | grep -m1 ^IMAGE | cut -f2) || true
    if [[ -z "$AMI" ]]; then
        echo "$0: Cannot find an AMI named ${search_name}-pv in ${r}" >&2
        exit 1
    fi
    PV_AMIS[${r}]=$AMI
    
    AMI=$(ec2-describe-images --region=${r} -F name="${search_name}-hvm" \
        | grep -m1 ^IMAGE | cut -f2) || true
    if [[ -z "$AMI" ]]; then
        echo "$0: Cannot find an AMI named ${search_name}-hvm in ${r}" >&2
        exit 1
    fi
    HVM_AMIS[${r}]=$AMI
    
    AMI=$(ec2-describe-images --region=${r} -F name="${search_name}-is-pv" \
        | grep -m1 ^IMAGE | cut -f2) || true
    if [[ -z "$AMI" ]]; then
        echo "$0: Cannot find an AMI named ${search_name}-is-pv in ${r}" >&2
        exit 1
    fi
    IS_PV_AMIS[${r}]=$AMI
    
    AMI=$(ec2-describe-images --region=${r} -F name="${search_name}-is-hvm" \
        | grep -m1 ^IMAGE | cut -f2) || true
    if [[ -z "$AMI" ]]; then
        echo "$0: Cannot find an AMI named ${search_name}-is-hvm in ${r}" >&2
        exit 1
    fi
    IS_HVM_AMIS[${r}]=$AMI
done

publish_ami() {
    local r="$1"
    local root_type="$2"
    local r_amiid="$3"

    if [[ "${r}" == "us-gov-west-1" ]]; then
        source $DIR/ami-builder-us-gov-auth.sh
    else
        source $DIR/marineam-auth.sh
    fi

    # Only required for publishing EBS images to the marketplace
    if [[ "$r" == "us-east-1" && "$root_type" == "ebs" ]]; then
        local r_snapshotid=$(ec2-describe-images --region="$r" "$r_amiid" \
            | grep -E '^BLOCKDEVICEMAPPING.*/dev/(xv|s)da' | cut -f5) || true

        if [[ -z "${r_snapshotid}" ]]; then
            echo "$0: Cannot find snapshot id for $r_amiid in $r" >&2
            return 1
        fi

        echo "Sharing snapshot $r_snapshotid in $r with Amazon"
        ec2-modify-snapshot-attribute --region "$r" \
            "$r_snapshotid" -c --add 679593333241
    fi

    echo "Making $r_amiid in $r public"
    ec2-modify-image-attribute --region "$r" \
        "$r_amiid" --launch-permission -a all
}

for r in "${!PV_AMIS[@]}"; do
    publish_ami "$r" ebs "${PV_AMIS[$r]}"
done

for r in "${!HVM_AMIS[@]}"; do
    publish_ami "$r" ebs "${HVM_AMIS[$r]}"
done

for r in "${!IS_PV_AMIS[@]}"; do
    publish_ami "$r" is "${IS_PV_AMIS[$r]}"
done

for r in "${!IS_HVM_AMIS[@]}"; do
    publish_ami "$r" is "${IS_HVM_AMIS[$r]}"
done
