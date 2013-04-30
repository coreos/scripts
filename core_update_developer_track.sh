#!/bin/bash

usage="
usage: $0 <image.bin> <api key>\n
\n
Setting everything up for use\n
1) Run 'gsutil config' and use project id coreos.com:core-update-storage\n
2) Ensure core-admin is installed, it is a recent addition\n
"

FILE=$1
KEY=$2

if [ $# -ne 2 ]; then
  echo -e $usage
  exit
fi

if [ ! -f $FILE ]; then
  echo "ERROR: No such file $FILE"
  echo -e $usage
  exit
fi

cros_generate_update_payload --image $FILE --output /tmp/update.gz
MD5SUM=$(md5sum $FILE | cut -f1 -d" ")
core-admin new-version -k $KEY -v 9999.0.0 -a {87efface-864d-49a5-9bb3-4b050a7c227a} -t developer-build -p $MD5SUM /tmp/update.gz
gsutil cp /tmp/update.gz gs://update-storage.core-os.net/developer-build/$MD5SUM/update.gz
