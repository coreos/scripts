#!/bin/bash
#
# This expects to run on an EC2 instance.
#
# mad props to Eric Hammond for the initial script
#  https://github.com/alestic/alestic-hardy-ebs/blob/master/bin/alestic-hardy-ebs-build-ami

# Set pipefail along with -e in hopes that we catch more errors
set -e -o pipefail

DIR=$(dirname $0)
source $DIR/regions.sh

readonly COREOS_EPOCH=1372636800
VERSION="master"
BOARD="amd64-usr"
GROUP="alpha"
IMAGE="coreos_production_ami_image.bin.bz2"
GS_URL="gs://builds.release.core-os.net"
IMG_URL=""
IMG_PATH=""
GRANT_LAUNCH=""
USE_GPG=1
# accepted via the environment
: ${EC2_IMPORT_BUCKET:=}
: ${EC2_IMPORT_ZONE:=}

USAGE="Usage: $0 [-V 1.2.3] [-p path/image.bz2 | -u http://foo/image.bz2]
Options:
    -V VERSION  Set the version of this AMI, default is 'master'
    -b BOARD    Set to the board name, default is amd64-usr
    -g GROUP    Set the update group, default is alpha or master
    -p PATH     Path to compressed disk image, overrides -u
    -u URL      URL to compressed disk image, derived from -V if unset.
    -s STORAGE  GS URL for Google storage (used to generate URL)
    -B BUCKET   S3 bucket to use for temporary storage.
    -Z ZONE     EC2 availability zone to use.
    -l ACCOUNT  Grant launch permission to a given AWS account ID.
    -X          Disable GPG verification of downloads.
    -h          this ;-)
    -v          Verbose, see all the things!

This script must be run from an ec2 host with the ec2 tools installed.
"

while getopts "V:b:g:p:u:s:t:l:B:Z:Xhv" OPTION
do
    case $OPTION in
        V) VERSION="$OPTARG";;
        b) BOARD="$OPTARG";;
        g) GROUP="$OPTARG";;
        p) IMG_PATH="$OPTARG";;
        u) IMG_URL="$OPTARG";;
        s) GS_URL="$OPTARG";;
        B) EC2_IMPORT_BUCKET="${OPTARG}";;
        Z) EC2_IMPORT_ZONE="${OPTARG}";;
        l) GRANT_LAUNCH="${OPTARG}";;
        t) export TMPDIR="$OPTARG";;
        X) USE_GPG=0;;
        h) echo "$USAGE"; exit;;
        v) set -x;;
        *) exit 1;;
    esac
done

if [[ $(id -u) -eq 0 ]]; then
    echo "$0: This command should not be ran run as root!" >&2
    exit 1
fi

if [[ -z "${EC2_IMPORT_BUCKET}" ]]; then
    echo "$0: -B or \$EC2_IMPORT_BUCKET must be set!" >&2
    exit 1
fi

# Quick sanity check that the image exists
if [[ -n "$IMG_PATH" ]]; then
    if [[ ! -f "$IMG_PATH" ]]; then
        echo "$0: Image path does not exist: $IMG_PATH" >&2
        exit 1
    fi
    IMG_URL=$(basename "$IMG_PATH")
else
    if [[ -z "$IMG_URL" ]]; then
        IMG_URL="$GS_URL/$GROUP/boards/$BOARD/$VERSION/$IMAGE"
    fi
    if [[ "$IMG_URL" == gs://* ]]; then
        if ! gsutil -q stat "$IMG_URL"; then
            echo "$0: Image URL unavailable: $IMG_URL" >&2
            exit 1
        fi
    else
        if ! curl --fail -s --head "$IMG_URL" >/dev/null; then
            echo "$0: Image URL unavailable: $IMG_URL" >&2
            exit 1
        fi
    fi
fi

if [[ "$VERSION" == "master" ]]; then
    # Come up with something more descriptive and timestamped
    TODAYS_VERSION=$(( (`date +%s` - ${COREOS_EPOCH}) / 86400 ))
    VERSION="${TODAYS_VERSION}-$(date +%H-%M)"
    GROUP="master"
fi

# Size of AMI file system
# TODO: Perhaps define size and arch in a metadata file image_to_vm creates?
size=8 # GB
arch=x86_64
# The name has a limited set of allowed characterrs
name=$(sed -e "s%[^A-Za-z0-9()\\./_-]%_%g" <<< "CoreOS-$GROUP-$VERSION")
description="CoreOS $GROUP $VERSION"

if [[ -z "${EC2_IMPORT_ZONE}" ]]; then
    zoneurl=http://instance-data/latest/meta-data/placement/availability-zone
    EC2_IMPORT_ZONE=$(curl --fail -s $zoneurl)
fi
region=$(echo "${EC2_IMPORT_ZONE}" | sed 's/.$//')
akiid=${ALL_AKIS[$region]}

if [ -z "$akiid" ]; then
   echo "$0: Can't identify AKI, using region: $region" >&2
   exit 1
fi

export EC2_URL="https://ec2.${region}.amazonaws.com"
echo "Building AMI in zone ${EC2_IMPORT_ZONE}"

tmpdir=$(mktemp --directory --tmpdir=/var/tmp)
trap "rm -rf '${tmpdir}'" EXIT

# if it is on the local fs, just use it, otherwise try to download it
if [[ -z "$IMG_PATH" ]]; then
    IMG_PATH="${tmpdir}/${IMG_URL##*/}"
    if [[ "$IMG_URL" == gs://* ]]; then
        gsutil cp "$IMG_URL" "$IMG_PATH"
        if [[ "$USE_GPG" != 0 ]]; then
            gsutil cp "${IMG_URL}.sig" "${IMG_PATH}.sig"
        fi
    else
        curl --fail "$IMG_URL" > "$IMG_PATH"
        if [[ "$USE_GPG" != 0 ]]; then
            curl --fail "${IMG_URL}.sig" > "${IMG_PATH}.sig"
        fi
    fi
fi

if [[ "$USE_GPG" != 0 ]]; then
    gpg --verify "${IMG_PATH}.sig"
fi

echo "Bunzipping...."
tmpimg="${tmpdir}/img"
bunzip2 -c "$IMG_PATH" >"${tmpimg}"

imgfmt=ponies
case "$IMG_PATH" in
    *_image.bin*)  imgfmt=raw;;
    *_image.vmdk*) imgfmt=vmdk;;
    *_image.vhd*)  imgfmt=vhd;;
    *)
        echo "$0: Cannot guess image format from image path!"
        exit 1
        ;;
