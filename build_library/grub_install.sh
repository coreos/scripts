#!/bin/bash

# Copyright (c) 2014 The CoreOS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Replacement script for 'grub-install' which does not detect drives
# properly when partitions are mounted via individual loopback devices.

SCRIPT_ROOT=$(readlink -f $(dirname "$0")/..)
. "${SCRIPT_ROOT}/common.sh" || exit 1

# We're invoked only by build_image, which runs in the chroot
assert_inside_chroot

# Flags.
DEFINE_string board "${DEFAULT_BOARD}" \
  "The name of the board"
DEFINE_string target "" \
  "The GRUB target to install such as i386-pc or x86_64-efi"
DEFINE_string disk_image "" \
  "The disk image containing the EFI System partition."
DEFINE_boolean verity ${FLAGS_FALSE} \
  "Indicates that boot commands should enable dm-verity."
DEFINE_string copy_efi_grub "" \
  "Copy the EFI GRUB image to the specified path."
DEFINE_string copy_shim "" \
  "Copy the shim image to the specified path."

# Parse flags
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"
switch_to_strict_mode

# must be sourced after flags are parsed.
. "${BUILD_LIBRARY_DIR}/toolchain_util.sh" || exit 1
. "${BUILD_LIBRARY_DIR}/board_options.sh" || exit 1

# Our GRUB lives under coreos/grub so new pygrub versions cannot find grub.cfg
GRUB_DIR="coreos/grub/${FLAGS_target}"

# GRUB install location inside the SDK
GRUB_SRC="/usr/lib/grub/${FLAGS_target}"

# Modules required to boot a standard CoreOS configuration
CORE_MODULES=( normal search test fat part_gpt search_fs_uuid gzio search_part_label terminal gptprio configfile memdisk tar echo read )

# Name of the core image, depends on target
CORE_NAME=

# Whether the SDK's grub or the board root's grub is used. Once amd64 is
# fixed up the board root's grub will always be used.
BOARD_GRUB=0

# This may be useful if you're running the build process inside a container
# (e.g. docker/podman/etc) distinct from the host; in that case you'll have
# a distinct /dev normally and won't pick up udev probed devices.  But if you
# do the probe from the host side, it should show up in the container.
LOOP_NO_UDEV=${LOOP_NO_UDEV:-0}

case "${FLAGS_target}" in
    i386-pc)
        CORE_MODULES+=( biosdisk serial )
        CORE_NAME="core.img"
        ;;
    x86_64-efi)
	CORE_MODULES+=( serial linuxefi efi_gop getenv smbios efinet verify http tftp )
        CORE_NAME="core.efi"
        ;;
    x86_64-xen)
        CORE_NAME="core.elf"
        ;;
    arm64-efi)
        CORE_MODULES+=( serial linux efi_gop getenv smbios efinet verify http tftp )
        CORE_NAME="core.efi"
        BOARD_GRUB=1
        ;;
    *)
        die_notrace "Unknown GRUB target ${FLAGS_target}"
        ;;
esac

if [[ $BOARD_GRUB -eq 1 ]]; then
    info "Updating GRUB in ${BOARD_ROOT}"
    emerge-${BOARD} --nodeps --select -qugKN sys-boot/grub
    GRUB_SRC="${BOARD_ROOT}/usr/lib/grub/${FLAGS_target}"
fi
[[ -d "${GRUB_SRC}" ]] || die "GRUB not installed at ${GRUB_SRC}"

# In order for grub-setup-bios to properly detect the layout of the disk
# image it expects a normal partitioned block device. For most of the build
# disk_util maps individual loop devices to each partition in the image so
# the kernel can automatically detach the loop devices on unmount. When
# using a single loop device with partitions there is no such cleanup.
# That's the story of why this script has all this goo for loop and mount.
ESP_DIR=
LOOP_DEV=

cleanup() {
    if [[ -d "${ESP_DIR}" ]]; then
        if mountpoint -q "${ESP_DIR}"; then
            sudo umount "${ESP_DIR}"
        fi
        rm -rf "${ESP_DIR}"
    fi
    if [[ -b "${LOOP_DEV}" ]]; then
        sudo losetup --detach "${LOOP_DEV}"
    fi
    if [[ -n "${GRUB_TEMP_DIR}" && -e "${GRUB_TEMP_DIR}" ]]; then
      rm -r "${GRUB_TEMP_DIR}"
    fi
}
trap cleanup EXIT

