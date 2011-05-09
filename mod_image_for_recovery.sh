#!/bin/bash

# Copyright (c) 2010 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# This script modifies a base image to act as a recovery installer.
# If no kernel image is supplied, it will build a devkeys signed recovery
# kernel.  Alternatively, a signed recovery kernel can be used to
# create a Chromium OS recovery image.

# --- BEGIN COMMON.SH BOILERPLATE ---
# Load common CrOS utilities.  Inside the chroot this file is installed in
# /usr/lib/crosutils.  Outside the chroot we find it relative to the script's
# location.
find_common_sh() {
  local common_paths=(/usr/lib/crosutils $(dirname "$(readlink -f "$0")"))
  local path

  SCRIPT_ROOT=
  for path in "${common_paths[@]}"; do
    if [ -r "${path}/common.sh" ]; then
      SCRIPT_ROOT=${path}
      break
    fi
  done
}

find_common_sh
. "${SCRIPT_ROOT}/common.sh" || (echo "Unable to load common.sh" && exit 1)
# --- END COMMON.SH BOILERPLATE ---

# Need to be inside the chroot to load chromeos-common.sh
assert_inside_chroot

# Load functions and constants for chromeos-install
. "/usr/lib/installer/chromeos-common.sh" || \
  die "Unable to load /usr/lib/installer/chromeos-common.sh"

# For update_partition_table
. "${SCRIPT_ROOT}/resize_stateful_partition.sh" || \
  die "Unable to load ${SCRIPT_ROOT}/resize_stateful_partition.sh"

get_default_board

DEFINE_string board "$DEFAULT_BOARD" "Board for which the image was built" b
DEFINE_integer statefulfs_sectors 4096 \
  "Number of sectors to use for the stateful filesystem when minimizing"
# Skips the build steps and just does the kernel swap.
DEFINE_string kernel_image "" \
    "Path to a pre-built recovery kernel"
DEFINE_string kernel_outfile "" \
    "Filename and path to emit the kernel outfile to. \
If empty, emits to IMAGE_DIR."
DEFINE_string image "" "Path to the image to use"
DEFINE_string to "" \
    "Path to the image to create. If empty, defaults to \
IMAGE_DIR/recovery_image.bin."
DEFINE_boolean kernel_image_only $FLAGS_FALSE \
    "Emit the recovery kernel image only"
DEFINE_boolean sync_keys $FLAGS_TRUE \
    "Update the kernel to be installed with the vblock from stateful"
DEFINE_boolean minimize_image $FLAGS_TRUE \
    "Decides if the original image is used or a minimal recovery image is \
created."
DEFINE_boolean modify_in_place $FLAGS_FALSE \
    "Modifies the source image in place. This cannot be used with \
--minimize_image."
DEFINE_integer jobs -1 \
    "How many packages to build in parallel at maximum." j
DEFINE_string build_root "/build" \
    "The root location for board sysroots."

DEFINE_string rootfs_hash "/tmp/rootfs.hash" \
  "Path where the rootfs hash should be stored."

DEFINE_boolean verbose $FLAGS_FALSE \
    "Log all commands to stdout." v

# Keep in sync with build_image.
DEFINE_string keys_dir "/usr/share/vboot/devkeys" \
  "Directory containing the signing keys."

# TODO(clchiou): Remove this flag after arm verified boot is stable
DEFINE_boolean crosbug12352_arm_kernel_signing ${FLAGS_TRUE} \
  "Sign kernel partition for ARM images (temporary hack)."

# Parse command line
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

if [ $FLAGS_verbose -eq $FLAGS_FALSE ]; then
  exec 2>/dev/null
  # Redirecting to stdout instead of stderr since
  # we silence  stderr above.
  die() {
    echo -e "${V_BOLD_RED}ERROR  : $1${V_VIDOFF}"
    exit 1
  }
fi
set -x  # Make debugging with -v easy.

EMERGE_CMD="emerge"
EMERGE_BOARD_CMD="emerge-${FLAGS_board}"

# No board, no default and no image set then we can't find the image
if [ -z $FLAGS_image ] && [ -z $FLAGS_board ] ; then
  setup_board_warning
  die "mod_image_for_recovery failed.  No board set and no image set"
fi

# We have a board name but no image set.  Use image at default location
if [ -z $FLAGS_image ] ; then
  IMAGES_DIR="${DEFAULT_BUILD_ROOT}/images/${FLAGS_board}"
  FILENAME="chromiumos_image.bin"
  FLAGS_image="${IMAGES_DIR}/$(ls -t $IMAGES_DIR 2>&-| head -1)/${FILENAME}"
fi

# Turn path into an absolute path.
FLAGS_image=`eval readlink -f ${FLAGS_image}`

