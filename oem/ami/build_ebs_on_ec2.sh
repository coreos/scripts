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

readonly COREOS_EPOCH=1372636800
VERSION="master"
IMAGE="coreos_production_ami_image.bin.bz2"
URL_FMT="http://storage.core-os.net/coreos/amd64-generic/%s/$IMAGE"
IMG_URL=""
IMG_PATH=""

USAGE="Usage: $0 [-V 1.2.3] [-p path/image.bz2 | -u http://foo/image.bz2]
Options:
    -V VERSION  Set the version of this AMI, default is 'master'
    -p PATH     Path to compressed disk image, overrides -u
    -u URL      URL to compressed disk image, derived from -V if unset.
    -K KEY      Path to Amazon API private key.
    -C CERT     Path to Amazon API key certificate.
    -h          this ;-)
    -v          Verbose, see all the things!

This script must be run from an ec2 host with the ec2 tools installed.
"

while getopts "V:p:u:K:C:hv" OPTION
do
    case $OPTION in
        V) VERSION="$OPTARG";;
        p) IMG_PATH="$OPTARG";;
        u) IMG_URL="$OPTARG";;
        K) export EC2_PRIVATE_KEY="$OPTARG";;
        C) export EC2_CERT="$OPTARG";;
        h) echo "$USAGE"; exit;;
        v) set -x;;
        *) exit 1;;
    esac
done

if [[ $(id -u) -ne 0 ]]; then
    echo "$0: This command must be run as root!" >&2
    exit 1
fi

# Quick sanity check that the image exists
if [[ -n "$IMG_PATH" ]]; then
    if [[ ! -f "$IMG_PATH" ]]; then
        echo "$0: Image path does not exist: $IMG_PATH" >&2
        exit 1
    fi
    IMG_URL=$(basename "$IMG_PATH")
else
    if [[ -z "$IMG_URL" ]]; then
        IMG_URL=$(printf "$URL_FMT" "$VERSION")
    fi
    if ! curl --fail -s --head "$IMG_URL" >/dev/null; then
        echo "$0: Image URL unavailable: $IMG_URL" >&2
        exit 1
    fi
fi

if [[ "$VERSION" == "master" ]]; then
    # Come up with something more descriptive and timestamped
    TODAYS_VERSION=$(( (`date +%s` - ${COREOS_EPOCH}) / 86400 ))
    VERSION="master-${TODAYS_VERSION}-$(date +%H-%M)"
fi


# Size of AMI file system
# TODO: Perhaps define size and arch in a metadata file image_to_vm creates?
size=8 # GB
arch=x86_64
arch2=amd64
ephemeraldev=/dev/sdb
# The name has a limited set of allowed characterrs
name=$(sed -e "s%[^A-Za-z0-9()\\./_-]%_%g" <<< "CoreOS-$VERSION")
description="CoreOS $VERSION"

zoneurl=http://instance-data/latest/meta-data/placement/availability-zone
zone=$(curl --fail -s $zoneurl)
region=$(echo $zone | sed 's/.$//')
akiid=${AKI[$region]}

if [ -z "$akiid" ]; then
   echo "$0: Can't identify AKI, using region: $region" >&2
   exit 1
fi

# TODO: Once we sort out a long-term scheme for generating AMIs this likely
# will go away. What if we want to generate AMIs from CoreOS?!?!?
if [ -z "$(which ec2-attach-volume)" ]; then
	# Update and install Ubuntu packages
	export DEBIAN_FRONTEND=noninteractive
	sudo perl -pi -e 's/^# *(deb .*multiverse)$/$1/' /etc/apt/sources.list
	sudo apt-get update
	sudo -E apt-get upgrade -y
	sudo -E apt-get install -y \
	  ec2-api-tools            \
	  ec2-ami-tools 
fi

export EC2_URL="http://ec2.${region}.amazonaws.com"
echo "Building AMI in zone $zone, region id $akiid"

# Create and mount temporary EBS volume with file system to hold new AMI image
volumeid=$(ec2-create-volume --size $size --availability-zone $zone |
  cut -f2)
instanceid=$(curl --fail -s http://instance-data/latest/meta-data/instance-id)
echo "Attaching new volume $volumeid locally (instance $instanceid)"
ec2-attach-volume --device /dev/sdi --instance "$instanceid" "$volumeid"
while [ ! -e /dev/sdi -a ! -e /dev/xvdi ]
  do sleep 3; done
if [ -e /dev/xvdi ]; then
   dev=/dev/xvdi
else
   dev=/dev/sdi 
fi

echo "Attached volume $volumeid as $dev"
echo "Writing image from $IMG_URL to $dev"

# if it is on the local fs, just use it, otherwise try to download it
if [[ -n "$IMG_PATH" ]]; then
    if [[ "$IMG_PATH" =~ \.bz2$ ]]; then
        bunzip2 -c "$IMG_PATH" | dd of=$dev bs=1M
    else
        dd if="$IMG_PATH" of=$dev bs=1M
    fi
else
    curl --fail "$IMG_URL" | bunzip2 | dd of=$dev bs=1M
fi

echo "Detaching $volumeid and creating snapshot"
ec2-detach-volume "$volumeid"
while ec2-describe-volumes "$volumeid" | grep -q ATTACHMENT
  do sleep 3; done
snapshotid=$(ec2-create-snapshot --description "$name" "$volumeid" | cut -f2)
while ec2-describe-snapshots "$snapshotid" | grep -q pending
  do sleep 30; done

echo "Created snapshot $snapshotid, registering as a new AMI"
amiid=$(ec2-register                                  \
  --name "$name"                                      \
  --description "$description"                        \
  --architecture "$arch"                              \
  --kernel "$akiid"                                   \
  --block-device-mapping /dev/sda=$snapshotid::true   \
  --block-device-mapping $ephemeraldev=ephemeral0     |
  cut -f2)

ec2-delete-volume "$volumeid"

cat <<EOF
AMI: $amiid $region $arch2

CoreOS $VERSION
architecture: $arch ($arch2)
region:       $region ($zone)
aki id:       $akiid
name:         $name
description:  $description
EBS volume:   $volumeid (deleted)
EBS snapshot: $snapshotid
AMI id:       $amiid
bin url:      $IMG_URL

Test the new AMI using something like:

  export EC2_URL=http://ec2.${region}.amazonaws.com
  ec2-run-instances \\
    --key \$USER \\
    --instance-type t1.micro \\
    $amiid

EOF
