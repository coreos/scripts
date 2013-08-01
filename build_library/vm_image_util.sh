# Copyright (c) 2013 The CoreOS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Format options. Each variable uses the form IMG_<type>_<opt>.
# Default values use the format IMG_DEFAULT_<opt>.

VALID_IMG_TYPES=(
    ami
    qemu
    rackspace
    vagrant
    virtualbox
    vmware
    xen
)

# Set at runtime to one of the above types
VM_IMG_TYPE=DEFAULT

# Set at runtime to the source and destination image paths
VM_SRC_IMG=
VM_TMP_IMG=
VM_TMP_DIR=
VM_DST_IMG=
VM_README=
VM_NAME=
VM_UUID=

# Contains a list of all generated files
VM_GENERATED_FILES=()

## DEFAULT
# If set to 1 use a hybrid GPT/MBR format instead of plain GPT
IMG_DEFAULT_HYBRID_MBR=0

# If set install the given package name to the OEM partition
IMG_DEFAULT_OEM_PACKAGE=

# Name of the target image format.
# May be raw or vmdk (vmware, virtualbox)
IMG_DEFAULT_DISK_FORMAT=raw

# Name of the target config format, default is no config
IMG_DEFAULT_CONF_FORMAT=

# Memory size to use in any config files
IMG_DEFAULT_MEM=1024

## qemu
IMG_qemu_CONF_FORMAT=qemu

## xen
# Hybrid is required by pvgrub (pygrub supports GPT but we support both)
IMG_xen_HYBRID_MBR=1
IMG_xen_CONF_FORMAT=xl

## virtualbox
IMG_virtualbox_DISK_FORMAT=vmdk
IMG_virtualbox_CONF_FORMAT=ovf

## vagrant
IMG_vagrant_DISK_FORMAT=vmdk
IMG_vagrant_CONF_FORMAT=vagrant
IMG_vagrant_OEM_PACKAGE=oem-vagrant

## vmware
IMG_vmware_DISK_FORMAT=vmdk
IMG_vmware_CONF_FORMAT=vmx

## ami
IMG_ami_HYBRID_MBR=1
IMG_ami_OEM_PACKAGE=oem-ami

## rackspace
# TODO: package doesn't exist yet
#IMG_rackspace_OEM_PACKAGE=oem-rackspace

###########################################################

# Validate and set the vm type to use for the rest of the functions
set_vm_type() {
    local vm_type="$1"
    local valid_type
    for valid_type in "${VALID_IMG_TYPES[@]}"; do
        if [[ "${vm_type}" == "${valid_type}" ]]; then
            VM_IMG_TYPE="${vm_type}"
            return 0
        fi
    done
    return 1
}

# Validate and set source vm image path
set_vm_paths() {
    local src_dir="$1"
    local dst_dir="$2"
    local src_name="$3"

    VM_SRC_IMG="${src_dir}/${src_name}"
    if [[ ! -f "${VM_SRC_IMG}" ]]; then
        die "Source image does not exist: $VM_SRC_IMG"
    fi

    local dst_name="$(_src_to_dst_name "${src_name}" "_image.$(_disk_ext)")"
    VM_DST_IMG="${dst_dir}/${dst_name}"
    VM_TMP_DIR="${dst_dir}/${dst_name}.vmtmpdir"
    VM_TMP_IMG="${VM_TMP_DIR}/disk_image.bin"
    VM_NAME="$(_src_to_dst_name "${src_name}" "")-${COREOS_VERSION_STRING}"
    VM_UUID=$(uuidgen)
    VM_README="${dst_dir}/$(_src_to_dst_name "${src_name}" ".README")"
}

_get_vm_opt() {
    local opt="$1"
    local type_opt="IMG_${VM_IMG_TYPE}_${opt}"
    local default_opt="IMG_DEFAULT_${opt}"
    echo "${!type_opt:-${!default_opt}}"
}

# Translate source image names to output names.
# This keeps naming consistent across all vm types.
_src_to_dst_name() {
    local src_img="$1"
    local suffix="$2"
    echo "${1%_image.bin}_${VM_IMG_TYPE}${suffix}"
}

# Get the proper disk format extension.
_disk_ext() {
    local disk_format=$(_get_vm_opt DISK_FORMAT)
    case ${disk_format} in
        raw) echo bin;;
        *) echo "${disk_format}";;
    esac
}