# Abort early if we can't find the image
if [ ! -f $FLAGS_image ] ; then
  echo "No image found at $FLAGS_image"
  exit 1
fi

# What cross-build are we targeting?
. "${FLAGS_build_root}/${FLAGS_board}/etc/make.conf.board_setup"
# Figure out ARCH from the given toolchain.
# TODO: Move to common.sh as a function after scripts are switched over.
TC_ARCH=$(echo "${CHOST}" | awk -F'-' '{ print $1 }')
case "${TC_ARCH}" in
  arm*)
    ARCH="arm"
    error "ARM recovery mode is still in the works. Use a normal image for now."
    ;;
  *86)
    ARCH="x86"
    ;;
  *)
    error "Unable to determine ARCH from toolchain: ${CHOST}"
    exit 1
esac

if [[ ${FLAGS_crosbug12352_arm_kernel_signing} -eq ${FLAGS_TRUE} ]]; then
  crosbug12352_flag="--crosbug12352_arm_kernel_signing"
else
  crosbug12352_flag="--nocrosbug12352_arm_kernel_signing"
fi

get_install_vblock() {
  # If it exists, we need to copy the vblock over to stateful
  # This is the real vblock and not the recovery vblock.
  local stateful_offset=$(partoffset "$FLAGS_image" 1)
  local stateful_mnt=$(mktemp -d)
  local out=$(mktemp)

  set +e
  sudo mount -o ro,loop,offset=$((stateful_offset * 512)) \
             "$FLAGS_image" $stateful_mnt
  sudo cp "$stateful_mnt/vmlinuz_hd.vblock"  "$out"
  sudo chown $USER "$out"

  sudo umount -d "$stateful_mnt"
  rmdir "$stateful_mnt"
  set -e
  echo "$out"
}

emerge_recovery_kernel() {
  echo "Emerging custom recovery initramfs and kernel"
  local emerge_flags="-uDNv1 --usepkg=n --selective=n"

  $EMERGE_BOARD_CMD \
    $emerge_flags --binpkg-respect-use=y \
    chromeos-initramfs || die "no initramfs"
  USE="fbconsole initramfs" $EMERGE_BOARD_CMD \
                    $emerge_flags --binpkg-respect-use=y \
                    virtual/kernel
}

create_recovery_kernel_image() {
  local sysroot="${FLAGS_build_root}/${FLAGS_board}"
  local vmlinuz="$sysroot/boot/vmlinuz"
  local root_dev=$(sudo losetup -f)
  local root_offset=$(partoffset "$FLAGS_image" 3)
  local root_size=$(partsize "$FLAGS_image" 3)

  sudo losetup \
       -o $((root_offset * 512)) \
       --sizelimit $((root_size * 512)) \
       "$root_dev" \
       "$FLAGS_image"

  trap "sudo losetup -d $root_dev" EXIT

  cros_root=/dev/sd%D%P  # only used for non-verified images
  if [[ "${ARCH}" = "arm" ]]; then
    cros_root='/dev/${devname}${rootpart}'
  fi
  if grep -q enable_rootfs_verification "${IMAGE_DIR}/boot.desc"; then
    cros_root=/dev/dm-0
  fi
  # TODO(wad) LOAD FROM IMAGE KERNEL AND NOT BOOT.DESC
  local verity_args=$(grep -- '--verity_' "${IMAGE_DIR}/boot.desc")
  # Convert the args to the right names and clean up extra quoting.
  # TODO(wad) just update these everywhere
  verity_args=$(echo $verity_args | sed \
    -e 's/verity_algorithm/verity_hash_alg/g' \
    -e 's/"//g')

  # Tie the installed recovery kernel to the final kernel.  If we don't
  # do this, a normal recovery image could be used to drop an unsigned
  # kernel on without a key-change check.
  # Doing this here means that the kernel and initramfs creation can
  # be done independently from the image to be modified as long as the
  # chromeos-recovery interfaces are the same.  It allows for the signer
  # to just compute the new hash and update the kernel command line during
  # recovery image generation.  (Alternately, it means an image can be created,
  # modified for recovery, then passed to a signer which can then sign both
  # partitions appropriately without needing any external dependencies.)
  local kern_offset=$(partoffset "$FLAGS_image" 2)
  local kern_size=$(partsize "$FLAGS_image" 2)
  local kern_tmp=$(mktemp)
  local kern_hash=

  dd if="$FLAGS_image" bs=512 count=$kern_size \
     skip=$kern_offset of="$kern_tmp" 1>&2
  # We're going to use the real signing block.
  if [ $FLAGS_sync_keys -eq $FLAGS_TRUE ]; then
    dd if="$INSTALL_VBLOCK" of="$kern_tmp" conv=notrunc 1>&2
  fi
  local kern_hash=$(sha1sum "$kern_tmp" | cut -f1 -d' ')
  rm "$kern_tmp"

  # TODO(wad) add FLAGS_boot_args support too.
  ${SCRIPTS_DIR}/build_kernel_image.sh \
    --arch="${ARCH}" \
    --to="$RECOVERY_KERNEL_IMAGE" \
    --hd_vblock="$RECOVERY_KERNEL_VBLOCK" \
    --vmlinuz="$vmlinuz" \
    --working_dir="${IMAGE_DIR}" \
    --boot_args="panic=60 cros_recovery kern_b_hash=$kern_hash" \
    --keep_work \
    --rootfs_image=${root_dev} \
    --rootfs_hash=${FLAGS_rootfs_hash} \
    --root=${cros_root} \
    --keys_dir="${FLAGS_keys_dir}" \
    --nouse_dev_keys \
    ${crosbug12352_flag} \
    ${verity_args} 1>&2
  sudo rm "$FLAGS_rootfs_hash"
  sudo losetup -d "$root_dev"
  trap - RETURN

  # Update the EFI System Partition configuration so that the kern_hash check
  # passes.
  local efi_dev=$(sudo losetup -f)
  local efi_offset=$(partoffset "$FLAGS_image" 12)
  local efi_size=$(partsize "$FLAGS_image" 12)

  sudo losetup \
       -o $((efi_offset * 512)) \
       --sizelimit $((efi_size * 512)) \
       "$efi_dev" \
       "$FLAGS_image"
  local efi_dir=$(mktemp -d)
  trap "sudo losetup -d $efi_dev && rmdir \"$efi_dir\"" EXIT
  sudo mount "$efi_dev" "$efi_dir"
  sudo sed  -i -e "s/cros_legacy/cros_legacy kern_b_hash=$kern_hash/g" \
    "$efi_dir/syslinux/usb.A.cfg" || true
  # This will leave the hash in the kernel for all boots, but that should be
  # safe.
  sudo sed  -i -e "s/cros_efi/cros_efi kern_b_hash=$kern_hash/g" \
    "$efi_dir/efi/boot/grub.cfg" || true
  sudo umount "$efi_dir"
  sudo losetup -d "$efi_dev"
  rmdir "$efi_dir"
  trap - EXIT
}

