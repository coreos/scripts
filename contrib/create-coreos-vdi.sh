#!/bin/bash

VERSION_ID=alpha
SSH_KEYS=""
CORE_UID=500
CORE_GID=500

USAGE="Usage: $0 [-V version] [-d /target/path] [-a authorized_keys]
Options:
    -d DEST     Create CoreOS VDI image to the given path.
    -V VERSION  Version to install (e.g. alpha) [default: ${VERSION_ID}]
    -a FILE     SSH public keys for login access. [~/.ssh/id_{dsa,rsa}.pub]
    -h          This help

This tool creates a CoreOS VDI image to be used with VirtualBox.
"

# Image signing key: buildbot@coreos.com
GPG_LONG_ID="50E0885593D2DCB4"
GPG_KEY="-----BEGIN PGP PUBLIC KEY BLOCK-----
Version: GnuPG v2.0.20 (GNU/Linux)

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
BeiJ6tEeDHDzdA==
=4Qn0
-----END PGP PUBLIC KEY BLOCK-----
"

while getopts "V:d:a:h" OPTION
do
    case $OPTION in
        V) VERSION_ID="$OPTARG" ;;
        d) DEST="$OPTARG" ;;
        a) SSH_KEYS="$OPTARG" ;;
        h) echo "$USAGE"; exit;;
        *) exit 1;;
    esac
done

# root user required
if [ $(id -u) -ne 0 ]; then
    echo "$0: You must be root to run this script." >&2
    exit 1
fi

# VirtualBox tools required
which VBoxManage &>/dev/null
if [ $? -ne 0 ]; then
    echo "$0: VBoxManage tool is required to convert image." >&2
    exit 1
fi

# Verify provided keys file
if [[ -n "${SSH_KEYS}" ]]; then
    if [[ ! -f "${SSH_KEYS}" ]]; then
        echo "$0: SSH keys file not found: ${SSH_KEYS}." >&2
        exit 1
    fi
else
    # SSH keys file was not provided, setting to default
    SSH_KEYS=~/.ssh/id_*.pub
fi



if [[ ! -d "${DEST}" ]]; then
    echo "$0: Target path (${DEST}) do not exists." >&2
    exit 1
fi

WORKDIR="${DEST}/tmp.${RANDOM}"
mkdir "$WORKDIR"
trap "rm -rf '${WORKDIR}'" EXIT

RAW_IMAGE_NAME="coreos_production_image.bin"
VDI_IMAGE_NAME="coreos_production_${VERSION_ID}.vdi"
IMAGE_NAME="${RAW_IMAGE_NAME}.bz2"
DIGESTS_NAME="${IMAGE_NAME}.DIGESTS.asc"

BASE_URL="http://storage.core-os.net/coreos/amd64-usr/${VERSION_ID}"
IMAGE_URL="${BASE_URL}/${IMAGE_NAME}"
DIGESTS_URL="${BASE_URL}/${DIGESTS_NAME}"
DOWN_IMAGE="${WORKDIR}/${RAW_IMAGE_NAME}"
VDI_IMAGE="${DEST}/${VDI_IMAGE_NAME}"

if ! wget --spider --quiet "${IMAGE_URL}"; then
    echo "$0: Image URL unavailable: $IMAGE_URL" >&2
    exit 1
fi

if ! wget --spider --quiet "${DIGESTS_URL}"; then
    echo "$0: Image signature unavailable: $DIGESTS_URL" >&2
    exit 1
fi

# Setup GnuPG for verifying the image signature
export GNUPGHOME="${WORKDIR}/gnupg"
mkdir "${GNUPGHOME}"
gpg --batch --quiet --import <<<"$GPG_KEY"

echo "Downloading and verifying ${IMAGE_NAME}..."
wget --no-verbose -O "${WORKDIR}/${DIGESTS_NAME}" "${DIGESTS_URL}"
if ! gpg --batch --trusted-key "${GPG_LONG_ID}" \
    --verify "${WORKDIR}/${DIGESTS_NAME}"
then
    echo "$0: GPG signature verification failed for ${DIGESTS_NAME}" >&2
    exit 1
fi

wget -O "${WORKDIR}/${IMAGE_NAME}" "${IMAGE_URL}"

# DIGESTS may include README and other extra files we don't need, filter them.
# Also filter one hash at a time, not required but avoids warnings from *sum.
for sum in sha1 sha512; do
    (cd "${WORKDIR}"
    grep -i -A1 "^# ${sum} HASH$" "${WORKDIR}/${DIGESTS_NAME}" \
        | grep "${IMAGE_NAME}$" | ${sum}sum -c /dev/stdin)
done

echo "Writing ${IMAGE_NAME} to ${DOWN_IMAGE}..."
bzcat -v --stdout "${WORKDIR}/${IMAGE_NAME}" >"${DOWN_IMAGE}"

# The ROOT partition should be #9 but make no assumptions here!
# Also don't mount by label directly in case other devices conflict.
PART_OFFSET=$(parted ${DOWN_IMAGE} unit b print | grep "ROOT" | awk '{print $2}')
PART_OFFSET=${PART_OFFSET//B/}
if [[ -z "${PART_OFFSET}" ]]; then
    echo "Unable to find new ROOT partition on ${DOWN_IMAGE}" >&2
    exit 1
fi

MOUNT_DEST="${WORKDIR}/rootfs"
CORE_SSH_DIR="${MOUNT_DEST}/home/core/.ssh"
AUTHORIZED_KEYS="${CORE_SSH_DIR}/authorized_keys"

echo "Adding SSH key to authorized keys file..."
mkdir -p "${MOUNT_DEST}"
mount -t btrfs -o loop,offset=${PART_OFFSET},subvol=root "${DOWN_IMAGE}" "${MOUNT_DEST}"
trap "umount '${MOUNT_DEST}' && rm -rf '${WORKDIR}'" EXIT

if [ ! -d "${CORE_SSH_DIR}" ]; then
    mkdir -p ${CORE_SSH_DIR}
    chmod 0600 ${CORE_SSH_DIR}
fi

cat ${SSH_KEYS} > ${AUTHORIZED_KEYS}
chmod 0600 ${AUTHORIZED_KEYS}
chown -R $CORE_UID:$CORE_GID "${CORE_SSH_DIR}"

umount "${MOUNT_DEST}"

echo "Converting ${RAW_IMAGE_NAME} to VirtualBox format..."
VBoxManage convertdd ${DOWN_IMAGE} ${VDI_IMAGE_NAME} --format VDI

rm -rf "${WORKDIR}"
trap - EXIT

echo "Success! CoreOS ${VERSION_ID} VDI image was created on ${VDI_IMAGE_NAME}"