# Unpack the source disk to individual partitions, optionally using an
# alternate filesystem image for the state partition instead of the one
# from VM_SRC_IMG. Start new image using the given disk layout.
unpack_source_disk() {
    local disk_layout="$1"
    local alternate_state_image="$2"

    if [[ -n "${alternate_state_image}" && ! -f "${alternate_state_image}" ]]
    then
        die "State image does not exist: $alternate_state_image"
    fi

    info "Unpacking source image to $(relpath "${VM_TMP_DIR}")"

    rm -rf "${VM_TMP_DIR}"
    mkdir -p "${VM_TMP_DIR}"

    pushd "${VM_TMP_DIR}" >/dev/null
    local src_dir=$(dirname "${VM_SRC_IMG}")
    "${src_dir}/unpack_partitions.sh" "${VM_SRC_IMG}"
    popd >/dev/null

    # Partition paths that have been unpacked from VM_SRC_IMG
    TEMP_ESP="${VM_TMP_DIR}"/part_${NUM_ESP}
    TEMP_OEM="${VM_TMP_DIR}"/part_${NUM_OEM}
    TEMP_ROOTFS="${VM_TMP_DIR}"/part_${NUM_ROOTFS_A}
    TEMP_STATE="${VM_TMP_DIR}"/part_${NUM_STATEFUL}
    # Copy the replacement STATE image if it is set
    if [[ -n "${alternate_state_image}" ]]; then
        cp --sparse=always "${alternate_state_image}" "${TEMP_STATE}"
    fi

    TEMP_PMBR="${VM_TMP_DIR}"/pmbr
    dd if="${VM_SRC_IMG}" of="${TEMP_PMBR}" bs=512 count=1

    info "Initializing new partition table..."
    TEMP_PARTITION_SCRIPT="${VM_TMP_DIR}/partition_script.sh"
    write_partition_script "${disk_layout}" "${TEMP_PARTITION_SCRIPT}"
    . "${TEMP_PARTITION_SCRIPT}"
    write_partition_table "${VM_TMP_IMG}" "${TEMP_PMBR}"
}

resize_state_partition() {
    local size_in_bytes="$1"
    local size_in_sectors=$(( size_in_bytes / 512 ))
    local size_in_mb=$(( size_in_bytes / 1024 / 1024 ))
    local original_size=$(stat -c%s "${TEMP_STATE}")

    if [[ "${original_size}" -gt "${size_in_bytes}" ]]; then
        die "Cannot resize stateful image to smaller than original."
    fi

    info "Resizing stateful partition to ${size_in_mb}MB"
    /sbin/e2fsck -pf "${TEMP_STATE}"
    /sbin/resize2fs "${TEMP_STATE}" "${size_in_sectors}s"
}

# If the current type defines a oem package install it to the given fs image.
install_oem_package() {
    local oem_pkg=$(_get_vm_opt OEM_PACKAGE)
    local oem_mnt="${VM_TMP_DIR}/oem"

    if [[ -z "${oem_pkg}" ]]; then
        return 0
    fi

    info "Installing ${oem_pkg} to OEM partition"
    mkdir -p "${oem_mnt}"
    sudo mount -o loop "${TEMP_OEM}" "${oem_mnt}"

    # TODO(polvi): figure out how to keep portage from putting these
    # portage files on disk, we don't need or want them.
    emerge-${BOARD} --root="${oem_mnt}" --root-deps=rdeps "${oem_pkg}"

    sudo umount "${oem_mnt}"
    rm -rf "${oem_mnt}"
}

# Write the vm disk image to the target directory in the proper format
write_vm_disk() {
    info "Writing partitions to new disk image"
    dd if="${TEMP_ROOTFS}" of="${VM_TMP_IMG}" conv=notrunc,sparse \
        bs=512 seek=$(partoffset ${VM_TMP_IMG} ${NUM_ROOTFS_A})
    dd if="${TEMP_STATE}"  of="${VM_TMP_IMG}" conv=notrunc,sparse \
        bs=512 seek=$(partoffset ${VM_TMP_IMG} ${NUM_STATEFUL})
    dd if="${TEMP_ESP}"    of="${VM_TMP_IMG}" conv=notrunc,sparse \
        bs=512 seek=$(partoffset ${VM_TMP_IMG} ${NUM_ESP})
    dd if="${TEMP_OEM}"    of="${VM_TMP_IMG}" conv=notrunc,sparse \
        bs=512 seek=$(partoffset ${VM_TMP_IMG} ${NUM_OEM})

    if [[ $(_get_vm_opt HYBRID_MBR) -eq 1 ]]; then
        info "Creating hybrid MBR"
        _write_hybrid_mbr "${VM_TMP_IMG}"
    fi

    local disk_format=$(_get_vm_opt DISK_FORMAT)
    info "Writing $disk_format image $(basename "${VM_DST_IMG}")"
    _write_${disk_format}_disk "${VM_TMP_IMG}" "${VM_DST_IMG}"
    VM_GENERATED_FILES+=( "${VM_DST_IMG}" )
}

