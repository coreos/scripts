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
    -K KEY      Path to Amazon API private key.
    -C CERT     Path to Amazon API key certificate.
    -h          this ;-)
    -v          Verbose, see all the things!

This script must be run from an ec2 host with the ec2 tools installed.
"

AMI=
VER=

while getopts "a:V:K:C:hv" OPTION
do
    case $OPTION in
        a) AMI="$OPTARG";;
        V) VER="$OPTARG";;
        K) export EC2_PRIVATE_KEY="$OPTARG";;
        C) export EC2_CERT="$OPTARG";;
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

if [[ -z "$AMI" ]]; then
    AMI=$(ec2-describe-images -F name="CoreOS-$VER" | grep -m1 ^IMAGE \
        | cut -f2) || true # Don't die silently, error messages are good
    if [[ -z "$AMI" ]]; then
        echo "$0: Cannot find an AMI for CoreOS $VER" >&2
        exit 1
    fi
else
    # check to make sure this is a valid image
    if ! ec2-describe-images -F image-id="$AMI" | grep -q "$AMI"; then
        echo "$0: Unknown image: $AMI" >&2
        exit 1
    fi
fi

# The name has a limited set of allowed characterrs
name=$(sed -e "s%[^A-Za-z0-9()\\./_-]%_%g" <<< "CoreOS-$VER")
description="CoreOS $VER"

zoneurl=http://instance-data/latest/meta-data/placement/availability-zone
zone=$(curl --fail -s $zoneurl)
region=$(echo $zone | sed 's/.$//')

# hack job to copy AMIs
export EC2_HOME=/home/ubuntu/ec2/ec2-api-tools-1.6.10.0
export JAVA_HOME=/usr

do_copy() {
    local r="$1"
    r_amiid=$($EC2_HOME/bin/ec2-copy-image \
        --source-region "$region"            \
        --source-ami-id "$AMI"               \
        --name "$name"                       \
        --description "$description"         \
        --region "$r"                        |
        cut -f2)
    echo "AMI copy to $r as $r_amiid in progress"

    while ec2-describe-images "$r_amiid" --region="$r" | grep -q pending; do
        sleep 30
    done
    echo "AMI copy to $r as $r_amiid in complete"

    # Not sure if this is needed, permissions seem to be copied
    echo "Making $r_amiid in $r public"
    ec2-modify-image-attribute --region "$r" "$r_amiid" --launch-permission -a all

    # TODO: Add the awsmarket permissions to the snapshot backing the AMI which
    # certainly isn't copied. Need to parse ec2-describe-images or something.
}

for r in "${!AKI[@]}"
do
    [ "${r}" == "${region}" ] && continue
    echo "Starting copy of $AMI from $region to $r"
    do_copy "$r" &
    sleep 15
done

wait

echo "Done"
