#!/bin/bash

# Copyright (c) 2011 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Script to generate a factory install partition set and miniomaha.conf
# file from a release image and a factory image. This creates a server
# configuration that can be installed using a factory install shim.
#
# miniomaha lives in src/platform/dev/ and miniomaha partition sets live
# in src/platform/dev/static.

# This script may be executed in a full CrOS source tree or an extracted factory
# bundle with limited tools, so we must always load scripts from $SCRIPT_ROOT
# and search for binary programs in $SCRIPT_ROOT/../bin

SCRIPT="$(readlink -f "$0")"
SCRIPT_ROOT="$(dirname "$SCRIPT")"
. "$SCRIPT_ROOT/lib/cros_image_common.sh" || exit 1
image_find_tool "cgpt" "$SCRIPT_ROOT/../bin"

if [ -f "$SCRIPT_ROOT/../dev/devserver.py" ]; then
  # Running within an extracted factory bundle
  GCLIENT_ROOT="$(readlink -f "$SCRIPT_ROOT/..")"
fi
. "$SCRIPT_ROOT/common.sh" || exit 1
. "$SCRIPT_ROOT/chromeos-common.sh" || exit 1

get_default_board
FLAGS_NONE='none'

# Flags
DEFINE_string board "${DEFAULT_BOARD}" "Board for which the image was built"
DEFINE_string factory "" \
  "Directory and file containing factory image: /path/chromiumos_test_image.bin"
DEFINE_string firmware_updater "" \
  "Firmware updater (shellball) into the server configuration,"\
" or '$FLAGS_NONE' to prevent running firmware updater."
DEFINE_string hwid_updater "" \
  "The component list updater for HWID validation,"\
" or '$FLAGS_NONE' to prevent updating the component list files."
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
DEFINE_boolean detect_release_image ${FLAGS_TRUE} \
  "If set, try to auto-detect the type of release image and convert if required"
DEFINE_string config "" \
  "Config file where parameters are read from"

# Parse command line
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

on_exit() {
  image_clean_temp
}

# Param checking and validation
check_file_param() {
  local param="$1"
  local msg="$2"
  local param_name="${param#FLAGS_}"
  local param_value="$(eval echo \$$1)"

  [ -n "$param_value" ] ||
    die "You must assign a file for --$param_name $msg"
  [ -f "$param_value" ] ||
    die "Cannot find file: $param_value"
}

check_file_param_or_none() {
  local param="$1"
  local msg="$2"
  local param_name="${param#FLAGS_}"
  local param_value="$(eval echo \$$1)"

  if [ "$param_value" = "$FLAGS_NONE" ]; then
    eval "$param=''"
    return
  fi
  [ -n "$param_value" ] ||
    die "You must assign either a file or 'none' for --$param_name $msg"
  [ -f "$param_value" ] ||
    die "Cannot find file: $param_value"
}

check_optional_file_param() {
  local param="$1"
  local msg="$2"
  local param_name="${param#FLAGS_}"
  local param_value="$(eval echo \$$1)"

  if [ -n "$param_value" ] && [ ! -f "$param_value" ]; then
    die "Cannot find file: $param_value"
  fi
}

check_empty_param() {
  local param="$1"
  local msg="$2"
  local param_name="${param#FLAGS_}"
  local param_value="$(eval echo \$$1)"

  [ -z "$param_value" ] || die "Parameter --$param_name is not supported $msg"
}

check_parameters() {
  check_file_param FLAGS_release ""
  check_file_param FLAGS_factory ""

  # All remaining parameters must be checked:
  # install_shim, firmware, hwid_updater, complete_script.

  if [ -n "${FLAGS_usbimg}" ]; then
    [ -z "${FLAGS_diskimg}" ] ||
      die "--usbimg and --diskimg cannot be used at the same time."
    check_file_param_or_none FLAGS_firmware_updater "in --usbimg mode"
    check_file_param_or_none FLAGS_hwid_updater "in --usbimg mode"
    check_empty_param FLAGS_complete_script "in --usbimg mode"
    check_file_param FLAGS_install_shim "in --usbimg mode"
  elif [ -n "${FLAGS_diskimg}" ]; then
    check_empty_param FLAGS_firmware_updater "in --diskimg mode"
    check_file_param_or_none FLAGS_hwid_updater "in --diskimg mode"
    check_empty_param FLAGS_complete_script "in --diskimg mode"
    check_empty_param FLAGS_install_shim "in --diskimg mode"
  else
    check_file_param_or_none FLAGS_firmware_updater "in mini-omaha mode"
    check_file_param_or_none FLAGS_hwid_updater "in mini-omaha mode"
    check_optional_file_param FLAGS_complete_script "in mini-omaha mode"
    check_empty_param FLAGS_install_shim "in mini-omaha mode"
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

  # When "sudo -v" is executed inside chroot, it prompts for password; however
  # the user account inside chroot may be using a different password (ex,
  # "chronos") from the same account outside chroot.  The /etc/sudoers file
  # inside chroot has explicitly specified "userid ALL=NOPASSWD: ALL" for the
  # account, so we should do nothing inside chroot.
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

  # Override this with path to modified kernel (for non-SSD images)
  RELEASE_KERNEL=""

  # Check required tools.
  if ! image_has_part_tools; then
    die "Missing partition tools. Please install cgpt/parted, or run in chroot."
  fi
}

