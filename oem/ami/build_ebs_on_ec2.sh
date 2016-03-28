#!/bin/bash
#
# This expects to run on an EC2 instance.
#
# mad props to Eric Hammond for the initial script
#  https://github.com/alestic/alestic-hardy-ebs/blob/master/bin/alestic-hardy-ebs-build-ami

# Set pipefail along with -e in hopes that we catch more errors
set -e -o pipefail

DIR=$(dirname $0)
source $DIR/regions.sh

readonly COREOS_EPOCH=1372636800
VERSION="master"
BOARD="amd64-usr"
GROUP="alpha"
IMAGE="coreos_production_ami_image.bin.bz2"
GS_URL="s3://coreos-release-builds"
IMG_URL=""
IMG_PATH=""

USAGE="Usage: $0 [-V 1.2.3] [-p path/image.bz2 | -u http://foo/image.bz2]
Options:
    -V VERSION  Set the version of this AMI, default is 'master'
    -b BOARD    Set to the board name, default is amd64-usr
    -g GROUP    Set the update group, default is alpha or master
    -p PATH     Path to compressed disk image, overrides -u
    -u URL      URL to compressed disk image, derived from -V if unset.
    -s STORAGE  GS URL for Google storage (used to generate URL)
    -h          this ;-)
    -v          Verbose, see all the things!

This script must be run from an ec2 host with the ec2 tools installed.
"

while getopts "V:b:g:p:u:s:hv" OPTION
do
    case $OPTION in
        V) VERSION="$OPTARG";;
        b) BOARD="$OPTARG";;
        g) GROUP="$OPTARG";;
        p) IMG_PATH="$OPTARG";;
        u) IMG_URL="$OPTARG";;
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

# Quick sanity check that the image exists
if [[ -n "$IMG_PATH" ]]; then
    if [[ ! -f "$IMG_PATH" ]]; then
        echo "$0: Image path does not exist: $IMG_PATH" >&2
        exit 1
    fi
    IMG_URL=$(basename "$IMG_PATH")
else
    if [[ -z "$IMG_URL" ]]; then
        IMG_URL="$GS_URL/$GROUP/boards/$BOARD/$VERSION/$IMAGE"
    fi
    if [[ "$IMG_URL" == gs://* ]] || [[ "$IMG_URL" == s3://* ]]; then
        if ! gsutil -q stat "$IMG_URL"; then
            echo "$0: Image URL unavailable: $IMG_URL" >&2
            exit 1
        fi
    else
        if ! curl --fail -s --head "$IMG_URL" >/dev/null; then
            echo "$0: Image URL unavailable: $IMG_URL" >&2
            exit 1
        fi
    fi
fi

if [[ "$VERSION" == "master" ]]; then
    # Come up with something more descriptive and timestamped
    TODAYS_VERSION=$(( (`date +%s` - ${COREOS_EPOCH}) / 86400 ))
    VERSION="${TODAYS_VERSION}-$(date +%H-%M)"
    GROUP="master"
fi

# Size of AMI file system
# TODO: Perhaps define size and arch in a metadata file image_to_vm creates?
size=8 # GB
arch=x86_64
arch2=amd64
# The name has a limited set of allowed characterrs
name=$(sed -e "s%[^A-Za-z0-9()\\./_-]%_%g" <<< "CoreOS-$GROUP-$VERSION")
description="CoreOS $GROUP $VERSION"

zoneurl=http://instance-data/latest/meta-data/placement/availability-zone
zone=$(curl --fail -s $zoneurl)
region=$(echo $zone | sed 's/.$//')
akiid=${ALL_AKIS[$region]}

if [ -z "$akiid" ]; then
   echo "$0: Can't identify AKI, using region: $region" >&2
   exit 1
fi

export EC2_URL="http://ec2.${region}.amazonaws.com"
echo "Building AMI in zone $zone, region id $akiid"

# Create and mount temporary EBS volume with file system to hold new AMI image
volumeid=$(ec2-create-volume --size $size --availability-zone $zone |
  cut -f2)
while ! ec2-describe-volumes "$volumeid" | grep -q available
  do sleep 1; done
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
        bunzip2 -c "$IMG_PATH" | sudo dd of=$dev bs=1M
    else
        sudo dd if="$IMG_PATH" of=$dev bs=1M
    fi
elif [[ "$IMG_URL" == gs://* ]] || [[ "$IMG_URL" == s3://* ]]; then
    gsutil cat "$IMG_URL" | bunzip2 | sudo dd of=$dev bs=1M
else
    curl --fail "$IMG_URL" | bunzip2 | sudo dd of=$dev bs=1M
fi

echo "Detaching $volumeid and creating snapshot"
ec2-detach-volume "$volumeid"
while ec2-describe-volumes "$volumeid" | grep -q ATTACHMENT
  do sleep 3; done
snapshotid=$(ec2-create-snapshot --description "$name" "$volumeid" | cut -f2)
while ec2-describe-snapshots "$snapshotid" | grep -q pending
  do sleep 30; done

echo "Created snapshot $snapshotid, deleting $volumeid"
ec2-delete-volume "$volumeid"

echo "Registering hvm AMI"
hvm_amiid=$(ec2-register                              \
  --name "${name}-hvm"                                \
  --description "$description (HVM)"                  \
  --architecture "$arch"                              \
  --virtualization-type hvm                           \
  --root-device-name /dev/xvda                        \
  --block-device-mapping /dev/xvda=$snapshotid::true  \
  --block-device-mapping /dev/xvdb=ephemeral0         |
  cut -f2)

echo "Registering paravirtual AMI"
amiid=$(ec2-register                                  \
  --name "$name"                                      \
  --description "$description (PV)"                   \
  --architecture "$arch"                              \
  --virtualization-type paravirtual                   \
  --kernel "$akiid"                                   \
  --root-device-name /dev/sda                         \
  --block-device-mapping /dev/sda=$snapshotid::true   \
  --block-device-mapping /dev/sdb=ephemeral0          |
  cut -f2)

cat <<EOF
$description
architecture: $arch ($arch2)
region:       $region ($zone)
aki id:       $akiid
name:         $name
description:  $description
EBS volume:   $volumeid (deleted)
EBS snapshot: $snapshotid
PV AMI id:    $amiid
HVM AMI id:   $hvm_amiid
EOF
