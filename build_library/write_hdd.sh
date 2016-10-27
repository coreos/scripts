#!/bin/bash

# Generate a parallels compatible disk with XML format. qemu-img does not currently
# support the XML disk format. If changes in the future this script can replaced simply
# by a qemu-img convert.

SCRIPT_ROOT=$(readlink -f $(dirname "$0")/..)
. "${SCRIPT_ROOT}/common.sh" || exit 1
. "${BUILD_LIBRARY_DIR}/build_image_util.sh" || exit 1

DEFINE_string input_disk_image "" "Disk image to convert from, required."
DEFINE_string input_disk_format "raw" "Disk image format."
DEFINE_string output_disk "" "Path to the output disk, required."

# Parse command line
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

# Die on any errors.
switch_to_strict_mode

if [[ ! -e "${FLAGS_input_disk_image}" ]]; then
    echo "No such disk image '${FLAGS_input_disk_image}'" >&2
    exit 1
fi

rm -fr "${FLAGS_output_disk}"
mkdir -p "${FLAGS_output_disk}"
disk_name=$(basename "${FLAGS_output_disk}")

touch "${FLAGS_output_disk}"/"${disk_name}"

# this id is a constant and identifies the first snapshot of a disk
snapshot_uuid="{5fbaabe3-6958-40ff-92a7-860e329aab41}"
snapshot_name="${disk_name}".0.${snapshot_uuid}.hds
snapshot_path="${FLAGS_output_disk}"/"${snapshot_name}"

qemu-img convert -f "${FLAGS_input_disk_format}" "${FLAGS_input_disk_image}" \
   -O parallels "${snapshot_path}"

assert_image_size "${snapshot_path}" parallels

DISK_VIRTUAL_SIZE_BYTES=$(qemu-img info -f parallels --output json \
    "${snapshot_path}" | jq --raw-output '.["virtual-size"]')

if [[ -z "${DISK_VIRTUAL_SIZE_BYTES}" ]]; then
    echo "Unable to determine virtual size of '${snapshot_path}'" >&2
    exit 1
fi

cat >"${FLAGS_output_disk}"/DiskDescriptor.xml <<EOF
<?xml version='1.0' encoding='UTF-8'?>
<Parallels_disk_image Version="1.0">
    <Disk_Parameters>
        <Disk_size>$((DISK_VIRTUAL_SIZE_BYTES / 16 / 32))</Disk_size>
        <Cylinders>$((DISK_VIRTUAL_SIZE_BYTES / 16 / 32 / 512))</Cylinders>
        <PhysicalSectorSize>512</PhysicalSectorSize>
        <Heads>16</Heads>
        <Sectors>32</Sectors>
        <Padding>0</Padding>
        <Encryption>
            <Engine>{00000000-0000-0000-0000-000000000000}</Engine>
            <Data></Data>
        </Encryption>
        <UID>{$(uuidgen)}</UID>
        <Name>coreos</Name>
        <Miscellaneous>
            <CompatLevel>level2</CompatLevel>
            <Bootable>1</Bootable>
            <SuspendState>0</SuspendState>
        </Miscellaneous>
    </Disk_Parameters>
    <StorageData>
        <Storage>
            <Start>0</Start>
            <End>$((DISK_VIRTUAL_SIZE_BYTES / 16 / 32))</End>
            <Blocksize>2048</Blocksize>
            <Image>
                <GUID>${snapshot_uuid}</GUID>
                <Type>Compressed</Type>
                <File>${disk_name}.0.${snapshot_uuid}.hds</File>
            </Image>
        </Storage>
    </StorageData>
    <Snapshots>
        <Shot>
            <GUID>${snapshot_uuid}</GUID>
            <ParentGUID>{00000000-0000-0000-0000-000000000000}</ParentGUID>
        </Shot>
    </Snapshots>
</Parallels_disk_image>
EOF