# Prepares release image source by checking image type, and creates modified
# partition blob in RELEASE_KERNEL if required.
prepare_release_image() {
  local image="$(readlink -f "$1")"
  local kernel="$(mktemp --tmpdir)"
  image_add_temp "$kernel"

  # Image Types:
  # - recovery: kernel in #4 and vmlinuz_hd.vblock in #1
  # - usb: kernel in #2 and vmlinuz_hd.vblock in #1
  # - ssd: kernel in #2, no need to change
  image_dump_partition "$image" "2" >"$kernel" 2>/dev/null ||
    die "Cannot extract kernel partition from image: $image"

  local image_type="$(image_cros_kernel_boot_type "$kernel")"
  local need_vmlinuz_hd=""
  info "Image type is [$image_type]: $image"

  case "$image_type" in
    "ssd" )
      true
      ;;
    "usb" )
      RELEASE_KERNEL="$kernel"
      need_vmlinuz_hd="TRUE"
      ;;
    "recovery" )
      RELEASE_KERNEL="$kernel"
      image_dump_partition "$image" "4" >"$kernel" 2>/dev/null ||
        die "Cannot extract real kernel for recovery image: $image"
      need_vmlinuz_hd="TRUE"
      ;;
    * )
      die "Unexpected release image type: $image_type."
      ;;
  esac

  if [ -n "$need_vmlinuz_hd" ]; then
    local temp_mount="$(mktemp -d --tmpdir)"
    local vmlinuz_hd_file="vmlinuz_hd.vblock"
    image_add_temp "$temp_mount"
    image_mount_partition "$image" "1" "$temp_mount" "ro" ||
      die "No stateful partition in $image."
    [ -s "$temp_mount/$vmlinuz_hd_file" ] ||
      die "Missing $vmlinuz_hd_file in stateful partition: $image"
    sudo dd if="$temp_mount/$vmlinuz_hd_file" of="$kernel" \
      bs=512 conv=notrunc >/dev/null 2>&1 ||
      die "Cannot update kernel with $vmlinuz_hd_file"
    image_umount_partition "$temp_mount"
  fi
}

prepare_img() {
  local outdev="$(readlink -f "$FLAGS_diskimg")"
  local sectors="$FLAGS_sectors"
  local force_full="true"

  # We'll need some code to put in the PMBR, for booting on legacy BIOS.
  echo "Fetch PMBR"
  local pmbrcode="$(mktemp --tmpdir)"
  image_add_temp "$pmbrcode"
  sudo dd bs=512 count=1 if="${FLAGS_release}" of="${pmbrcode}" status=noxfer

  echo "Prepare base disk image"
  # Create an output file if requested, or if none exists.
  if [ -b "${outdev}" ] ; then
    echo "Using block device ${outdev}"
  elif [ ! -e "${outdev}" -o \
        "$(stat -c %s ${outdev})" != "$(( ${sectors} * 512 ))"  -o \
        "$FLAGS_preserve" = "$FLAGS_FALSE" ]; then
    echo "Generating empty image file"
    truncate -s "0" "$outdev"
    truncate -s "$((sectors * 512))" "$outdev"
  else
    echo "Reusing $outdev"
  fi

  # Create GPT partition table.
  locate_gpt
  install_gpt "${outdev}" 0 0 "${pmbrcode}" 0 "${force_full}"
  # Activate the correct partition.
  sudo "${GPT}" add -i 2 -S 1 -P 1 "${outdev}"
}