esac

importid=$(ec2-import-volume "${tmpimg}" \
  -f $imgfmt -s $size -x 2 \
  -z "${EC2_IMPORT_ZONE}" \
  -b "${EC2_IMPORT_BUCKET}" \
  -o "${AWS_ACCESS_KEY}" \
  -w "${AWS_SECRET_KEY}" \
  --no-upload | awk '/IMPORTVOLUME/{print $4}')
ec2-resume-import "${tmpimg}" \
  -t "${importid}" -x 2 \
  -o "${AWS_ACCESS_KEY}" \
  -w "${AWS_SECRET_KEY}"

echo "Waiting on import task ${importid}"
importstat=$(ec2-describe-conversion-tasks "${importid}" | grep IMPORTVOLUME)
while $(grep -qv completed <<<"${importstat}"); do
  sed -e 's/.*StatusMessage/Status:/' <<<"${importstat}"
  sleep 30
  importstat=$(ec2-describe-conversion-tasks "${importid}" | grep IMPORTVOLUME)
done

volumeid=$(ec2-describe-conversion-tasks "${importid}" | \
  grep DISKIMAGE | sed -e 's%.*\(vol-[a-z0-9]*\).*%\1%')

while ! ec2-describe-volumes "$volumeid" | grep -q available
  do sleep 1; done

echo "Volume ${volumeid} ready, deleting upload from S3..."
ec2-delete-disk-image \
  -t "${importid}" \
  -o "${AWS_ACCESS_KEY}" \
  -w "${AWS_SECRET_KEY}"

echo "Creating snapshot..."
snapshotid=$(ec2-create-snapshot --description "$name" "$volumeid" | cut -f2)
echo "Waiting on snapshot ${snapshotid}"
while ec2-describe-snapshots "$snapshotid" | grep -q pending
  do sleep 30; done

echo "Created snapshot $snapshotid, deleting $volumeid"
ec2-delete-volume "$volumeid"

echo "Registering hvm AMI"
hvm_amiid=$(ec2-register                              \
  --name "${name}-hvm"                                \
  --description "$description (HVM)"                  \
  --architecture "$arch"                              \
  --virtualization-type hvm                           \
  --root-device-name /dev/xvda                        \
  --block-device-mapping /dev/xvda=$snapshotid::true  \
  --sriov simple                                      \
  --block-device-mapping /dev/xvdb=ephemeral0         |
  cut -f2)

echo "Registering paravirtual AMI"
amiid=$(ec2-register                                  \
  --name "$name"                                      \
  --description "$description (PV)"                   \
  --architecture "$arch"                              \
  --virtualization-type paravirtual                   \
  --kernel "$akiid"                                   \
  --root-device-name /dev/sda                         \
  --block-device-mapping /dev/sda=$snapshotid::true   \
  --block-device-mapping /dev/sdb=ephemeral0          |
  cut -f2)

if [[ -n "${GRANT_LAUNCH}" ]]; then
  echo "Granting launch permission to ${GRANT_LAUNCH}"
  ec2-modify-image-attribute "${hvm_amiid}" \
      --launch-permission --add "${GRANT_LAUNCH}"
  ec2-modify-image-attribute "${amiid}" \
      --launch-permission --add "${GRANT_LAUNCH}"
fi

cat <<EOF
$description
architecture: $arch
region:       $region (${EC2_IMPORT_ZONE})
aki id:       $akiid
name:         $name
description:  $description
EBS volume:   $volumeid (deleted)
EBS snapshot: $snapshotid
PV AMI id:    $amiid
HVM AMI id:   $hvm_amiid
EOF
