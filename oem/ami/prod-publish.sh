#!/bin/bash

BOARD="amd64-usr"
GROUP="$1"
VER="$2"
DIR=/home/ec2-user/scripts/oem/ami

if [ -z "$GROUP" -o -z "$VER" ]; then
  echo "Usage: $0 alpha 1.2.3" >&2
  exit 1
fi

$DIR/publish_ami.sh -b $BOARD -g $GROUP -V $VER
