#!/bin/bash

BOARD="amd64-usr"
GROUP="$1"
VER="$2"
DIR=/home/ec2-user/scripts/oem/ami

if [ -z "$GROUP" -o -z "$VER" ]; then
  echo "Usage: $0 alpha 1.2.3" >&2
  exit 1
fi

set -e
source $DIR/marineam-auth.sh
args="-b $BOARD -g $GROUP -V $VER"
$DIR/import.sh ${args}
$DIR/test_ami.sh -v ${args}
$DIR/copy_ami.sh ${args}

source $DIR/ami-builder-us-gov-auth.sh
$DIR/import.sh ${args}
