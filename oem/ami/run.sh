#!/bin/bash

VER="$1"
DIR=/home/ubuntu/official

if [ -z "$VER" ]; then
  echo "Usage: $0 1.2.3" >&2
  exit 1
fi

set -e
sudo $DIR/build_ebs_on_ec2.sh -V $VER -K $DIR/aws-pk.pem -C $DIR/aws-cert.pem
$DIR/test_ami.sh -v -V $VER -K $DIR/aws-pk.pem -C $DIR/aws-cert.pem
$DIR/copy_ami.sh -V $VER -K $DIR/aws-pk.pem -C $DIR/aws-cert.pem
$DIR/upload_ami_txt.sh -V $VER -K $DIR/aws-pk.pem -C $DIR/aws-cert.pem