prepare_dir() {
  local dir="$1"

  # TODO(hungte) the three files were created as root by old mk_memento_images;
  #  we can prevent the sudo in future.
  sudo rm -f "${dir}/rootfs-test.gz"
  sudo rm -f "${dir}/rootfs-release.gz"
  sudo rm -f "${dir}/update.gz"
  for filename in efi oem state hwid firmware; do
    rm -f "${dir}/${filename}.gz"
  done
  if [ ! -d "${dir}" ]; then
    mkdir -p "${dir}"
  fi
}

# Compresses kernel and rootfs of an imge file, and output its hash.
# Usage:compress_and_hash_memento_image kernel rootfs
# Please see "mk_memento_images --help" for detail of parameter syntax
compress_and_hash_memento_image() {
  local kern="$1"
  local rootfs="$2"
  [ "$#" = "2" ] || die "Internal error: compress_and_hash_memento_image $*"

  "${SCRIPTS_DIR}/mk_memento_images.sh" "$kern" "$rootfs" "." |
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
  local release_file="$FLAGS_release"

  if [ -n "$RELEASE_KERNEL" ]; then
    # TODO(hungte) Improve make_universal_factory_shim to support assigning
    # a modified kernel to prevent creating temporary image here
    info "Creating temporary SSD-type release image, please wait..."
    release_file="$(mktemp --tmpdir)"
    image_add_temp "${release_file}"
    if image_has_part_tools pv; then
      pv -B 16M "${FLAGS_release}" >"${release_file}"
    else
      cp -f "${FLAGS_release}" "${release_file}"
    fi
    image_partition_copy_from_file "${RELEASE_KERNEL}" "${release_file}" 2
  fi

  "$builder" -m "${FLAGS_factory}" -f "${FLAGS_usbimg}" \
    "${FLAGS_install_shim}" "${FLAGS_factory}" "${release_file}"
  apply_hwid_updater "${FLAGS_hwid_updater}" "${FLAGS_usbimg}"

  # Extract and modify lsb-factory from original install shim
  local lsb_path="/dev_image/etc/lsb-factory"
  local src_dir="$(mktemp -d --tmpdir)"
  local src_lsb="${src_dir}${lsb_path}"
  local new_dir="$(mktemp -d --tmpdir)"
  local new_lsb="${new_dir}${lsb_path}"
  image_add_temp "$src_dir" "$new_dir"
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
  image_umount_partition "$new_dir"
  image_umount_partition "$src_dir"

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
  local release_image="${RELEASE_DIR}/${RELEASE_IMAGE}"
  echo "Release Kernel"
  if [ -n "$RELEASE_KERNEL" ]; then
    image_partition_copy_from_file "${RELEASE_KERNEL}" "${outdev}" 4
  else
    image_partition_copy "${release_image}" 2 "${outdev}" 4
  fi
  echo "Release Rootfs"
  image_partition_overwrite "${release_image}" 3 "${outdev}" 5
  echo "OEM parition"
  image_partition_overwrite "${release_image}" 8 "${outdev}" 8

  # Go to retrieve the factory test image.
  local factory_image="${FACTORY_DIR}/${FACTORY_IMAGE}"
  echo "Factory Kernel"
  image_partition_copy "${factory_image}" 2 "${outdev}" 2
  echo "Factory Rootfs"
  image_partition_overwrite "${factory_image}" 3 "${outdev}" 3
  echo "Factory Stateful"
  image_partition_overwrite "${factory_image}" 1 "${outdev}" 1
  echo "EFI Partition"
  image_partition_copy "${factory_image}" 12 "${outdev}" 12
  apply_hwid_updater "${hwid_updater}" "${outdev}"

  # TODO(nsanders, wad): consolidate this code into some common code
  # when cleaning up kernel commandlines. There is code that touches
  # this in postint/chromeos-setimage and build_image. However none
  # of the preexisting code actually does what we want here.
  local tmpesp="$(mktemp -d --tmpdir)"
  image_add_temp "$tmpesp"
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

  image_umount_partition "$tmpesp"
  echo "Generated Image at $outdev."
  echo "Done"
}

