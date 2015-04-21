#!/bin/bash
#
# This expects to run on an EC2 instance.

# Set pipefail along with -e in hopes that we catch more errors
set -e -o pipefail

# accepted via the environment
: ${EC2_IMPORT_BUCKET:=}
: ${EC2_IMPORT_ZONE:=}

USAGE="Usage: $0 [-B bucket] [-Z zone]
Options:
    -B          S3 bucket to use for temporary storage.
    -Z          EC2 availability zone to use.
    -h          this ;-)
    -v          Verbose, see all the things!

This script must be run from an ec2 host with the ec2 tools installed.
"

while getopts "B:Z:hv" OPTION
do
    case $OPTION in
        B) EC2_IMPORT_BUCKET="${OPTARG}";;
        Z) EC2_IMPORT_ZONE="${OPTARG}";;
        h) echo "$USAGE"; exit;;
        v) set -x;;
        *) exit 1;;
    esac
done

if [[ $(id -u) -eq 0 ]]; then
    echo "$0: This command should not be ran run as root!" >&2
    exit 1
fi

if [[ -z "${EC2_IMPORT_BUCKET}" ]]; then
    echo "$0: -B or \$EC2_IMPORT_BUCKET must be set!" >&2
    exit 1
fi

if [[ -z "${EC2_IMPORT_ZONE}" ]]; then
    zoneurl=http://instance-data/latest/meta-data/placement/availability-zone
    EC2_IMPORT_ZONE=$(curl --fail -s $zoneurl)
fi
region=$(echo "${EC2_IMPORT_ZONE}" | sed 's/.$//')

# The AWS cli uses slightly different vars than the EC2 cli...
export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_KEY}"
aws s3 mb "s3://${EC2_IMPORT_BUCKET}" --region "$region"