install_recovery_kernel() {
  local kern_a_offset=$(partoffset "$RECOVERY_IMAGE" 2)
  local kern_a_size=$(partsize "$RECOVERY_IMAGE" 2)
  local kern_b_offset=$(partoffset "$RECOVERY_IMAGE" 4)
  local kern_b_size=$(partsize "$RECOVERY_IMAGE" 4)

  if [ $kern_b_size -eq 1 ]; then
    echo "Image was created with no KERN-B partition reserved!" 1>&2
    echo "Cannot proceed." 1>&2
    return 1
  fi

  # Backup original kernel to KERN-B
  dd if="$RECOVERY_IMAGE" of="$RECOVERY_IMAGE" bs=512 \
     count=$kern_a_size \
     skip=$kern_a_offset \
     seek=$kern_b_offset \
     conv=notrunc

  # We're going to use the real signing block.
  if [ $FLAGS_sync_keys -eq $FLAGS_TRUE ]; then
    dd if="$INSTALL_VBLOCK" of="$RECOVERY_IMAGE" bs=512 \
       seek=$kern_b_offset \
       conv=notrunc
  fi

  # Install the recovery kernel as primary.
  dd if="$RECOVERY_KERNEL_IMAGE" of="$RECOVERY_IMAGE" bs=512 \
     seek=$kern_a_offset \
     count=$kern_a_size \
     conv=notrunc

  # Set the 'Success' flag to 1 (to prevent the firmware from updating
  # the 'Tries' flag).
  sudo $GPT add -i 2 -S 1 "$RECOVERY_IMAGE"

  # Repeat for the legacy bioses.
  # Replace vmlinuz.A with the recovery version
  local sysroot="${FLAGS_build_root}/${FLAGS_board}"
  local vmlinuz="$sysroot/boot/vmlinuz"
  local failed=0

  if [ "$ARCH" = "x86" ]; then
    # There is no syslinux on ARM, so this copy only makes sense for x86.
    set +e
    local esp_offset=$(partoffset "$RECOVERY_IMAGE" 12)
    local esp_mnt=$(mktemp -d)
    sudo mount -o loop,offset=$((esp_offset * 512)) "$RECOVERY_IMAGE" "$esp_mnt"
    sudo cp "$vmlinuz" "$esp_mnt/syslinux/vmlinuz.A" || failed=1
    sudo umount -d "$esp_mnt"
    rmdir "$esp_mnt"
    set -e
  fi

  if [ $failed -eq 1 ]; then
    echo "Failed to copy recovery kernel to ESP"
    return 1
  fi
  return 0
}

