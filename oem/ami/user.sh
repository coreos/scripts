#!/bin/bash

DIR=/home/ec2-user/scripts
USER=someone
TYPE=production
VERSION="367.0.0+2014-07-10-1613"
URL="http://users.developer.core-os.net/${USER}/boards/amd64-usr/${VERSION}"

set -e
eval $(curl -f "${URL}/version.txt")

source $DIR/marineam-auth.sh
args="-b amd64-usr -g ${USER} -V ${VERSION}"
$DIR/import.sh ${args} -u "${URL}/coreos_${TYPE}_ami_image.bin.bz2"
$DIR/test_ami.sh -v ${args}
#$DIR/copy_ami.sh ${args}
