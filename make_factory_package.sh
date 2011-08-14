#!/bin/bash

# Copyright (c) 2009 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Script to generate a factory install partition set and miniomaha.conf
# file from a release image and a factory image. This creates a server
# configuration that can be installed using a factory install shim.
#
# miniomaha lives in src/platform/dev/ and miniomaha partition sets live
# in src/platform/dev/static.

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
. "${SCRIPT_ROOT}/common.sh" || { echo "Unable to load common.sh"; exit 1; }
# --- END COMMON.SH BOILERPLATE ---

# Load functions and constants for chromeos-install
# NOTE: This script needs to be called from outside the chroot.
. "/usr/lib/installer/chromeos-common.sh" &> /dev/null || \
. "${SRC_ROOT}/platform/installer/chromeos-common.sh" || \
  die "Unable to load /usr/lib/installer/chromeos-common.sh"

# Load functions designed for image processing
. "${SCRIPT_ROOT}/lib/cros_image_common.sh" ||
  die "Cannot load required library: lib/cros_image_common.sh; Abort."

SCRIPT="$0"
get_default_board

# Flags
DEFINE_string board "${DEFAULT_BOARD}" "Board for which the image was built"
DEFINE_string factory "" \
  "Directory and file containing factory image: /path/chromiumos_test_image.bin"
DEFINE_string firmware_updater "" \
  "If set, include the firmware shellball into the server configuration"
DEFINE_string hwid_updater "" \
  "If set, include the component list updater for HWID validation"
DEFINE_string complete_script "" \
  "If set, include the script for the last-step execution of factory install"
DEFINE_string release "" \
  "Directory and file containing release image: /path/chromiumos_image.bin"
DEFINE_string subfolder "" \
  "If set, the name of the subfolder to put the payload items inside"
DEFINE_string usbimg "" \
  "If set, the name of the USB installation disk image file to output"
DEFINE_string install_shim "" \
  "Directory and file containing factory install shim for --usbimg"
DEFINE_string diskimg "" \
  "If set, the name of the diskimage file to output"
DEFINE_boolean preserve ${FLAGS_FALSE} \
  "If set, reuse the diskimage file, if available"
DEFINE_integer sectors 31277232  "Size of image in sectors"

# Parse command line
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

IMAGE_MOUNT_STACK=""

image_push_mounts() {
  IMAGE_MOUNT_STACK="$* $IMAGE_MOUNT_STACK"
}

image_pop_mounts() {
  local dir=""
  for dir in $IMAGE_MOUNT_STACK; do
    sudo umount "$dir" || true
    sudo rmdir "$dir" || true
  done
  IMAGE_MOUNT_STACK=""
}

check_optional_file() {
  local file="$1"
  local description="$2"
  [ -n "$file" ] || return 0
  [ -f "$file" ] || die "Cannot find $description: $file"
}

check_required_file() {
  local file="$1"
  local description="$2"
  [ -n "$file" ] || die "You must assign a file for $description."
  [ -f "$file" ] || die "Cannot find $description: $file"
}

check_empty_param() {
  [ -z "$1" ] || die "Parameter is not supported $2"
}

check_parameters() {
  check_required_file "${FLAGS_release}" "release image (--release)"
  check_required_file "${FLAGS_factory}" "factory test image (--factory)"

  # All remaining parameters must be checked:
  # install_shim, firmware, hwid_updater, complete_script.

  if [ -n "${FLAGS_usbimg}" ]; then
    [ -z "${FLAGS_diskimg}" ] ||
      die "--usbimg and --diskimg cannot be used at the same time."
    check_optional_file "${FLAGS_firmware_updater}" "firmware file (--firmware)"
    check_optional_file "${FLAGS_hwid_updater}" "HWID component list updater"
    check_empty_param "${FLAGS_complete_script}" "in usbimg: --complete_script"
    check_required_file "${FLAGS_install_shim}" "install shim (--install_shim)"
  elif [ -n "${FLAGS_diskimg}" ]; then
    check_empty_param "${FLAGS_firmware_updater}" "in diskimg: --firmware"
    check_optional_file "${FLAGS_hwid_updater}" "HWID component list updater"
    check_empty_param "${FLAGS_complete_script}" "in diskimg: --complete_script"
    check_empty_param "${FLAGS_install_shim}" "in diskimg: --install_shim"
  else
    check_optional_file "${FLAGS_firmware_updater}" "firmware file (--firmware)"
    check_optional_file "${FLAGS_hwid_updater}" "HWID component list updater"
    check_optional_file "${FLAGS_complete_script}" "completion script"
    check_empty_param "${FLAGS_install_shim}" "in omaha: --install_shim"
  fi
}

