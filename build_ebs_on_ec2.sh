#!/bin/bash -ex
#
# This expects to run on an EC2 instance.
#

# AKI ids from:
#  http://docs.aws.amazon.com/AWSEC2/latest/UserGuide/UserProvidedkernels.html
# we need pv-grub-hd00 x86_64

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
TODAYS_VERSION=$(( (`date +%s` - ${COREOS_EPOCH}) / 86400 ))
EXTRA_VERSION=$(date +%H-%M)

if [ -z "$1" ]; then
	echo "usage: $0 [http|path/to/bin.bz2]"
	exit 1
fi

binurl=$1

# Size of AMI file system
size=8 # GB

arch=x86_64
arch2=amd64
ephemeraldev=/dev/sdb
version="master-$TODAYS_VERSION-$EXTRA_VERSION"

#TBD
name="CoreOS-$version"
description="CoreOS master"

export EC2_CERT=$(echo /tmp/*cert*.pem)
export EC2_PRIVATE_KEY=$(echo /tmp/*pk*.pem)

zoneurl=http://instance-data/latest/meta-data/placement/availability-zone
zone=$(curl -s $zoneurl)
region=$(echo $zone | sed 's/.$//')

# this is defined in: build_library/ami_constants.sh
akiid=${AKI[$region]}

if [ -z "$akiid" ]; then
   echo "$0: Can't identify AKI, using region: $region";
   exit 1
fi

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

export EC2_URL=http://ec2.$region.amazonaws.com

# Create and mount temporary EBS volume with file system to hold new AMI image
volumeid=$(ec2-create-volume --size $size --availability-zone $zone |
  cut -f2)
instanceid=$(wget -qO- http://instance-data/latest/meta-data/instance-id)
ec2-attach-volume --device /dev/sdi --instance "$instanceid" "$volumeid"
while [ ! -e /dev/sdi -a ! -e /dev/xvdi ]
  do sleep 3; done
if [ -e /dev/xvdi ]; then
   dev=/dev/xvdi
else
   dev=/dev/sdi 
fi

# if it is on the local fs, just use it, otherwise try to download it
if [ -e "$binurl" ]; then
	bzcat $binurl | dd of=$dev bs=128M
else
	curl -s $binurl | bunzip2 | dd of=$dev bs=128M
fi

ec2-detach-volume "$volumeid"
while ec2-describe-volumes "$volumeid" | grep -q ATTACHMENT
  do sleep 3; done
snapshotid=$(ec2-create-snapshot --description "$name" "$volumeid" | cut -f2)
while ec2-describe-snapshots "$snapshotid" | grep -q pending
  do sleep 30; done

# Register the snapshot as a new AMI
amiid=$(ec2-register                                  \
  --name "$name"                                      \
  --description "$description"                        \
  --architecture "$arch"                              \
  --kernel "$akiid"                                   \
  --block-device-mapping /dev/sda=$snapshotid::true   \
  --block-device-mapping $ephemeraldev=ephemeral0     \
  --snapshot "$snapshotid" |
  cut -f2)

ec2-delete-volume "$volumeid"

cat <<EOF
AMI: $amiid $codename $region $arch2

CoreOS $version
architecture: $arch ($arch2)
region:       $region ($zone)
aki id:       $akiid
name:         $name
description:  $description
EBS volume:   $volumeid (deleted)
EBS snapshot: $snapshotid
AMI id:       $amiid
bin url:      $binurl

Test the new AMI using something like:

  export EC2_URL=http://ec2.$region.amazonaws.com
  ec2-run-instances \\
    --key \$USER \\
    --instance-type t1.micro \\
    $amiid

EOF
