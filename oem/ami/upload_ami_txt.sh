#!/bin/bash
#
# Set pipefail along with -e in hopes that we catch more errors
set -e -o pipefail

USAGE="Usage: $0 -a ami-id
    -V VERSION  Find AMI by CoreOS version. (required)
    -K KEY      Path to Amazon API private key.
    -C CERT     Path to Amazon API key certificate.
    -h          this ;-)
    -v          Verbose, see all the things!

This script must be run from an ec2 host with the ec2 tools installed.
"

IMAGE="coreos_production_ami"
URL_FMT="gs://storage.core-os.net/coreos/amd64-generic/%s/${IMAGE}_%s.txt"
AMI=
VER=

while getopts "a:V:K:C:hv" OPTION
do
    case $OPTION in
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

if [[ -n "$VER" ]]; then
    AMI=$(ec2-describe-images -F name="CoreOS-$VER" | grep -m1 ^IMAGE \
        | cut -f2) || true # Don't die silently, error messages are good
    if [[ -z "$AMI" ]]; then
        echo "$0: Cannot find an AMI for CoreOS $VER" >&2
        exit 1
    fi
else
    echo "$0: AMI version required via -V" >&2
    echo "$USAGE" >&2
    exit 1
fi

zoneurl=http://instance-data/latest/meta-data/placement/availability-zone
zone=$(curl --fail -s $zoneurl)
region=$(echo $zone | sed 's/.$//')
url=$(printf "$URL_FMT" "$VER" "$region")

tmp=$(mktemp --suffix=.txt)
trap "rm -f '$tmp'" EXIT
echo "$AMI" > "$tmp"
gsutil cp "$tmp" "$url"
echo "OK"