setup_environment() {
  # Convert args to paths.  Need eval to un-quote the string so that shell
  # chars like ~ are processed; just doing FOO=`readlink -f ${FOO}` won't work.
  OMAHA_DIR="${SRC_ROOT}/platform/dev"
  OMAHA_CONF="${OMAHA_DIR}/miniomaha.conf"
  OMAHA_DATA_DIR="${OMAHA_DIR}/static/"

  # Note: The subfolder flag can only append configs.  That means you will need
  # to have unique board IDs for every time you run.  If you delete
  # miniomaha.conf you can still use this flag and it will start fresh.
  if [ -n "${FLAGS_subfolder}" ]; then
    OMAHA_DATA_DIR="${OMAHA_DIR}/static/${FLAGS_subfolder}/"
  fi

  if [ ${INSIDE_CHROOT} -eq 0 ]; then
    echo "Caching sudo authentication"
    sudo -v
    echo "Done"
  fi

  # Use this image as the source image to copy
  RELEASE_DIR="$(dirname "${FLAGS_release}")"
  FACTORY_DIR="$(dirname "${FLAGS_factory}")"
  RELEASE_IMAGE="$(basename "${FLAGS_release}")"
  FACTORY_IMAGE="$(basename "${FLAGS_factory}")"

  # Check required tools.
  if ! image_has_part_tools; then
    die "Missing partition tools. Please install cgpt/parted, or run in chroot."
  fi
}


prepare_img() {
  local outdev="$(readlink -f "$FLAGS_diskimg")"
  local sectors="$FLAGS_sectors"
  local force_full="true"

  # We'll need some code to put in the PMBR, for booting on legacy BIOS.
  echo "Fetch PMBR"
  local pmbrcode="$(mktemp -d)/gptmbr.bin"
  sudo dd bs=512 count=1 if="${FLAGS_release}" of="${pmbrcode}" status=noxfer

  echo "Prepare base disk image"
  # Create an output file if requested, or if none exists.
  if [ -b "${outdev}" ] ; then
    echo "Using block device ${outdev}"
  elif [ ! -e "${outdev}" -o \
        "$(stat -c %s ${outdev})" != "$(( ${sectors} * 512 ))"  -o \
        "$FLAGS_preserve" = "$FLAGS_FALSE" ]; then
    echo "Generating empty image file"
    image_dump_partial_file /dev/zero 0 "${sectors}" |
        dd of="${outdev}" bs=8M
  else
    echo "Reusing $outdev"
  fi

  # Create GPT partition table.
  locate_gpt
  install_gpt "${outdev}" 0 0 "${pmbrcode}" 0 "${force_full}"
  # Activate the correct partition.
  sudo "${GPT}" add -i 2 -S 1 -P 1 "${outdev}"
}

prepare_omaha() {
  sudo rm -rf "${OMAHA_DATA_DIR}/rootfs-test.gz"
  sudo rm -rf "${OMAHA_DATA_DIR}/rootfs-release.gz"
  rm -rf "${OMAHA_DATA_DIR}/efi.gz"
  rm -rf "${OMAHA_DATA_DIR}/oem.gz"
  rm -rf "${OMAHA_DATA_DIR}/state.gz"
  if [ ! -d "${OMAHA_DATA_DIR}" ]; then
    mkdir -p "${OMAHA_DATA_DIR}"
  fi
}

prepare_dir() {
  sudo rm -rf rootfs-test.gz
  sudo rm -rf rootfs-release.gz
  rm -rf efi.gz
  rm -rf oem.gz
  rm -rf state.gz
}

