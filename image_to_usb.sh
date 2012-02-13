#!/bin/bash

# Copyright (c) 2010 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Script to convert the output of build_image.sh to a usb or SD image.

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
[ -f /usr/lib/installer/chromeos-common.sh ] && \
  INSTALLER_ROOT=/usr/lib/installer || \
  INSTALLER_ROOT=$(dirname "$(readlink -f "$0")")

. "${INSTALLER_ROOT}/chromeos-common.sh" || \
  die "Unable to load chromeos-common.sh"

# In case chromeos-common.sh doesn't support MMC yet
declare -F list_mmc_disks >/dev/null || list_mmc_disks() { true; }

get_default_board

# Flags
DEFINE_string board "${DEFAULT_BOARD}" \
  "board for which the image was built"
DEFINE_string from "" \
  "directory containing the image, or image full pathname"
DEFINE_string to "/dev/sdX" \
  "write to a specific disk or image file"
DEFINE_string to_product "" \
  "find target device with product name matching a string (accepts wildcards)"
DEFINE_boolean yes ${FLAGS_FALSE} \
  "answer yes to all prompts" \
  y
DEFINE_boolean force_copy ${FLAGS_FALSE} \
  "always rebuild test image"
DEFINE_boolean force_non_usb ${FLAGS_FALSE} \
  "force writing even if target device doesn't appear to be a USB/MMC disk"
DEFINE_boolean factory_install ${FLAGS_FALSE} \
  "generate a factory install shim"
DEFINE_boolean factory ${FLAGS_FALSE} \
  "generate a factory runing image, implies autotest and test"
DEFINE_boolean copy_kernel ${FLAGS_FALSE} \
  "copy the kernel to the fourth partition"
DEFINE_boolean test_image "${FLAGS_FALSE}" \
  "copy normal image to ${CHROMEOS_TEST_IMAGE_NAME} and modify it for test"
DEFINE_string image_name "" \
  "image base name (auto-select if empty)" \
  i
DEFINE_string build_root "/build" \
  "root location for board sysroots"
DEFINE_boolean install ${FLAGS_FALSE} \
  "install to the USB/MMC device"
DEFINE_string arch "" \
  "architecture for which the image was built (derived from board if empty)"

# Parse command line
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

# Generates a descriptive string of a removable device. Includes the
# manufacturer (if non-empty), product and a human-readable size.
function get_disk_string() {
  local disk="${1##*/}"
  local manufacturer_string=$(get_disk_info $disk manufacturer)
  local product_string=$(get_disk_info $disk product)
  local disk_size=$(sudo fdisk -l /dev/$disk 2>/dev/null | grep Disk |
                    head -n 1 | cut -d' ' -f3-4 | sed 's/,//g')
  # I've seen one case where manufacturer only contains spaces, hence the test.
  if [ -n "${manufacturer_string// }" ]; then
    echo -n "${manufacturer_string} "
  fi
  echo "${product_string}, ${disk_size}"
}


# Prohibit mutually exclusive factory/install flags.
if [ ${FLAGS_factory} -eq ${FLAGS_TRUE} -a \
     ${FLAGS_factory_install} -eq ${FLAGS_TRUE} ] ; then
  die "Factory test image is incompatible with factory install shim"
fi

# Allow --from /foo/file.bin
if [ -f "${FLAGS_from}" ]; then
  pathname=$(dirname "${FLAGS_from}")
  filename=$(basename "${FLAGS_from}")
  FLAGS_image_name="${filename}"
  FLAGS_from="${pathname}"
fi

# Require autotest for manucaturing image.
if [ ${FLAGS_factory} -eq ${FLAGS_TRUE} ] ; then
  echo "Factory image requires --test_image, setting."
  FLAGS_test_image=${FLAGS_TRUE}
fi

# Require test for for factory install shim.
if [ ${FLAGS_factory_install} -eq ${FLAGS_TRUE} ] ; then
  echo "Factory install shim requires --test_image, setting."
  FLAGS_test_image=${FLAGS_TRUE}
fi


# Die on any errors.
set -e

# No board, no default and no image set then we can't find the image
if [ -z ${FLAGS_from} ] && [ -z ${FLAGS_board} ] ; then
  setup_board_warning
  exit 1
fi

# No board set during install
if [ -z "${FLAGS_board}" ] && [ ${FLAGS_install} -eq ${FLAGS_TRUE} ]; then
  setup_board_warning
  exit 1
fi

