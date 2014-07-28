#!/bin/bash

DIR=/home/ec2-user/scripts
URL="https://commondatastorage.googleapis.com/storage.core-os.net/coreos/amd64-usr/master"

set -e
eval $(curl -f "${URL}/version.txt")

source $DIR/marineam-auth.sh
args="-b amd64-usr -g master -V ${COREOS_VERSION}"
$DIR/build_ebs_on_ec2.sh ${args} -u "${URL}/coreos_production_ami_image.bin.bz2"
$DIR/test_ami.sh -v ${args}
#$DIR/copy_ami.sh ${args}
