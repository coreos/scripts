#!/bin/bash
#
# Set pipefail along with -e in hopes that we catch more errors
set -e -o pipefail

REGIONS=(
    us-east-1
    us-west-1
    us-west-2
    eu-west-1
    eu-central-1
    ap-southeast-1
    ap-southeast-2
    ap-northeast-1
    sa-east-1
)

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
for r in "${REGIONS[@]}"; do
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
    url="$GS_URL/$GROUP/boards/$BOARD/$VER/${IMAGE}_${name}.txt"
    python -W "ignore:Not using mpz_powm_sec" \
        `which gsutil` cp - "$url" <<<"$content"
    echo "OK, ${url}=${content}"
}

publish_ami() {
    local r="$1"
    local virt_type="$2"
    local r_amiid="$3"
    local r_snapshotid=$(ec2-describe-images --region="$r" "$r_amiid" \
        | grep -E '^BLOCKDEVICEMAPPING.*/dev/(xv|s)da' | cut -f5) || true

    # run in a subshell, the -e flag doesn't get inherited
    set -e

    if [[ -z "${r_snapshotid}" ]]; then
        echo "$0: Cannot find snapshot id for $r_amiid in $r" >&2
        return 1
    fi

    echo "Sharing snapshot $r_snapshotid in $r with Amazon"
    ec2-modify-snapshot-attribute --region "$r" \
        "$r_snapshotid" -c --add 679593333241

    echo "Making $r_amiid in $r public"
    ec2-modify-image-attribute --region "$r" \
        "$r_amiid" --launch-permission -a all

    # compatibility name from before addition of hvm
    if [[ "${virt_type}" == "pv" ]]; then
        upload_file "$r" "$r_amiid"
    fi

    upload_file "${virt_type}_${r}" "$r_amiid"
}

WAIT_PIDS=()
PV_ALL=""
for r in "${!AMIS[@]}"; do
    publish_ami "$r" pv "${AMIS[$r]}" &
    WAIT_PIDS+=( $! )
    PV_ALL+="|${r}=${AMIS[$r]}"
done
PV_ALL="${PV_ALL#|}"

HVM_ALL=""
for r in "${!HVM_AMIS[@]}"; do
    publish_ami "$r" hvm "${HVM_AMIS[$r]}" &
    WAIT_PIDS+=( $! )
    HVM_ALL+="|${r}=${HVM_AMIS[$r]}"
done
HVM_ALL="${HVM_ALL#|}"

# wait for each subshell individually to report errors
WAIT_FAILED=0
for wait_pid in "${WAIT_PIDS[@]}"; do
    if ! wait ${wait_pid}; then
        : $(( WAIT_FAILED++ ))
    fi
done

if [[ ${WAIT_FAILED} -ne 0 ]]; then
    echo "${WAIT_FAILED} jobs failed, aborting :(" >&2
    exit ${WAIT_FAILED}
fi

upload_file "all" "${PV_ALL}"
upload_file "pv" "${PV_ALL}"
upload_file "hvm" "${HVM_ALL}"
echo "Done"