# We have a board name but no image set.  Use image at default location
if [ -z "${FLAGS_from}" ]; then
  FLAGS_from="$($SCRIPT_ROOT/get_latest_image.sh --board=${FLAGS_board})"
fi

if [ ! -d "${FLAGS_from}" ] ; then
  die "Cannot find image directory ${FLAGS_from}"
fi

# No target provided, attempt autodetection.
if [ "${FLAGS_to}" == "/dev/sdX" ]; then
  if [ -z "${FLAGS_to_product}" ]; then
    echo "No target device specified, autodetecting..."
  else
    echo "Looking for target devices matching '${FLAGS_to_product}'..."
  fi

  # Obtain list of USB and MMC device names.
  disk_list=( $(list_usb_disks) $(list_mmc_disks) )

  # Build list of descriptive strings for detected devices.
  unset disk_string_list
  for disk in "${disk_list[@]}"; do
    # If --to_product was used, match against provided string.
    # Note: we intentionally use [[ ... != ... ]] to allow pattern matching on
    # the product string.
    if [ -n "${FLAGS_to_product}" ] &&
       [[ "$(get_disk_info ${disk} product)" != ${FLAGS_to_product} ]]; then
      continue
    fi

    disk_string=$(get_disk_string /dev/${disk})
    disk_string_list=( "${disk_string_list[@]}"
                       "/dev/${disk}: ${disk_string}" )
  done

  # If no (matching) devices found, quit.
  if (( ! ${#disk_string_list[*]} )); then
    if [ -z "${FLAGS_to_product}" ]; then
      die "No USB/MMC devices could be detected"
    else
      die "No matching USB/MMC devices could be detected"
    fi
  fi

  # Prompt for selection, or autoselect if only one device was found.
  if (( ${#disk_string_list[*]} > 1 )); then
    PS3="Select a target device: "
    select disk_string in "${disk_string_list[@]}"; do
      if [ -z "${disk_string}" ]; then
        die "Invalid selection"
      fi
      break
    done
  else
    disk_string="${disk_string_list}"
    echo "Found ${disk_string}"
  fi

  FLAGS_to="${disk_string%%:*}"
elif [ -n "${FLAGS_to_product}" ]; then
  die "Cannot specify both --to and --to_product"
fi

# Guess ARCH if it's unset
if [ "${FLAGS_arch}" = "" ]; then
  if echo "${FLAGS_board}" | grep -qs "x86"; then
    FLAGS_arch=INTEL
  else
    FLAGS_arch=ARM
  fi
fi

# Convert args to paths.  Need eval to un-quote the string so that shell
# chars like ~ are processed; just doing FOO=`readlink -f ${FOO}` won't work.
FLAGS_from=`eval readlink -f ${FLAGS_from}`
FLAGS_to=`eval readlink -f ${FLAGS_to}`

# Check whether target device is USB/MMC, and obtain a string descriptor for it.
unset disk_string
if [ -b "${FLAGS_to}" ]; then
  if list_usb_disks | grep -q '^'${FLAGS_to##*/}'$' ||
     list_mmc_disks | grep -q '^'${FLAGS_to##*/}'$'; then
    disk_string=$(get_disk_string ${FLAGS_to})
  elif [ ${FLAGS_force_non_usb} -ne ${FLAGS_TRUE} ]; then
    # Safeguard against writing to a real non-USB disk or non-SD disk
    die "${FLAGS_to} does not appear to be a USB/MMC disk," \
        "use --force_non_usb to override"
  fi
fi

STATEFUL_DIR="${FLAGS_from}/stateful_partition"
mkdir -p "${STATEFUL_DIR}"

# Figure out which image to use.
if [ ${FLAGS_test_image} -eq ${FLAGS_TRUE} ]; then
  # Test image requested: pass the provided (or otherwise default) image name
  # to the method that's in charge of preparing a test image (note that this
  # image may or may not exist). The test image filename is returned in
  # CHROMEOS_RETURN_VAL.
  prepare_test_image "${FLAGS_from}" \
    "${FLAGS_image_name:=${CHROMEOS_IMAGE_NAME}}"
  SRC_IMAGE="${CHROMEOS_RETURN_VAL}"
else
  # Auto-detect and select an image name if none provided.
  if [ -z "${FLAGS_image_name}" ]; then
    echo "No image name specified, autodetecting..."

    # Obtain list of available images that can be used.
    image_candidate_list=( "${CHROMEOS_IMAGE_NAME}"
                           "${CHROMEOS_RECOVERY_IMAGE_NAME}"
                           "${CHROMEOS_TEST_IMAGE_NAME}"
                           "${CHROMEOS_FACTORY_TEST_IMAGE_NAME}"
                           "${CHROMEOS_FACTORY_INSTALL_SHIM_NAME}" )
    unset image_list
    for image_candidate in "${image_candidate_list[@]}"; do
      if [ -f "${FLAGS_from}/${image_candidate}" ]; then
        image_list=( "${image_list[@]}" "${image_candidate}" )
      fi
    done

    num_images=${#image_list[*]}
    if (( ${num_images} == 0 )); then
      die "No candidate images could be detected"
    elif (( ${num_images} == 1)); then
      image="${image_list}"
      echo "Found image ${image}"
    else
      # Select one from a list of available images; default to the first.
      PS3="Select an image [1]: "
      choose image "${image_list}" "ERROR" "${image_list[@]}"
      if [ "${image}" == "ERROR" ]; then
        die "Invalid selection"
      fi
    fi

    FLAGS_image_name="${image}"
  fi

  # Use the selected image.
  SRC_IMAGE="${FLAGS_from}/${FLAGS_image_name}"
fi

# Make sure that the selected image exists.
if [ ! -f "${SRC_IMAGE}" ]; then
  die "Image not found: ${SRC_IMAGE}"
fi

# Let's do it.
if [ -b "${FLAGS_to}" ]; then
  # Output to a block device (i.e., a real USB key / SD card), so need sudo dd
  if [ ${FLAGS_install} -ne ${FLAGS_TRUE} ]; then
    echo "Copying image ${SRC_IMAGE} to ${FLAGS_to}..."
  else
    echo "Installing image ${SRC_IMAGE} to ${FLAGS_to}..."
  fi

  # Warn if it looks like they supplied a partition as the destination.
  if echo "${FLAGS_to}" | grep -q '[0-9]$'; then
    drive=$(echo "${FLAGS_to}" | sed -re 's/[0-9]+$//')
    if [ -b "${drive}" ]; then
      warn "${FLAGS_to} looks like a partition; did you mean ${drive}?"
    fi
  fi

  # Make sure this is really what the user wants, before nuking the device
  if [ ${FLAGS_yes} -ne ${FLAGS_TRUE} ]; then
    warning_str="this will erase all data on ${FLAGS_to}"
    if [ -n "${disk_string}" ]; then
      warning_str="${warning_str}: ${disk_string}"
    else
      warning_str="${warning_str}, which does not appear to be a USB/MMC disk!"
    fi
    warn "${warning_str}"
    read -p "Are you sure (y/N)? " SURE
    SURE="${SURE:0:1}" # Get just the first character
    if [ "${SURE}" != "y" ]; then
      echo "Ok, better safe than sorry."
      exit
    fi
  fi

  mount_list=$(mount | grep ^"${FLAGS_to}" | awk '{print $1}')
  if [ -n "${mount_list}" ]; then
    echo "Attempting to unmount any mounts on the target device..."
    for i in ${mount_list}; do
      if sudo umount "$i" 2>&1 >/dev/null | grep "not found"; then
        die "Device ${FLAGS_to} needs to be unmounted outside the chroot"
      fi
    done
    sleep 3
  fi

  if [ ${FLAGS_install} -ne ${FLAGS_TRUE} ]; then
    sudo ${COMMON_PV_CAT} "${SRC_IMAGE}" |
      sudo dd of="${FLAGS_to}" bs=4M oflag=sync status=noxfer
    sync
  else
    if [ ${INSIDE_CHROOT} -ne 1 ]; then
      die "Installation must be done from inside the chroot"
    fi

    "${FLAGS_build_root}/${FLAGS_board}/usr/sbin/chromeos-install" \
      --yes \
      --skip_src_removable \
      --skip_dst_removable \
      --arch="${FLAGS_arch}" \
      --payload_image="${SRC_IMAGE}" \
      --dst="${FLAGS_to}"
  fi
else
  # Output to a file, so just make a copy.
  if [ "${SRC_IMAGE}" != "${FLAGS_to}" ]; then
    echo "Copying ${SRC_IMAGE} to ${FLAGS_to}..."
    ${COMMON_PV_CAT} "${SRC_IMAGE}" >"${FLAGS_to}"
  fi

  info "To copy onto a USB/MMC drive /dev/sdX, use: "
  info "  sudo dd if=${FLAGS_to} of=/dev/sdX bs=4M oflag=sync"
fi

echo "Done."
