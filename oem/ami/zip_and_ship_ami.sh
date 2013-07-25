#!/bin/bash -xe
#
# this needs more refactoring, but is used to build the latest image

IMG="../build/images/amd64-generic/latest/coreos_ami_image.bin"
ssh -i ~/.ssh/coreos-images.pem ubuntu@23.22.1.1 "mkdir -p /mnt/tmp"

bzip2 $IMG
scp -i ~/.ssh/coreos-images.pem build_ebs_on_ec2.sh $IMG.bz2 ubuntu@23.22.1.1:/mnt/tmp
ssh -i ~/.ssh/coreos-images.pem ubuntu@23.22.1.1 "sudo /mnt/tmp/build_ebs_on_ec2.sh /mnt/tmp/coreos_ami_image.bin.bz2"
