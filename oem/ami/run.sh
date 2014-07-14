#!/bin/bash

BOARD="amd64-usr"
GROUP="$1"
VER="$2"
DIR=/home/ec2-user/scripts

if [ -z "$GROUP" -o -z "$VER" ]; then
  echo "Usage: $0 alpha 1.2.3" >&2
  exit 1
fi

set -e
args="-b $BOARD -g $GROUP -V $VER"
sudo bash -c ". $DIR/marineam-auth.sh && $DIR/build_ebs_on_ec2.sh ${args}"
source $DIR/marineam-auth.sh
$DIR/test_ami.sh -v ${args}
$DIR/copy_ami.sh ${args}
$DIR/upload_ami_txt.sh ${args}
