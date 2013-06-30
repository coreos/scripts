#!/bin/bash

usage="
usage: $0 <image.bin> <api key> <public-rsa-key> <private-rsa-key>\n
\n
Setting everything up for use\n

1) Run 'gsutil config' and use project id coreos.com:core-update-storage\n
2) Ensure core-admin is installed, it is a recent addition\n

NOTE: Use the chromiumos_image.bin not a qemu/xen/etc image for generating the
update.
"

FILE=$1
APIKEY=$2
PUB=$3
KEY=$4

if [ $# -ne 4 ]; then
  echo -e $usage
  exit
fi

if [ ! -f $FILE ]; then
  echo "ERROR: No such file $FILE"
  echo -e $usage
  exit
fi

# Generate a payload and sign it with our private key
cros_generate_update_payload --image $FILE --output /tmp/update.gz --private_key $KEY

# Verify that the payload signature is OK
delta_generator -in_file /tmp/update.gz -public_key $PUB || exit

# Generate the metadata payload
delta_generator -out_metadata /tmp/update.metadata -private_key $KEY -in_file /tmp/update.gz || exit

MD5SUM=$(md5sum $FILE | cut -f1 -d" ")
gsutil cp /tmp/update.gz gs://update-storage.core-os.net/developer-build/$MD5SUM/update.gz
CORE_UPDATE_URL="https://core-api.appspot.com" core-admin new-version \
	-k $APIKEY -v 9999.0.0 \
	-a {e96281a6-d1af-4bde-9a0a-97b76e56dc57} \
	-m /tmp/update.metadata \
	-t developer-build -p $MD5SUM /tmp/update.gz
