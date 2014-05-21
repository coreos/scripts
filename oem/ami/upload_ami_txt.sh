#!/bin/bash
#
# Set pipefail along with -e in hopes that we catch more errors
set -e -o pipefail

# we just use this for the list of regions
# should a copy/paste from build_ebs_on_ec2.sh
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

USAGE="Usage: $0 -V 100.0.0
    -V VERSION  Find AMI by CoreOS version. (required)
    -b BOARD    Set to the board name, default is amd64-usr
    -g GROUP    Set the update group, default is alpha
    -s STORAGE  GS URL for Google storage to upload to.
    -h          this ;-)
    -v          Verbose, see all the things!

This script must be run from an ec2 host with the ec2 tools installed.
"

IMAGE="coreos_production_ami"
GS_URL="gs://builds.release.core-os.net"
AMI=
VER=
BOARD="amd64-usr"
GROUP="alpha"

while getopts "V:b:g:s:hv" OPTION
do
    case $OPTION in
        V) VER="$OPTARG";;
        b) BOARD="$OPTARG";;
        g) GROUP="$OPTARG";;
        s) GS_URL="$OPTARG";;
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

declare -A AMIS
for r in "${!AKI[@]}"; do
    AMI=$(ec2-describe-images --region=${r} -F name="CoreOS-$GROUP-$VER" \
        | grep -m1 ^IMAGE \
        | cut -f2) || true # Don't die silently, error messages are good
    if [[ -z "$AMI" ]]; then
        echo "$0: Cannot find ${r} AMI for CoreOS $GROUP $VER" >&2
        continue
    fi
    AMIS[${r}]=$AMI
done

OUT=
for r in "${!AMIS[@]}"; do
    url="$GS_URL/$GROUP/$BOARD/$VER/${IMAGE}_${r}.txt"
    tmp=$(mktemp --suffix=.txt)
    trap "rm -f '$tmp'" EXIT
    echo "${AMIS[$r]}" > "$tmp"
    gsutil cp "$tmp" "$url"
    echo "OK, $r ${AMIS[$r]}, $url"
    if [[ -z "$OUT" ]]; then
        OUT="${r}=${AMIS[$r]}"
    else
        OUT="${OUT}|${r}=${AMIS[$r]}"
    fi
done
url="$GS_URL/$GROUP/$BOARD/$VER/${IMAGE}_all.txt"
tmp=$(mktemp --suffix=.txt)
trap "rm -f '$tmp'" EXIT
echo "$OUT" > "$tmp"
gsutil cp "$tmp" "$url"
echo "OK, all, $url"
