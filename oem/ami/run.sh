#!/bin/bash

BOARD="$1"
VER="$2"
DIR=/home/ubuntu/official

if [ -z "$BOARD" -o -z "$VER" ]; then
  echo "Usage: $0 amd64-usr 1.2.3" >&2
  exit 1
fi

set -e
args=( -b $BOARD -V $VER -K $DIR/aws-pk.pem -C $DIR/aws-cert.pem )
sudo $DIR/build_ebs_on_ec2.sh "${args[@]}"
$DIR/test_ami.sh -v "${args[@]}"
$DIR/copy_ami.sh "${args[@]}"
$DIR/upload_ami_txt.sh "${args[@]}"