compress_and_hash_memento_image() {
  local input_file="$1"

  sudo "${SCRIPTS_DIR}/mk_memento_images.sh" "$input_file:2" "$input_file:3" |
    grep hash |
    awk '{print $4}'
}

compress_and_hash_file() {
  local input_file="$1"
  local output_file="$2"

  if [ -z "$input_file" ]; then
    # Runs as a pipe processor
    image_gzip_compress -c -9 |
    tee "$output_file" |
    openssl sha1 -binary |
    openssl base64
  else
    image_gzip_compress -c -9 "$input_file" |
    tee "$output_file" |
    openssl sha1 -binary |
    openssl base64
  fi
}

compress_and_hash_partition() {
  local input_file="$1"
  local part_num="$2"
  local output_file="$3"

  image_dump_partition "$input_file" "$part_num" |
  compress_and_hash_file "" "$output_file"
}

# Applies HWID component list files updater into stateful partition
apply_hwid_updater() {
  local hwid_updater="$1"
  local outdev="$2"
  local hwid_result="0"

  if [ -n "$hwid_updater" ]; then
    local state_dev="$(image_map_partition "${outdev}" 1)"
    sudo sh "$hwid_updater" "$state_dev" || hwid_result="$?"
    image_unmap_partition "$state_dev" || true
    [ $hwid_result = "0" ] || die "Failed to update HWID ($hwid_result). abort."
  fi
}

generate_usbimg() {
  if ! type cgpt >/dev/null 2>&1; then
    die "Missing 'cgpt'. Please install cgpt, or run inside chroot."
  fi
  local builder="$(dirname "$SCRIPT")/make_universal_factory_shim.sh"

  "$builder" -m "${FLAGS_factory}" -f "${FLAGS_usbimg}" \
    "${FLAGS_install_shim}" "${FLAGS_factory}" "${FLAGS_release}"

  # Extract and modify lsb-factory from original install shim
  local lsb_path="/dev_image/etc/lsb-factory"
  local src_dir="$(mktemp -d --tmpdir)"
  local src_lsb="${src_dir}${lsb_path}"
  local new_dir="$(mktemp -d --tmpdir)"
  local new_lsb="${new_dir}${lsb_path}"
  apply_hwid_updater "${FLAGS_hwid_updater}" "${FLAGS_usbimg}"
  image_push_mounts "$src_dir"
  image_push_mounts "$new_dir"
  image_mount_partition "${FLAGS_install_shim}" 1 "${src_dir}" ""
  image_mount_partition "${FLAGS_usbimg}" 1 "${new_dir}" "rw"
  # Copy firmware updater, if available
  local updater_settings=""
  if [ -n "${FLAGS_firmware_updater}" ]; then
    local updater_new_path="${new_dir}/chromeos-firmwareupdate"
    sudo cp -f "${FLAGS_firmware_updater}" "${updater_new_path}"
    sudo chmod a+rx "${updater_new_path}"
    updater_settings="FACTORY_INSTALL_FIRMWARE=/mnt/stateful_partition"
    updater_settings="$updater_settings/$(basename $updater_new_path)"
  fi
  # We put the install shim kernel and rootfs into partition #2 and #3, so
  # the factory and release image partitions must be moved to +2 location.
  # USB_OFFSET=2 tells factory_installer/factory_install.sh this information.
  (cat "$src_lsb" &&
    echo "FACTORY_INSTALL_FROM_USB=1" &&
    echo "FACTORY_INSTALL_USB_OFFSET=2" &&
    echo "$updater_settings") |
    sudo dd of="${new_lsb}"
  image_pop_mounts

  # Deactivate all kernel partitions except installer slot
  local i=""
  for i in 4 5 6 7; do
    cgpt add -P 0 -T 0 -S 0 -t data -i "$i" "${FLAGS_usbimg}"
  done

  info "Generated Image at ${FLAGS_usbimg}."
  info "Done"
}

