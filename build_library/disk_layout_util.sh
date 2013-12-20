# Copyright (c) 2012 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

CGPT_PY="${BUILD_LIBRARY_DIR}/disk_util"

cgpt_py() {
  "${CGPT_PY}" "$@"
}

write_partition_table() {
  local outdev=$1

  local pmbr_img
  case ${ARCH} in
  arm)
    pmbr_img=/dev/zero
    ;;
  amd64|x86)
    pmbr_img=$(readlink -f /usr/share/syslinux/gptmbr.bin)
    ;;
  *)
    error "Unknown architecture: $ARCH"
    return 1
    ;;
  esac

  cgpt_py write_gpt --mbr_boot_code="${pmbr_img}" "${outdev}"
}

get_fs_block_size() {
  cgpt_py readfsblocksize
}

get_block_size() {
  cgpt_py readblocksize
}

get_partition_size() {
  local part_id=$1

  cgpt_py readpartsize ${part_id}
}

get_filesystem_size() {
  local part_id=$1

  cgpt_py readfssize ${part_id}
}

get_label() {
  local part_id=$1

  cgpt_py readlabel ${part_id}
}

get_num() {
  local label=$1

  cgpt_py readnum ${label}
}

get_uuid() {
  local label=$1

  cgpt_py readuuid ${label}
}

check_valid_layout() {
  cgpt_py parseonly > /dev/null
}

get_disk_layout_type() {
  DISK_LAYOUT_TYPE="${1:-base}"
  if [[ -n "${FLAGS_disk_layout}" && \
      "${FLAGS_disk_layout}" != "default" ]]; then
    DISK_LAYOUT_TYPE="${FLAGS_disk_layout}"
  fi
  export DISK_LAYOUT_TYPE
}

emit_gpt_scripts() {
  local image="$1"
  local dir="$2"

  local pack="${dir}/pack_partitions.sh"
  local unpack="${dir}/unpack_partitions.sh"
  local mount="${dir}/mount_image.sh"
  local umount="${dir}/umount_image.sh"

  local start size part x

  cat >"${unpack}" <<EOF
#!/bin/bash -eu
# File automatically generated. Do not edit.
TARGET=\${1:-}
if [[ -z \${TARGET} ]]; then
  echo "Usage: \$0 <image>" 1>&2
  echo "Example: \$0 $COREOS_IMAGE_NAME" 1>&2
  exit 1
fi
set -x
$(${GPT} show "${image}" | sed -e 's/^/# /')
EOF

  for x in "${pack}" "${mount}" "${umount}"; do
    cp "${unpack}" "${x}"
  done

  while read start size part x; do
    local file="part_${part}"
    local dir="dir_${part}"
    local target='"${TARGET}"'
    local dd_args="bs=512 count=${size} conv=sparse"
    local start_b=$(( start * 512 ))
    local size_b=$(( size * 512 ))
    echo "dd if=${target} of=${file} ${dd_args} skip=${start}" >>"${unpack}"
    echo "dd if=${file} of=${target} ${dd_args} seek=${start} conv=notrunc" \
      >>"${pack}"
    if [[ ${size} -gt 1 ]]; then
      cat <<-EOF >>"${mount}"
mkdir -p ${dir}
m=( sudo mount -o loop,offset=${start_b},sizelimit=${size_b} ${target} ${dir} )
if ! "\${m[@]}"; then
  if ! "\${m[@]}" -o ro; then
    rmdir ${dir}
  fi
fi
EOF
      cat <<-EOF >>"${umount}"
if [[ -d ${dir} ]]; then
  sudo umount ${dir} || :
  rmdir ${dir}
fi
EOF
    fi
  done < <(${GPT} show -q "${image}")

  chmod +x "${unpack}" "${pack}" "${mount}" "${umount}"
}

