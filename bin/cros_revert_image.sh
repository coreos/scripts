#!/bin/bash

# Usage:
#   revert_image.sh [image_to_revert]
#
# This assumes the image has been updated by update_image.sh.
usage()
{
cat <<EOF

usage:
   revert_image.sh [image_to_revert]
EOF
}

if [[ $# < 1 ]]; then
   echo "Not enough arguments supplied."
   usage
   exit 1
fi

IMAGE=$( readlink -f ${1} )
IMAGE_DIR=$( dirname ${IMAGE} )

if [[ -z "${IMAGE}" ]]; then
   echo "Missing required argument 'image_to_revert'"
   usage
   exit 1
fi

cd ${IMAGE_DIR}

if [[ ! -d "./orig_partitions" ]]; then
   echo "Could not find original partitions."
   exit 1
fi

yes | cp ./orig_partitions/* ./

./pack_partitions.sh ${IMAGE}
rm -rf ./orig_partitions
cd -
