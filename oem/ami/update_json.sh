#!/bin/bash
#
# Set pipefail along with -e in hopes that we catch more errors
set -e -o pipefail

DIR=$(dirname $0)
source $DIR/regions.sh

USAGE="Usage: $0 -V 100.0.0
    -V VERSION  Find AMI by CoreOS version. (required)
    -b BOARD    Set to the board name, default is amd64-usr
    -g GROUP    Set the update group, default is alpha
    -s STORAGE  GS URL for Google storage to upload to.
    -h          this ;-)
    -v          Verbose, see all the things!

This script must be run from an ec2 host with the ec2 tools installed.
"

IMAGE="coreos_production_ami"
GS_URL="gs://builds.release.core-os.net"
AMI=
VER=
BOARD="amd64-usr"
GROUP="alpha"

clean_version() {
    sed -e 's%[^A-Za-z0-9()\\./_-]%_%g' <<< "$1"
}

while getopts "V:b:g:s:hv" OPTION
do
    case $OPTION in
        V) VER="$OPTARG";;
        b) BOARD="$OPTARG";;
        g) GROUP="$OPTARG";;
        s) GS_URL="$OPTARG";;
        h) echo "$USAGE"; exit;;
        v) set -x;;
        *) exit 1;;
    esac
done

if [[ $(id -u) -eq 0 ]]; then
    echo "$0: This command should not be ran run as root!" >&2
    exit 1
fi

if [[ ! -n "$VER" ]]; then
    echo "$0: AMI version required via -V" >&2
    echo "$USAGE" >&2
    exit 1
fi

search_name=$(clean_version "CoreOS-$GROUP-$VER")
declare -A AMIS HVM_AMIS
for r in "${ALL_REGIONS[@]}"; do
    # Hacky but avoids writing an indirection layer to handle auth...
    if [[ "${r}" == "us-gov-west-1" ]]; then
        source $DIR/ami-builder-us-gov-auth.sh
    else
        source $DIR/marineam-auth.sh
    fi

    AMI=$(ec2-describe-images --region=${r} -F name="${search_name}" \
        | grep -m1 ^IMAGE | cut -f2) || true
    if [[ -z "$AMI" ]]; then
        echo "$0: Cannot find an AMI named ${search_name} in ${r}" >&2
        exit 1
    fi
    AMIS[${r}]=$AMI
    HVM=$(ec2-describe-images --region=${r} -F name="${search_name}-hvm" \
        | grep -m1 ^IMAGE | cut -f2) || true
    if [[ -z "$HVM" ]]; then
        echo "$0: Cannot find an AMI named ${search_name}-hvm in ${r}" >&2
        exit 1
    fi
    HVM_AMIS[${r}]=$HVM
done

# ignore this crap: /usr/lib64/python2.6/site-packages/Crypto/Util/number.py:57: PowmInsecureWarning: Not using mpz_powm_sec.  You should rebuild using libgmp >= 5 to avoid timing attack vulnerability.
upload_file() {
    local name="$1"
    local content="$2"
    url="$GS_URL/$GROUP/boards/$BOARD/$VER/${IMAGE}_${name}"
    echo -e "$content" \
        | python -W "ignore:Not using mpz_powm_sec" \
        `which gsutil` cp - "$url"
    echo "OK, ${url}=${content}"
}

publish_ami() {
    local r="$1"
    local virt_type="$2"
    local r_amiid="$3"

    # compatibility name from before addition of hvm
    if [[ "${virt_type}" == "pv" ]]; then
        upload_file "${r}.txt" "$r_amiid"
    fi

    upload_file "${virt_type}_${r}.txt" "$r_amiid"
}

PV_ALL=""
for r in "${!AMIS[@]}"; do
    publish_ami "$r" pv "${AMIS[$r]}"
    PV_ALL+="|${r}=${AMIS[$r]}"
done
PV_ALL="${PV_ALL#|}"

HVM_ALL=""
for r in "${!HVM_AMIS[@]}"; do
    publish_ami "$r" hvm "${HVM_AMIS[$r]}"
    HVM_ALL+="|${r}=${HVM_AMIS[$r]}"
done
HVM_ALL="${HVM_ALL#|}"

AMI_ALL="{\n  \"amis\": ["
for r in "${ALL_REGIONS[@]}"; do
	AMI_ALL+="\n    {"
	AMI_ALL+="\n      \"name\": \"${r}\","
	AMI_ALL+="\n      \"pv\":   \"${AMIS[$r]}\","
	AMI_ALL+="\n      \"hvm\":  \"${HVM_AMIS[$r]}\""
	AMI_ALL+="\n    },"
done
AMI_ALL="${AMI_ALL%,}"
AMI_ALL+="\n  ]\n}"

upload_file "all.txt" "${PV_ALL}"
upload_file "pv.txt" "${PV_ALL}"
upload_file "hvm.txt" "${HVM_ALL}"
upload_file "all.json" "${AMI_ALL}"
echo "Done"