build_gpt() {
  local outdev="$1"
  local rootfs_img="$2"
  local stateful_img="$3"
  local esp_img="$4"
  local oem_img="$5"

  get_disk_layout_type
  write_partition_table "${outdev}"

  local sudo=
  if [ ! -w "$outdev" ] ; then
    # use sudo when writing to a block device.
    sudo=sudo
  fi

  local root_fs_label="ROOT-A"
  local root_fs_num=$(get_num ${image_type} ${root_fs_label})

  local stateful_fs_label="STATE"
  local stateful_fs_num=$(get_num ${image_type} ${stateful_fs_label})

  local esp_fs_label="EFI-SYSTEM"
  local esp_fs_num=$(get_num ${image_type} ${esp_fs_label})

  local oem_fs_label="OEM"
  local oem_fs_num=$(get_num ${image_type} ${oem_fs_label})

  # Now populate the partitions.
  info "Copying stateful partition..."
  $sudo dd if="$stateful_img" of="$outdev" conv=notrunc,sparse bs=512 \
      seek=$(partoffset ${outdev} ${stateful_fs_num}) status=none

  info "Copying rootfs..."
  $sudo dd if="$rootfs_img" of="$outdev" conv=notrunc,sparse bs=512 \
      seek=$(partoffset ${outdev} ${root_fs_num}) status=none

  info "Copying EFI system partition..."
  $sudo dd if="$esp_img" of="$outdev" conv=notrunc,sparse bs=512 \
      seek=$(partoffset ${outdev} ${esp_fs_num}) status=none

  info "Copying OEM partition..."
  $sudo dd if="$oem_img" of="$outdev" conv=notrunc,sparse bs=512 \
      seek=$(partoffset ${outdev} ${oem_fs_num}) status=none

  # Pre-set "sucessful" bit in gpt, so we will never mark-for-death
  # a partition on an SDCard/USB stick.
  cgpt add -i 2 -S 1 "$outdev"
}

# Rebuild an image's partition table with new stateful size.
#  $1: source image filename
#  $2: source stateful partition image filename
#  $3: number of sectors to allocate to the new stateful partition
#  $4: destination image filename
# Used by dev/host/tests/mod_recovery_for_decryption.sh and
# mod_image_for_recovery.sh.
update_partition_table() {
  local src_img=$1              # source image
  local src_state=$2            # stateful partition image
  local dst_stateful_blocks=$3  # number of blocks in resized stateful partition
  local dst_img=$4

  rm -f "${dst_img}"

  # Calculate change in image size.
  local src_stateful_blocks=$(cgpt show -i 1 -s ${src_img})
  local delta_blocks=$(( dst_stateful_blocks - src_stateful_blocks ))
  local dst_stateful_bytes=$(( dst_stateful_blocks * 512 ))
  local src_stateful_bytes=$(( src_stateful_blocks * 512 ))
  local src_size=$(stat -c %s ${src_img})
  local dst_size=$(( src_size - src_stateful_bytes + dst_stateful_bytes ))
  truncate -s ${dst_size} ${dst_img}

  # Copy MBR, initialize GPT.
  dd if="${src_img}" of="${dst_img}" conv=notrunc bs=512 count=1 status=none
  cgpt create ${dst_img}

  # Find partition number of STATE (really should always be "1")
  local part=0
  local label=""
  while [ "${label}" != "STATE" ]; do
    part=$(( part + 1 ))
    local label=$(cgpt show -i ${part} -l ${src_img})
    local src_start=$(cgpt show -i ${part} -b ${src_img})
    if [ ${src_start} -eq 0 ]; then
      echo "Could not find 'STATE' partition" >&2
      return 1
    fi
  done
  local src_state_start=$(cgpt show -i ${part} -b ${src_img})

  # Duplicate each partition entry.
  part=0
  while :; do
    part=$(( part + 1 ))
    local src_start=$(cgpt show -i ${part} -b ${src_img})
    if [ ${src_start} -eq 0 ]; then
      # No more partitions to copy.
      break
    fi
    local dst_start=${src_start}
    # Load source partition details.
    local size=$(cgpt show -i ${part} -s ${src_img})
    local label=$(cgpt show -i ${part} -l ${src_img})
    local attr=$(cgpt show -i ${part} -A ${src_img})
    local tguid=$(cgpt show -i ${part} -t ${src_img})
    local uguid=$(cgpt show -i ${part} -u ${src_img})
    # Change size of stateful.
    if [ "${label}" = "STATE" ]; then
      size=${dst_stateful_blocks}
    fi
    # Partitions located after STATE need to have their start moved.
    if [ ${src_start} -gt ${src_state_start} ]; then
      dst_start=$(( dst_start + delta_blocks ))
    fi
    # Add this partition to the destination.
    cgpt add -i ${part} -b ${dst_start} -s ${size} -l "${label}" -A ${attr} \
             -t ${tguid} -u ${uguid} ${dst_img}
    if [ "${label}" != "STATE" ]; then
      # Copy source partition as-is.
      dd if="${src_img}" of="${dst_img}" conv=notrunc,sparse bs=512 \
        skip=${src_start} seek=${dst_start} count=${size} status=none
    else
      # Copy new stateful partition into place.
      dd if="${src_state}" of="${dst_img}" conv=notrunc,sparse bs=512 \
        seek=${dst_start} status=none
    fi
  done
  return 0
}
