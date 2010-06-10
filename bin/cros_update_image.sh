#!/bin/bash

# Usage:
# update_image.sh [image_to_update] [packages...]
usage()
{
cat <<EOF

usage:
   update_image.sh [image_to_update] [packages...]
EOF
}

if [[ $# < 2 ]]; then
   echo "Not enough arguments supplied."
   usage
   exit 1
fi

if [[ -f /home/${USER}/trunk/src/scripts/.default_board ]]; then
   BOARD=$( cat /home/${USER}/trunk/src/scripts/.default_board )
else
   BOARD=st1q
fi

IMAGE=$( readlink -f ${1} )
IMAGE_DIR=$( dirname ${IMAGE} )
shift
PKGS=$@

if [[ -z "${IMAGE}" || ! -f ${IMAGE} ]]; then
   echo "Missing required argument 'image_to_update'"
   usage
   exit 1
fi

cd ${IMAGE_DIR}
if ! [[ -x ./unpack_partitions.sh && -x ./pack_partitions.sh ]]; then
   echo "Could not find image manipulation scripts."
   exit 1
fi

./unpack_partitions.sh ${IMAGE}
mkdir -p ./rootfs
mkdir -p ./stateful_part
mkdir -p ./orig_partitions

rm -rf ./orig_partitions/*
cp ./part_* ./orig_partitions
sudo mount -o loop part_3 rootfs
sudo mount -o loop part_1 stateful_part
sudo mount --bind stateful_part/dev_image rootfs/usr/local
sudo mount --bind stateful_part/var rootfs/var

emerge-${BOARD} --root="./rootfs" \
   --root-deps=rdeps --nodeps --usepkgonly ${PKGS}

#if the kernel is one of the packages that got updated
#we need to update the kernel partition as well.
if [[ ${PKGS/kernel/} != ${PKGS} ]]; then
   rm -rf part_2
   sudo dd if="/dev/zero" of=part_2 bs=512 count=8192
   sudo dd if="./rootfs/boot/vmlinuz" of=part_2 bs=512 count=8192 conv=notrunc
fi

sudo umount rootfs/usr/local
sudo umount rootfs/var
sudo umount rootfs
sudo umount stateful_part
./pack_partitions.sh ${IMAGE}

cd -