info "Installing GRUB ${FLAGS_target} in ${FLAGS_disk_image##*/}"
LOOP_DEV=$(sudo losetup --find --show --partscan "${FLAGS_disk_image}")
ESP_DIR=$(mktemp --directory)

# Hack available for doing the build in a container; see the LOOP_NO_UDEV
# comments above.
if [[ ${LOOP_NO_UDEV} -eq 1 ]]; then
    echo "LOOP_NO_UDEV enabled, creating device nodes directly"
    LOOPNUM=$(echo ${LOOP_DEV} | sed -e 's,/dev/loop,,')
    for d in /sys/block/loop${LOOPNUM}/loop${LOOPNUM}p*; do
        p=$(cat ${d}/partition)
        dev=$(cat ${d}/dev)
        min=${dev##*:}
        maj=${dev%:*}
        devpath=/dev/loop${LOOPNUM}p${p}
        sudo rm -f ${devpath}
        sudo mknod -m 660 ${devpath} b ${maj} ${min}
    done
fi
# work around slow/buggy udev, make sure the node is there before mounting
if [[ ! -b "${LOOP_DEV}p1" ]]; then
    # sleep a little just in case udev is ok but just not finished yet
    warn "loopback device node ${LOOP_DEV}p1 missing, waiting on udev..."
    sleep 0.5
    for (( i=0; i<5; i++ )); do
        if [[ -b "${LOOP_DEV}p1" ]]; then
            break
        fi
        warn "loopback device node still ${LOOP_DEV}p1 missing, reprobing..."
        sudo blockdev --rereadpt ${LOOP_DEV}
        sleep 0.5
    done
    if [[ ! -b "${LOOP_DEV}p1" ]]; then
        ls -al /dev/loop*
        failboat "${LOOP_DEV}p1 where art thou? udev has forsaken us!"
    fi
fi

sudo mount -t vfat "${LOOP_DEV}p1" "${ESP_DIR}"
sudo mkdir -p "${ESP_DIR}/${GRUB_DIR}"

info "Compressing modules in ${GRUB_DIR}"
for file in "${GRUB_SRC}"/*{.lst,.mod}; do
    out="${ESP_DIR}/${GRUB_DIR}/${file##*/}"
    gzip --best --stdout "${file}" | sudo_clobber "${out}"
done

info "Generating ${GRUB_DIR}/load.cfg"
# Include a small initial config in the core image to search for the ESP
# by filesystem ID in case the platform doesn't provide the boot disk.
# The existing $root value is given as a hint so it is searched first.
ESP_FSID=$(sudo grub-probe -t fs_uuid -d "${LOOP_DEV}p1")
sudo_clobber "${ESP_DIR}/${GRUB_DIR}/load.cfg" <<EOF
search.fs_uuid ${ESP_FSID} root \$root
set prefix=(memdisk)
set
EOF

# Generate a memdisk containing the appropriately generated grub.cfg. Doing
# this because we need conflicting default behaviors between verity and
# non-verity images.
GRUB_TEMP_DIR=$(mktemp -d)
if [[ ! -f "${ESP_DIR}/coreos/grub/grub.cfg.tar" ]]; then
    info "Generating grub.cfg memdisk"

    if [[ ${FLAGS_verity} -eq ${FLAGS_TRUE} ]]; then
      # use dm-verity for /usr
      cat "${BUILD_LIBRARY_DIR}/grub.cfg" | \
        sed 's/@@MOUNTUSR@@/mount.usr=\/dev\/mapper\/usr verity.usr/' > \
        "${GRUB_TEMP_DIR}/grub.cfg"
    else
      # uses standard systemd /usr mount
      cat "${BUILD_LIBRARY_DIR}/grub.cfg" | \
        sed 's/@@MOUNTUSR@@/mount.usr/' > "${GRUB_TEMP_DIR}/grub.cfg"
    fi

    sudo tar cf "${ESP_DIR}/coreos/grub/grub.cfg.tar" \
	 -C "${GRUB_TEMP_DIR}" "grub.cfg"
fi

