# Copyright (c) 2011 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

emit_gpt_scripts() {
  local image="$1"
  local dir="$2"

  local pack="$dir/pack_partitions.sh"
  local unpack="$dir/unpack_partitions.sh"

  cat >"$unpack" <<HEADER
#!/bin/bash -eu
# File automatically generated. Do not edit.
TARGET=\${1:-}
if [[ -z "\$TARGET" ]]; then
  echo "Usage: \$0 DEVICE" 1>&2
  exit 1
fi
set -x
HEADER

  $GPT show "$image" | sed -e 's/^/# /' >>"$unpack"
  cp "$unpack" "$pack"

  $GPT show -q "$image" |
    while read start size part x; do
      local file="part_$part"
      local target="\"\$TARGET\""
      local dd_args="bs=512 count=$size"
      echo "dd if=$target of=$file $dd_args skip=$start" >>"$unpack"
      echo "dd if=$file of=$target $dd_args seek=$start conv=notrunc" \
        >>"$pack"
    done

  chmod +x "$unpack" "$pack"
}


build_gpt() {
  local outdev="$1"
  local rootfs_img="$2"
  local stateful_img="$3"
  local esp_img="$4"

  # We'll need some code to put in the PMBR, for booting on legacy BIOS.
  local pmbr_img
  if [ "$ARCH" = "arm" ]; then
    pmbr_img=/dev/zero
  elif [ "$ARCH" = "x86" ]; then
    pmbr_img=$(readlink -f /usr/share/syslinux/gptmbr.bin)
  else
    error "Unknown architecture: $ARCH"
    return 1
  fi

  # Create the GPT. This has the side-effect of setting some global vars
  # describing the partition table entries (see the comments in the source).
  install_gpt "$outdev" $(numsectors "$rootfs_img") \
    $(numsectors "$stateful_img") $pmbr_img $(numsectors "$esp_img") \
    false $FLAGS_rootfs_partition_size

  local sudo=
  if [ ! -w "$outdev" ] ; then
    # use sudo when writing to a block device.
    sudo=sudo
  fi

  # Now populate the partitions.
  echo "Copying stateful partition..."
  $sudo dd if="$stateful_img" of="$outdev" conv=notrunc bs=512 \
      seek=$START_STATEFUL

  echo "Copying rootfs..."
  $sudo dd if="$rootfs_img" of="$outdev" conv=notrunc bs=512 \
      seek=$START_ROOTFS_A

  echo "Copying EFI system partition..."
  $sudo dd if="$esp_img" of="$outdev" conv=notrunc bs=512 \
      seek=$START_ESP

  # Pre-set "sucessful" bit in gpt, so we will never mark-for-death
  # a partition on an SDCard/USB stick.
  $GPT add -i 2 -S 1 "$outdev"
}