_write_hybrid_mbr() {
    # TODO(marineam): Switch to sgdisk
    /usr/sbin/gdisk "$1" <<EOF
r
h
1
N
c
Y
N
w
Y
Y
EOF
}

_write_raw_disk() {
    mv "$1" "$2"
}

_write_vmdk_disk() {
    qemu-img convert -f raw "$1" -O vmdk "$2"
}

# If a config format is defined write it!
write_vm_conf() {
    local conf_format=$(_get_vm_opt CONF_FORMAT)
    if [[ -n "${conf_format}" ]]; then
        info "Writing ${conf_format} configuration"
        _write_${conf_format}_conf "$@"
    fi
}

_write_qemu_conf() {
    local vm_mem="${1:-$(_get_vm_opt MEM)}"
    local src_name=$(basename "$VM_SRC_IMG")
    local dst_name=$(basename "$VM_DST_IMG")
    local dst_dir=$(dirname "$VM_DST_IMG")
    local conf_path="${dst_dir}/$(_src_to_dst_name "${src_name}" ".conf")"

    # FIXME qemu 1.4/5 doesn't support these options in config files
    # Seems like submitting a patch to fix that and documenting this
    # format would be a worthy projects...
    #  name=${VM_NAME}
    #  uuid=${VM_UUID}
    #  m=${vm_mem}
    #  cpu=kvm64
    #  smp=2

    cat >"${conf_path}" <<EOF
# qemu config file

# Default to KVM, fall back on full emulation
[machine]
    accel = "kvm:tcg"

[drive]
    media = "disk"
    index = "0"
#   if = "virtio"
    file = "${dst_name}"
    format = "raw"

[net]
    type = "nic"
    vlan = "0"
    model = "virtio"

[net]
    type = "user"
    vlan = "0"
    hostfwd = "tcp::2222-:22"
EOF

    cat >"${VM_README}" <<EOF
If you have qemu installed, you can start the image with:
cd $(relpath "${dst_dir}")
qemu-system-x86_64 -curses -m ${vm_mem} -readconfig "${conf_path##*/}"

SSH into that host with:
ssh 127.0.0.1 -p 2222
EOF

    VM_GENERATED_FILES+=( "${conf_path}" "${VM_README}" )
}

# Generate the vmware config file
# A good reference doc: http://www.sanbarrow.com/vmx.html
_write_vmx_conf() {
    local vm_mem="${1:-$(_get_vm_opt MEM)}"
    local src_name=$(basename "$VM_SRC_IMG")
    local dst_name=$(basename "$VM_DST_IMG")
    local dst_dir=$(dirname "$VM_DST_IMG")
    local vmx_path="${dst_dir}/$(_src_to_dst_name "${src_name}" ".vmx")"
    cat >"${vmx_path}" <<EOF
#!/usr/bin/vmware
.encoding = "UTF-8"
config.version = "8"
virtualHW.version = "4"
memsize = "${vm_mem}"
ide0:0.present = "TRUE"
ide0:0.fileName = "${dst_name}"
ethernet0.present = "TRUE"
usb.present = "TRUE"
sound.present = "TRUE"
sound.virtualDev = "es1371"
displayName = "CoreOS"
guestOS = "otherlinux"
ethernet0.addressType = "generated"
floppy0.present = "FALSE""
EOF
    VM_GENERATED_FILES+=( "${vmx_path}" )
}