generate_omaha() {
  local kernel rootfs
  [ -n "$FLAGS_board" ] || die "Need --board parameter for mini-omaha server."
  # Clean up stale config and data files.
  prepare_dir "${OMAHA_DATA_DIR}"

  echo "Generating omaha release image from ${FLAGS_release}"
  echo "Generating omaha factory image from ${FLAGS_factory}"
  echo "Output omaha image to ${OMAHA_DATA_DIR}"
  echo "Output omaha config to ${OMAHA_CONF}"

  # Get the release image.
  ( set -e
    cd "${RELEASE_DIR}"
    prepare_dir "."

    kernel="${RELEASE_KERNEL:-${RELEASE_IMAGE}:2}"
    rootfs="${RELEASE_IMAGE}:3"
    release_hash="$(compress_and_hash_memento_image "$kernel" "$rootfs")"
    mv ./update.gz "${OMAHA_DATA_DIR}/rootfs-release.gz"
    echo "release: ${release_hash}"

    oem_hash="$(compress_and_hash_partition "${RELEASE_IMAGE}" 8 "oem.gz")"
    mv oem.gz "${OMAHA_DATA_DIR}"
    echo "oem: ${oem_hash}"
  )

  # Go to retrieve the factory test image.
  ( set -e
    cd "${FACTORY_DIR}"
    prepare_dir "."

    kernel="${FACTORY_IMAGE}:2"
    rootfs="${FACTORY_IMAGE}:3"
    test_hash="$(compress_and_hash_memento_image "$kernel" "$rootfs")"
    mv ./update.gz "${OMAHA_DATA_DIR}/rootfs-test.gz"
    echo "test: ${test_hash}"

    state_hash="$(compress_and_hash_partition "${FACTORY_IMAGE}" 1 "state.gz")"
    mv state.gz "${OMAHA_DATA_DIR}"
    echo "state: ${state_hash}"

    efi_hash="$(compress_and_hash_partition "${FACTORY_IMAGE}" 12 "efi.gz")"
    mv efi.gz "${OMAHA_DATA_DIR}"
    echo "efi: ${efi_hash}"
  )

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

parse_and_run_config() {
  # This function parses parameters from config file. Parameters can be put
  # in sections and sections of parameters will be run in turn.
  #
  # Config file format:
  # [section1]
  #  --param value
  #  --another_param  # comment
  #
  # # some more comment
  # [section2]
  #  --yet_another_param
  #
  # Note that a section header must start at the beginning of a line.
  # And it's not allowed to read from config file recursively.

  local config_file="$1"
  local -a cmds
  local cmd=""

  echo "Read parameters from: $config_file"
  local config="$(<$config_file)"
  local IFS=$'\n'
  for line in $config
  do
    if [[ "$line" =~ ^\[.*] ]]; then
      if [ -n "$cmd" ]; then
        cmds+=("$cmd")
        cmd=""
      fi
      continue
    fi
    line="${line%%#*}"
    cmd="$cmd $line"
  done
  if [ -n "$cmd" ]; then
    cmds+=("$cmd")
  fi

  for cmd in "${cmds[@]}"
  do
    info "Executing: $0 $cmd"
    eval "MFP_SUBPROCESS=1 $0 $cmd"
  done
}

main() {
  set -e
  trap on_exit EXIT

  if [ -n "$FLAGS_config" ]; then
    [ -z "$MFP_SUBPROCESS" ] ||
      die "Recursively reading from config file is not allowed"

    check_file_param FLAGS_config ""
    check_empty_param FLAGS_release "when using config file"
    check_empty_param FLAGS_factory "when using config file"
    check_empty_param FLAGS_firmware_updater "when using config file"
    check_empty_param FLAGS_hwid_updater "when using config file"
    check_empty_param FLAGS_install_shim "when using config file"
    check_empty_param FLAGS_complete_script "when using config file"
    check_empty_param FLAGS_usbimg "when using config file"
    check_empty_param FLAGS_diskimg "when using config file"
    check_empty_param FLAGS_subfolder "when using config file"

    # Make the path and folder of config file available when parsing config.
    MFP_CONFIG_PATH="$(readlink -f "$FLAGS_config")"
    MFP_CONFIG_DIR="$(dirname "$MFP_CONFIG_PATH")"

    parse_and_run_config "$FLAGS_config"
    exit
  fi

  check_parameters
  setup_environment
  if [ "$FLAGS_detect_release_image" = "$FLAGS_TRUE" ]; then
    prepare_release_image "$FLAGS_release"
  fi

  if [ -n "$FLAGS_usbimg" ]; then
    generate_usbimg
  elif [ -n "$FLAGS_diskimg" ]; then
    generate_img
  else
    generate_omaha
  fi
}

main "$@"
