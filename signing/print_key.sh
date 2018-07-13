#!/usr/bin/env bash
# If there is no default printer use ./print_key.sh prod-2 -d printer_name
# List available printers with lpstat -a

set -ex
KEY="$1"
shift
qrencode -8 -o - < "${KEY}.key.pem" | lp -E -o fit-to-page "$@"