# Generate a new-style (xl) Xen config file for both pvgrub and pygrub
_write_xl_conf() {
    local vm_mem="${1:-$(_get_vm_opt MEM)}"
    local src_name=$(basename "$VM_SRC_IMG")
    local dst_name=$(basename "$VM_DST_IMG")
    local dst_dir=$(dirname "$VM_DST_IMG")
    local pygrub="${dst_dir}/$(_src_to_dst_name "${src_name}" "_pygrub.cfg")"
    local pvgrub="${dst_dir}/$(_src_to_dst_name "${src_name}" "_pvgrub.cfg")"

    # Set up the few differences between pygrub and pvgrub
    echo '# Xen PV config using pygrub' > "${pygrub}"
    echo 'bootloader = "pygrub"' >> "${pygrub}"

    echo '# Xen PV config using pvgrub' > "${pvgrub}"
    echo 'kernel = "/usr/lib/xen/boot/pv-grub-x86_64.gz"' >> "${pvgrub}"
    echo 'extra = "(hd0,0)/boot/grub/menu.lst"' >> "${pvgrub}"

    # The rest is the same
    tee -a "${pygrub}" >> "${pvgrub}" <<EOF

builder = "generic"
name = "${VM_NAME}"
uuid = "${VM_UUID}"

memory = "${vm_mem}"
vcpus = 2
# TODO(marineam): networking...
vif = [ ]
disk = [ '${dst_name},raw,xvda' ]
EOF

    cat > "${VM_README}" <<EOF
If this is a Xen Dom0 host with pygrub you can start the vm with:
cd $(relpath "${dst_dir}")
xl create -c "${pygrub##*/}"

Or with pvgrub instead:
xl create -c "${pvgrub##*/}"

Detach from the console with ^] and reattach with:
xl console ${VM_NAME}

Kill the vm with:
xl destroy ${VM_NAME}
EOF
    VM_GENERATED_FILES+=( "${pygrub}" "${pvgrub}" "${VM_README}" )
}

_write_ovf_conf() {
    local vm_mem="${1:-$(_get_vm_opt MEM)}"
    local src_name=$(basename "$VM_SRC_IMG")
    local dst_name=$(basename "$VM_DST_IMG")
    local dst_dir=$(dirname "$VM_DST_IMG")
    local ovf="${dst_dir}/$(_src_to_dst_name "${src_name}" ".ovf")"

    "${BUILD_LIBRARY_DIR}/virtualbox_ovf.sh" \
            --vm_name "$VM_NAME" \
            --disk_vmdk "$VM_DST_IMG" \
            --memory_size "$vm_mem" \
            > "$ovf"

    local ovf_name=$(basename "${ovf}")
    cat > "${VM_README}" <<EOF
Copy ${dst_name} and ${ovf_name} to a VirtualBox host and run:
VBoxManage import ${ovf_name}
EOF

    VM_GENERATED_FILES+=( "$ovf" "${VM_README}" )
}

vm_cleanup() {
    info "Cleaning up temporary files"
    rm -rf "${VM_TMP_DIR}"
}

_write_vagrant_conf() {
    local vm_mem="${1:-$(_get_vm_opt MEM)}"
    local src_name=$(basename "$VM_SRC_IMG")
    local dst_name=$(basename "$VM_DST_IMG")
    local dst_dir=$(dirname "$VM_DST_IMG")
    local ovf="${dst_dir}/$(_src_to_dst_name "${src_name}" ".ovf")"
    local vfile="${dst_dir}/$(_src_to_dst_name "${src_name}" ".Vagrantfile")"

    "${BUILD_LIBRARY_DIR}/virtualbox_ovf.sh" \
            --vm_name "$VM_NAME" \
            --disk_vmdk "$VM_DST_IMG" \
            --memory_size "$vm_mem" \
            > "$ovf"

    cat > "${vfile}" <<EOF
Vagrant.configure("2") do |config|
# SSH in as the default 'core' user, it has the vagrant ssh key.
config.ssh.username = "core"

# Disable the base shared folder, guest additions are unavailable.
config.vm.synced_folder ".", "/vagrant", disabled: true
end
EOF

    cat > "${VM_README}" <<EOF
Vagrant >= 1.2 is required.
EOF

    VM_GENERATED_FILES+=( "$ovf" "${vfile}" "${VM_README}" )
}

print_readme() {
    local filename
    info "Files written to $(relpath "$(dirname "${VM_DST_IMG}")")"
    for filename in "${VM_GENERATED_FILES[@]}"; do
        info " - $(basename "${filename}")"
    done

    if [[ -f "${VM_README}" ]]; then
        cat "${VM_README}"
    fi
}
