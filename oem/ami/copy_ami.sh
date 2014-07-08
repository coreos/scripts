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
    AMI=$(ec2-describe-images -F name="CoreOS-$GROUP-$VER" | grep -m1 ^IMAGE \
        | cut -f2) || true # Don't die silently, error messages are good
    if [[ -z "$AMI" ]]; then
        echo "$0: Cannot find an AMI for CoreOS $GROUP $VER" >&2
        exit 1
    fi
    HVM=$(ec2-describe-images -F name="CoreOS-$GROUP-$VER-hvm" \
        | grep -m1 ^IMAGE | cut -f2) || true
    if [[ -z "$HVM" ]]; then
        echo "$0: Cannot find an AMI for CoreOS $GROUP $VER (HVM)" >&2
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
name=$(sed -e "s%[^A-Za-z0-9()\\./_-]%_%g" <<< "CoreOS-$GROUP-$VER")
description="CoreOS $GROUP $VER"

do_copy() {
    local r="$1"
    local virt_type="$2"
    local r_amiid
    if [[ "$virt_type" == "hvm" ]]; then
        r_amiid=$(ec2-copy-image                 \
            --source-region "$region"            \
            --source-ami-id "$HVM"               \
            --name "${name}-hvm"                 \
            --description "$description (HVM)"   \
            --region "$r"                        |
            cut -f2)
    else
        r_amiid=$(ec2-copy-image                 \
            --source-region "$region"            \
            --source-ami-id "$AMI"               \
            --name "$name"                       \
            --description "$description (PV)"    \
            --region "$r"                        |
        cut -f2)
    fi
    echo "AMI copy to $r as $r_amiid in progress"

    local r_amidesc=$(ec2-describe-images "$r_amiid" --region="$r")
    while grep -q pending <<<"$r_amidesc"; do
        sleep 30
        r_amidesc=$(ec2-describe-images "$r_amiid" --region="$r")
    done
    echo "AMI $virt_type copy to $r as $r_amiid in complete"

    local r_snapshotid=$(echo "$r_amidesc" | \
        grep '^BLOCKDEVICEMAPPING.*/dev/xvda' | cut -f5)
    echo "Sharing snapshot $r_snapshotid in $r with Amazon"
    ec2-modify-snapshot-attribute "$r_snapshotid" \
        -c --add 679593333241 --region "$r"

    echo "Making $r_amiid in $r public"
    ec2-modify-image-attribute --region "$r" "$r_amiid" --launch-permission -a all
}

for r in "${REGIONS[@]}"
do
    [ "${r}" == "${region}" ] && continue
    echo "Starting copy of pv $AMI from $region to $r"
    do_copy "$r" pv &
    if [[ -n "$HVM" ]]; then
        echo "Starting copy of hvm $AMI from $region to $r"
        do_copy "$r" hvm &
    fi
done

wait

echo "Done"