info "Generating ${GRUB_DIR}/${CORE_NAME}"
sudo grub-mkimage \
    --compression=auto \
    --format "${FLAGS_target}" \
    --directory "${GRUB_SRC}" \
    --config "${ESP_DIR}/${GRUB_DIR}/load.cfg" \
    --memdisk "${ESP_DIR}/coreos/grub/grub.cfg.tar" \
    --output "${ESP_DIR}/${GRUB_DIR}/${CORE_NAME}" \
    "${CORE_MODULES[@]}"

# Now target specific steps to make the system bootable
case "${FLAGS_target}" in
    i386-pc)
        info "Installing MBR and the BIOS Boot partition."
        sudo cp "${GRUB_SRC}/boot.img" "${ESP_DIR}/${GRUB_DIR}"
        sudo grub-bios-setup --device-map=/dev/null \
            --directory="${ESP_DIR}/${GRUB_DIR}" "${LOOP_DEV}"
        # boot.img gets manipulated by grub-bios-setup so it alone isn't
        # sufficient to restore the MBR boot code if it gets corrupted.
        sudo dd bs=448 count=1 status=none if="${LOOP_DEV}" \
            of="${ESP_DIR}/${GRUB_DIR}/mbr.bin"
        ;;
    x86_64-efi)
        info "Installing default x86_64 UEFI bootloader."
        sudo mkdir -p "${ESP_DIR}/EFI/boot"
	# Use the test keys for signing unofficial builds
	if [[ ${COREOS_OFFICIAL:-0} -ne 1 ]]; then
            sudo sbsign --key /usr/share/sb_keys/DB.key \
		--cert /usr/share/sb_keys/DB.crt \
                    "${ESP_DIR}/${GRUB_DIR}/${CORE_NAME}"
            sudo cp "${ESP_DIR}/${GRUB_DIR}/${CORE_NAME}.signed" \
                "${ESP_DIR}/EFI/boot/grub.efi"
            sudo sbsign --key /usr/share/sb_keys/DB.key \
                 --cert /usr/share/sb_keys/DB.crt \
                 --output "${ESP_DIR}/EFI/boot/bootx64.efi" \
                 "/usr/lib/shim/shim.efi"
        else
            sudo cp "${ESP_DIR}/${GRUB_DIR}/${CORE_NAME}" \
                "${ESP_DIR}/EFI/boot/grub.efi"
            sudo cp "/usr/lib/shim/shim.efi" \
                "${ESP_DIR}/EFI/boot/bootx64.efi"
	fi
        # copying from vfat so ignore permissions
        if [[ -n "${FLAGS_copy_efi_grub}" ]]; then
            cp --no-preserve=mode "${ESP_DIR}/EFI/boot/grub.efi" \
                "${FLAGS_copy_efi_grub}"
        fi
        if [[ -n "${FLAGS_copy_shim}" ]]; then
            cp --no-preserve=mode "${ESP_DIR}/EFI/boot/bootx64.efi" \
                "${FLAGS_copy_shim}"
        fi
        ;;
    x86_64-xen)
        info "Installing default x86_64 Xen bootloader."
        sudo mkdir -p "${ESP_DIR}/xen" "${ESP_DIR}/boot/grub"
        sudo cp "${ESP_DIR}/${GRUB_DIR}/${CORE_NAME}" \
            "${ESP_DIR}/xen/pvboot-x86_64.elf"
        sudo cp "${BUILD_LIBRARY_DIR}/menu.lst" \
            "${ESP_DIR}/boot/grub/menu.lst"
        ;;
    arm64-efi)
        info "Installing default arm64 UEFI bootloader."
        sudo mkdir -p "${ESP_DIR}/EFI/boot"
        #FIXME(andrejro): shim not ported to aarch64
        sudo cp "${ESP_DIR}/${GRUB_DIR}/${CORE_NAME}" \
            "${ESP_DIR}/EFI/boot/bootaa64.efi"
        if [[ -n "${FLAGS_copy_efi_grub}" ]]; then
            # copying from vfat so ignore permissions
            cp --no-preserve=mode "${ESP_DIR}/EFI/boot/bootaa64.efi" \
                "${FLAGS_copy_efi_grub}"
        fi
        ;;
esac

cleanup
trap - EXIT
command_completed
