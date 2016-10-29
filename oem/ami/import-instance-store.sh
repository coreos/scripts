#!/bin/bash
#
# This expects to run on an EC2 instance.

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
    -B BUCKET   S3 bucket (or bucket/prefix) to use for storage of the AMI.
    -Z ZONE     EC2 availability zone to use.
    -l ACCOUNT  Grant launch permission to a given AWS account ID.
    -c CERT     PEM-encoded X.509 certificate for EC2 API
    -k KEY      PEM-encoded RSA key for EC2 API
    -a ACCOUNT  Account number (without dashes) corresponding to EC2 credentials
    -X          Disable GPG verification of downloads.
    -h          this ;-)
    -v          Verbose, see all the things!

This script must be run from a host with the ec2-api-tools and ec2-ami-tools installed.
"

while getopts "V:b:g:p:u:s:t:l:c:k:a:B:Z:Xhv" OPTION
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
        c) EC2_CERT_PATH="${OPTARG}";;
        k) EC2_KEY_PATH="${OPTARG}";;
        a) EC2_ACCOUNT="${OPTARG}";;
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

if [[ -z "${AWS_ACCESS_KEY}" ]]; then
    echo "$0: \$AWS_ACCESS_KEY must be set!" >&2
    exit 1
fi
if [[ -z "${AWS_SECRET_KEY}" ]]; then
    echo "$0: \$AWS_SECRET_KEY must be set!" >&2
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
ec2manifestcert=${EC2_MANIFEST_CERT_PATH[$region]}

if [ -z "$akiid" ]; then
   echo "$0: Can't identify AKI, using region: $region" >&2
   exit 1
fi

if [ -z "$ec2manifestcert" ]; then
   echo "$0: Can't identify EC2 manifest encryption certificate, using region: $region" >&2
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

# TODO: Can we convert VMDK/VHDs to raw?
if [[ "$imgfmt" != "raw" ]]; then
    echo "$0: image must be in raw format"
    exit 1
fi

# Bundle the image, converting it from a raw image to a bunch of files and generating a manifest
bundledir="${tmpdir}/bundle"
mkdir "${bundledir}"
ec2-bundle-image --cert "${EC2_CERT_PATH}" --privatekey "${EC2_KEY_PATH}" --user "${EC2_ACCOUNT}" \
  --image "${tmpimg}" \
  --destination "${bundledir}" \
  --ec2cert "$ec2manifestcert" \
  --arch "$arch" \
  --block-device-mapping ami=sda,root=/dev/sda,ephemeral0=sdb \
  --prefix "${name}"

# Upload the bundle
ec2-upload-bundle \
  --bucket "${EC2_IMPORT_BUCKET}/${name}/" \
  --access-key "${AWS_ACCESS_KEY}" \
  --secret-key "${AWS_SECRET_KEY}" \
  --directory "${bundledir}" \
  --manifest "${bundledir}/${name}.manifest.xml" \
  --retry  

# Having uploaded the bundle, we can now register some AMIs
echo "Registering hvm AMI"
hvm_amiid=$(ec2-register                              \
  "${EC2_IMPORT_BUCKET}/${name}/${name}.manifest.xml" \
  --name "${name}-is-hvm"                             \
  --description "$description (instance-store HVM)"   \
  --architecture "$arch"                              \
  --virtualization-type hvm                           \
  --root-device-name /dev/sda                         \
  --sriov simple                                      |
  cut -f2)

echo "Registering paravirtual AMI"
pv_amiid=$(ec2-register                               \
  "${EC2_IMPORT_BUCKET}/${name}/${name}.manifest.xml" \
  --name "${name}-is-pv"                              \
  --description "$description (instance-store PV)"    \
  --architecture "$arch"                              \
  --virtualization-type paravirtual                   \
  --kernel "$akiid"                                   \
  --root-device-name /dev/sda                         \
  --sriov simple                                      |
  cut -f2)

if [[ -n "${GRANT_LAUNCH}" ]]; then
  echo "Granting launch permission to ${GRANT_LAUNCH}"
  ec2-modify-image-attribute "${hvm_amiid}" \
      --launch-permission --add "${GRANT_LAUNCH}"
  ec2-modify-image-attribute "${pv_amiid}" \
      --launch-permission --add "${GRANT_LAUNCH}"
fi

cat <<EOF
$description
architecture: $arch
region:       $region (${EC2_IMPORT_ZONE})
aki id:       $akiid
name:         $name
description:  $description
PV AMI id:    $pv_amiid
HVM AMI id:   $hvm_amiid
EOF