generate_img() {
  local outdev="$(readlink -f "$FLAGS_diskimg")"
  local sectors="$FLAGS_sectors"
  local hwid_updater="${FLAGS_hwid_updater}"

  if [ -n "${FLAGS_hwid_updater}" ]; then
    hwid_updater="$(readlink -f "$FLAGS_hwid_updater")"
  fi

  prepare_img

  # Get the release image.
  pushd "${RELEASE_DIR}" >/dev/null

  echo "Release Kernel"
  image_partition_copy "${RELEASE_IMAGE}" 2 "${outdev}" 4
  echo "Release Rootfs"
  image_partition_copy "${RELEASE_IMAGE}" 3 "${outdev}" 5
  echo "OEM parition"
  image_partition_copy "${RELEASE_IMAGE}" 8 "${outdev}" 8

  popd >/dev/null

  # Go to retrieve the factory test image.
  pushd "${FACTORY_DIR}" >/dev/null

  echo "Factory Kernel"
  image_partition_copy "${FACTORY_IMAGE}" 2 "${outdev}" 2
  echo "Factory Rootfs"
  image_partition_copy "${FACTORY_IMAGE}" 3 "${outdev}" 3
  echo "Factory Stateful"
  image_partition_copy "${FACTORY_IMAGE}" 1 "${outdev}" 1
  echo "EFI Partition"
  image_partition_copy "${FACTORY_IMAGE}" 12 "${outdev}" 12
  apply_hwid_updater "${hwid_updater}" "${outdev}"

  # TODO(nsanders, wad): consolidate this code into some common code
  # when cleaning up kernel commandlines. There is code that touches
  # this in postint/chromeos-setimage and build_image. However none
  # of the preexisting code actually does what we want here.
  local tmpesp="$(mktemp -d)"
  image_push_mounts "$tmpesp"
  image_mount_partition "${outdev}" 12 "$tmpesp" "rw"

  # Edit boot device default for legacy.
  # Support both vboot and regular boot.
  sudo sed -i "s/chromeos-usb.A/chromeos-hd.A/" \
      "${tmpesp}"/syslinux/default.cfg
  sudo sed -i "s/chromeos-vusb.A/chromeos-vhd.A/" \
      "${tmpesp}"/syslinux/default.cfg

  # Edit root fs default for legacy
  # Somewhat safe as ARM does not support syslinux, I believe.
  sudo sed -i "s'HDROOTA'/dev/sda3'g" "${tmpesp}"/syslinux/root.A.cfg

  image_pop_mounts
  echo "Generated Image at $outdev."
  echo "Done"
}