maybe_resize_stateful() {
  # If we're not minimizing, then just copy and go.
  if [ $FLAGS_minimize_image -eq $FLAGS_FALSE ]; then
    if [ "$FLAGS_image" != "$RECOVERY_IMAGE" ]; then
      cp "$FLAGS_image" "$RECOVERY_IMAGE"
    fi
    return 0
  fi

  # Rebuild the image with a 1 sector stateful partition
  local err=0
  local small_stateful=$(mktemp)
  dd if=/dev/zero of="$small_stateful" bs=512 \
    count=${FLAGS_statefulfs_sectors} 1>&2
  trap "rm $small_stateful" RETURN
  # Don't bother with ext3 for such a small image.
  /sbin/mkfs.ext2 -F -b 4096 "$small_stateful" 1>&2

  # If it exists, we need to copy the vblock over to stateful
  # This is the real vblock and not the recovery vblock.
  local new_stateful_mnt=$(mktemp -d)

  set +e
  sudo mount -o loop $small_stateful $new_stateful_mnt
  sudo cp "$INSTALL_VBLOCK" "$new_stateful_mnt/vmlinuz_hd.vblock"
  sudo mkdir "$new_stateful_mnt/var"
  sudo umount -d "$new_stateful_mnt"
  rmdir "$new_stateful_mnt"
  set -e

  # Create a recovery image of the right size
  # TODO(wad) Make the developer script case create a custom GPT with
  # just the kernel image and stateful.
  update_partition_table "$FLAGS_image" "$small_stateful" 4096 \
                         "$RECOVERY_IMAGE" 1>&2
  return $err
}

cleanup() {
  set +e
  if [ "$FLAGS_image" != "$RECOVERY_IMAGE" ]; then
    rm "$RECOVERY_IMAGE"
  fi
  rm "$INSTALL_VBLOCK"
}

# main process begins here.

set -e
set -u

IMAGE_DIR="$(dirname "$FLAGS_image")"
IMAGE_NAME="$(basename "$FLAGS_image")"
RECOVERY_IMAGE="${FLAGS_to:-$IMAGE_DIR/recovery_image.bin}"
RECOVERY_KERNEL_IMAGE=\
"${FLAGS_kernel_outfile:-${IMAGE_DIR}/recovery_vmlinuz.image}"
RECOVERY_KERNEL_VBLOCK="${RECOVERY_KERNEL_IMAGE}.vblock"
STATEFUL_DIR="$IMAGE_DIR/stateful_partition"
SCRIPTS_DIR=${SCRIPT_ROOT}

# Mounts gpt image and sets up var, /usr/local and symlinks.
# If there's a dev payload, mount stateful
#  offset=$(partoffset "${FLAGS_from}/${filename}" 1)
#  sudo mount ${ro_flag} -o loop,offset=$(( offset * 512 )) \
#    "${FLAGS_from}/${filename}" "${FLAGS_stateful_mountpt}"
# If not, resize stateful to 1 sector.
#

if [ $FLAGS_kernel_image_only -eq $FLAGS_TRUE -a \
     -n "$FLAGS_kernel_image" ]; then
  die "Cannot use --kernel_image_only with --kernel_image"
fi

if [ $FLAGS_modify_in_place -eq $FLAGS_TRUE ]; then
  if [ $FLAGS_minimize_image -eq $FLAGS_TRUE ]; then
    die "Cannot use --modify_in_place and --minimize_image together."
  fi
  RECOVERY_IMAGE="${FLAGS_image}"
fi

echo "Creating recovery image from ${FLAGS_image}"

INSTALL_VBLOCK=$(get_install_vblock)
if [ -z "$INSTALL_VBLOCK" ]; then
  die "Could not copy the vblock from stateful."
fi

if [ -z "$FLAGS_kernel_image" ]; then
  emerge_recovery_kernel
  create_recovery_kernel_image
  echo "Recovery kernel created at $RECOVERY_KERNEL_IMAGE"
else
  RECOVERY_KERNEL_IMAGE="$FLAGS_kernel_image"
fi

if [ $FLAGS_kernel_image_only -eq $FLAGS_TRUE ]; then
  echo "Kernel emitted. Stopping there."
  rm "$INSTALL_VBLOCK"
  exit 0
fi

if [ $FLAGS_modify_in_place -eq $FLAGS_FALSE ]; then
  rm "$RECOVERY_IMAGE" || true  # Start fresh :)
fi

trap cleanup EXIT

maybe_resize_stateful  # Also copies the image if needed.

install_recovery_kernel

echo "Recovery image created at $RECOVERY_IMAGE"
print_time_elapsed
trap - EXIT