generate_omaha() {
  # Clean up stale config and data files.
  prepare_omaha

  # Get the release image.
  pushd "${RELEASE_DIR}" >/dev/null
  echo "Generating omaha release image from ${FLAGS_release}"
  echo "Generating omaha factory image from ${FLAGS_factory}"
  echo "Output omaha image to ${OMAHA_DATA_DIR}"
  echo "Output omaha config to ${OMAHA_CONF}"

  prepare_dir

  release_hash="$(compress_and_hash_memento_image "${RELEASE_IMAGE}")"
  sudo chmod a+rw update.gz
  mv update.gz rootfs-release.gz
  mv rootfs-release.gz "${OMAHA_DATA_DIR}"
  echo "release: ${release_hash}"

  oem_hash="$(compress_and_hash_partition "${RELEASE_IMAGE}" 8 "oem.gz")"
  mv oem.gz "${OMAHA_DATA_DIR}"
  echo "oem: ${oem_hash}"

  popd >/dev/null

  # Go to retrieve the factory test image.
  pushd "${FACTORY_DIR}" >/dev/null
  prepare_dir

  test_hash="$(compress_and_hash_memento_image "${FACTORY_IMAGE}")"
  sudo chmod a+rw update.gz
  mv update.gz rootfs-test.gz
  mv rootfs-test.gz "${OMAHA_DATA_DIR}"
  echo "test: ${test_hash}"

  state_hash="$(compress_and_hash_partition "${FACTORY_IMAGE}" 1 "state.gz")"
  mv state.gz "${OMAHA_DATA_DIR}"
  echo "state: ${state_hash}"

  efi_hash="$(compress_and_hash_partition "${FACTORY_IMAGE}" 12 "efi.gz")"
  mv efi.gz "${OMAHA_DATA_DIR}"
  echo "efi: ${efi_hash}"

  popd >/dev/null

  if [ -n "${FLAGS_firmware_updater}" ]; then
    firmware_hash="$(compress_and_hash_file "${FLAGS_firmware_updater}" \
                     "firmware.gz")"
    mv firmware.gz "${OMAHA_DATA_DIR}"
    echo "firmware: ${firmware_hash}"
  fi

  if [ -n "${FLAGS_hwid_updater}" ]; then
    hwid_hash="$(compress_and_hash_file "${FLAGS_hwid_updater}" "hwid.gz")"
    mv hwid.gz "${OMAHA_DATA_DIR}"
    echo "hwid: ${hwid_hash}"
  fi

  if [ -n "${FLAGS_complete_script}" ]; then
    complete_hash="$(compress_and_hash_file "${FLAGS_complete_script}" \
                     "complete.gz")"
    mv complete.gz "${OMAHA_DATA_DIR}"
    echo "complete: ${complete_hash}"
  fi

  # If the file does exist and we are using the subfolder flag we are going to
  # append another config.
  if [ -n "${FLAGS_subfolder}" ] &&
     [ -f "${OMAHA_CONF}" ]; then
    # Remove the ']' from the last line of the file
    # so we can add another config.
    while  [ -s "${OMAHA_CONF}" ]; do
      # If the last line is null
      if [ -z "$(tail -1 "${OMAHA_CONF}")" ]; then
        sed -i '$d' "${OMAHA_CONF}"
      elif [ "$(tail -1 "${OMAHA_CONF}")" != ']' ]; then
        sed -i '$d' "${OMAHA_CONF}"
      else
        break
      fi
    done

    # Remove the last ]
    if [ "$(tail -1 "${OMAHA_CONF}")" = ']' ]; then
      sed -i '$d' "${OMAHA_CONF}"
    fi

    # If the file is empty, create it from scratch
    if [ ! -s "${OMAHA_CONF}" ]; then
      echo "config = [" >"${OMAHA_CONF}"
    fi
  else
    echo "config = [" >"${OMAHA_CONF}"
  fi

  if [ -n "${FLAGS_subfolder}" ]; then
    subfolder="${FLAGS_subfolder}/"
  fi

  echo -n "{
   'qual_ids': set([\"${FLAGS_board}\"]),
   'factory_image': '${subfolder}rootfs-test.gz',
   'factory_checksum': '${test_hash}',
   'release_image': '${subfolder}rootfs-release.gz',
   'release_checksum': '${release_hash}',
   'oempartitionimg_image': '${subfolder}oem.gz',
   'oempartitionimg_checksum': '${oem_hash}',
   'efipartitionimg_image': '${subfolder}efi.gz',
   'efipartitionimg_checksum': '${efi_hash}',
   'stateimg_image': '${subfolder}state.gz',
   'stateimg_checksum': '${state_hash}'," >>"${OMAHA_CONF}"

  if [ -n "${FLAGS_firmware_updater}" ]  ; then
    echo -n "
   'firmware_image': '${subfolder}firmware.gz',
   'firmware_checksum': '${firmware_hash}'," >>"${OMAHA_CONF}"
  fi

  if [ -n "${FLAGS_hwid_updater}" ]  ; then
    echo -n "
   'hwid_image': '${subfolder}hwid.gz',
   'hwid_checksum': '${hwid_hash}'," >>"${OMAHA_CONF}"
  fi

  if [ -n "${FLAGS_complete_script}" ]  ; then
    echo -n "
   'complete_image': '${subfolder}complete.gz',
   'complete_checksum': '${complete_hash}'," >>"${OMAHA_CONF}"
  fi

  echo -n "
 },
]
" >>"${OMAHA_CONF}"

  info "The miniomaha server lives in src/platform/dev.
To validate the configutarion, run:
  python2.6 devserver.py --factory_config miniomaha.conf \
  --validate_factory_config
To run the server:
  python2.6 devserver.py --factory_config miniomaha.conf"
}

main() {
  set -e
  trap image_pop_mounts EXIT

  check_parameters
  setup_environment

  if [ -n "$FLAGS_usbimg" ]; then
    generate_usbimg
  elif [ -n "$FLAGS_diskimg" ]; then
    generate_img
  else
    generate_omaha
  fi
}

main "$@"
