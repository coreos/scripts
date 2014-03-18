# Copyright (c) 2013 The CoreOS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Format options. Each variable uses the form IMG_<type>_<opt>.
# Default values use the format IMG_DEFAULT_<opt>.

VALID_IMG_TYPES=(
    ami
    pxe
    openstack
    qemu
    rackspace
    vagrant
    vagrant_vmware_fusion
    virtualbox
    vmware
    vmware_insecure
    xen
    gce
)

# Set at runtime to one of the above types
VM_IMG_TYPE=DEFAULT

# Set at runtime to the source and destination image paths
VM_SRC_IMG=
VM_TMP_IMG=
VM_TMP_DIR=
VM_TMP_ROOT=
VM_DST_IMG=
VM_README=
VM_NAME=
VM_UUID=

# Contains a list of all generated files
VM_GENERATED_FILES=()

## DEFAULT
# If set to 0 then a partition skeleton won't be laid out on VM_TMP_IMG
IMG_DEFAULT_PARTITIONED_IMG=1

# If set to 0 boot_kernel is skipped
IMG_DEFAULT_BOOT_KERNEL=1

# If set install the given package name to the OEM partition
IMG_DEFAULT_OEM_PACKAGE=

# Name of the target image format.
# May be raw, qcow2 (qemu), or vmdk (vmware, virtualbox)
IMG_DEFAULT_DISK_FORMAT=raw

# Name of the partition layout from disk_layout.json
IMG_DEFAULT_DISK_LAYOUT=base

# Name of the target config format, default is no config
IMG_DEFAULT_CONF_FORMAT=

# Memory size to use in any config files
IMG_DEFAULT_MEM=1024

## qemu
IMG_qemu_DISK_FORMAT=qcow2
IMG_qemu_DISK_LAYOUT=vm
IMG_qemu_CONF_FORMAT=qemu

## xen
IMG_xen_BOOT_KERNEL=0
IMG_xen_CONF_FORMAT=xl

## virtualbox
IMG_virtualbox_DISK_FORMAT=vmdk_ide
IMG_virtualbox_DISK_LAYOUT=vm
IMG_virtualbox_CONF_FORMAT=ovf

## vagrant
IMG_vagrant_DISK_FORMAT=vmdk_ide
IMG_vagrant_DISK_LAYOUT=vagrant
IMG_vagrant_CONF_FORMAT=vagrant
IMG_vagrant_OEM_PACKAGE=oem-vagrant

## vagrant_vmware
IMG_vagrant_vmware_fusion_DISK_FORMAT=vmdk_scsi
IMG_vagrant_vmware_fusion_DISK_LAYOUT=vagrant
IMG_vagrant_vmware_fusion_CONF_FORMAT=vagrant_vmware_fusion
IMG_vagrant_vmware_fusion_OEM_PACKAGE=oem-vagrant

## vmware
IMG_vmware_DISK_FORMAT=vmdk_scsi
IMG_vmware_DISK_LAYOUT=vm
IMG_vmware_CONF_FORMAT=vmx

## vmware_insecure
IMG_vmware_insecure_DISK_FORMAT=vmdk_scsi
IMG_vmware_insecure_DISK_LAYOUT=vm
IMG_vmware_insecure_CONF_FORMAT=vmware_zip
IMG_vmware_insecure_OEM_PACKAGE=oem-vagrant

## ami
IMG_ami_BOOT_KERNEL=0
IMG_ami_OEM_PACKAGE=oem-ami

## openstack, supports ec2's metadata format so use oem-ami
IMG_openstack_DISK_FORMAT=qcow2
IMG_openstack_DISK_LAYOUT=vm
IMG_openstack_OEM_PACKAGE=oem-ami

## pxe, which is an cpio image
IMG_pxe_DISK_FORMAT=cpio
IMG_pxe_PARTITIONED_IMG=0
IMG_pxe_CONF_FORMAT=pxe
IMG_pxe_OEM_PACKAGE=oem-pxe

## gce, image tarball
IMG_gce_CONF_FORMAT=gce
IMG_gce_OEM_PACKAGE=oem-gce

## rackspace
IMG_rackspace_BOOT_KERNEL=0
IMG_rackspace_OEM_PACKAGE=oem-rackspace

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
    VM_TMP_ROOT="${VM_TMP_DIR}/rootfs"
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

# Generate a destination name based on file extension
_dst_name() {
    local src_name=$(basename "$VM_SRC_IMG")
    local suffix="$1"
    echo "${src_name%_image.bin}_${VM_IMG_TYPE}${suffix}"
}

# Return the destination directory
_dst_dir() {
    echo $(dirname "$VM_DST_IMG")
}


# Get the proper disk format extension.
_disk_ext() {
    local disk_format=$(_get_vm_opt DISK_FORMAT)
    case ${disk_format} in
        raw) echo bin;;
        qcow2) echo img;;
        cpio) echo cpio.gz;;
        vmdk_ide) echo vmdk;;
        vmdk_scsi) echo vmdk;;
        *) echo "${disk_format}";;
    esac
}

setup_disk_image() {
    local suffix=$(portageq-$BOARD envvar COREOS_DISK_LAYOUT_SUFFIX)
    local disk_layout="${1:-$(_get_vm_opt DISK_LAYOUT)}${suffix}"

    rm -rf "${VM_TMP_DIR}"
    mkdir -p "${VM_TMP_DIR}" "${VM_TMP_ROOT}"

    info "Initializing new disk image..."
    cp --sparse=always "${VM_SRC_IMG}" "${VM_TMP_IMG}"

    if [[ $(_get_vm_opt PARTITIONED_IMG) -eq 1 ]]; then
      "${BUILD_LIBRARY_DIR}/disk_util" --disk_layout="${disk_layout}" \
          resize "${VM_TMP_IMG}"
    fi

    info "Mounting image to $(relpath "${VM_TMP_ROOT}")"
    "${BUILD_LIBRARY_DIR}/disk_util" --disk_layout="${disk_layout}" \
        mount "${VM_TMP_IMG}" "${VM_TMP_ROOT}"

    local SYSLINUX_DIR="${VM_TMP_ROOT}/boot/efi/syslinux"
    if [[ $(_get_vm_opt BOOT_KERNEL) -eq 0 ]]; then
        sudo mv "${SYSLINUX_DIR}/default.cfg.A" "${SYSLINUX_DIR}/default.cfg"
    fi
}

# If the current type defines a oem package install it to the given fs image.
install_oem_package() {
    local oem_pkg=$(_get_vm_opt OEM_PACKAGE)
    local oem_mnt="${VM_TMP_ROOT}/usr/share/oem"

    if [[ -z "${oem_pkg}" ]]; then
        return 0
    fi

    info "Installing ${oem_pkg} to OEM partition"
    emerge-${BOARD} --root="${oem_mnt}" --root-deps=rdeps "${oem_pkg}"
    sudo rm -rf "${oem_mnt}/var"  # clean out /var/pkg/db and friends
}

# Install a new /etc/oem-release if the group varies from the default one
install_update_config() {
    local update_group=$1
    local update_server=$2
    local default_update_config="${VM_TMP_ROOT}/usr/share/coreos/update.conf"
    local overlay_update_config="${VM_TMP_ROOT}/etc/coreos/update.conf"

    if [[ -z "${update_group}" ]]; then
        return 0
    fi
    if [[ ! -e "${default_update_config}" ]]; then
	info "Image does not appear to support update groups, skipping"
        return 0
    fi
    if grep -q "GROUP=${update_group}" $default_update_config && \
       grep -q "SERVER=${update_server}" $default_update_config; then
	info "Update group (${update_group}) and server (${update_server}) config already configured"
        return 0
    fi

    info "Installing overlay /etc/coreos/update.conf, setting group ${update_group}"
    sudo mkdir -p $(dirname ${overlay_update_config})
    sudo tee "${overlay_update_config}" <<EOF
SERVER=${update_server}
GROUP=${update_group}
EOF

}

# Write the vm disk image to the target directory in the proper format
write_vm_disk() {
    if [[ $(_get_vm_opt PARTITIONED_IMG) -eq 1 ]]; then
        # unmount before creating block device images
        cleanup_mounts "${VM_TMP_ROOT}"
    fi

    local disk_format=$(_get_vm_opt DISK_FORMAT)
    info "Writing $disk_format image $(basename "${VM_DST_IMG}")"
    _write_${disk_format}_disk "${VM_TMP_IMG}" "${VM_DST_IMG}"
    VM_GENERATED_FILES+=( "${VM_DST_IMG}" )
}

_write_raw_disk() {
    mv "$1" "$2"
}

_write_qcow2_disk() {
    qemu-img convert -f raw "$1" -O qcow2 "$2"
}

_write_vmdk_ide_disk() {
    qemu-img convert -f raw "$1" -O vmdk -o adapter_type=ide "$2"
}

_write_vmdk_scsi_disk() {
    qemu-img convert -f raw "$1" -O vmdk -o adapter_type=lsilogic "$2"
}

# The cpio "disk" is a bit special,
# consists of a kernel+initrd not a block device
_write_cpio_disk() {
    local cpio_target="${VM_TMP_DIR}/rootcpio"
    local dst_dir=$(_dst_dir)
    local vmlinuz_name="$(_dst_name ".vmlinuz")"

    # The STATE partition and all of its bind mounts shouldn't be
    # packed into the squashfs image. Just ROOT and OEM.
    if mountpoint -q "${VM_TMP_ROOT}/media/state"; then
        sudo umount --all-targets "${VM_TMP_ROOT}/media/state"
    fi

    # Build the squashfs, embed squashfs into a gzipped cpio
    mkdir -p "${cpio_target}"
    pushd "${cpio_target}" >/dev/null
    sudo mksquashfs "${VM_TMP_ROOT}" ./newroot.squashfs
    echo ./newroot.squashfs | cpio -o -H newc | gzip > "$2"
    popd >/dev/null

    # Pull the kernel out of the root filesystem
    cp "${VM_TMP_ROOT}"/boot/vmlinuz "${dst_dir}/${vmlinuz_name}"
    VM_GENERATED_FILES+=( "${dst_dir}/${vmlinuz_name}" )
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
    local script="${dst_dir}/$(_src_to_dst_name "${src_name}" ".sh")"

    sed -e "s%^VM_NAME=.*%VM_NAME='${VM_NAME}'%" \
        -e "s%^VM_UUID=.*%VM_UUID='${VM_UUID}'%" \
        -e "s%^VM_IMAGE=.*%VM_IMAGE='${dst_name}'%" \
        -e "s%^VM_MEMORY=.*%VM_MEMORY='${vm_mem}'%" \
        "${BUILD_LIBRARY_DIR}/qemu_template.sh" > "${script}"
    checkbashisms --posix "${script}" || die
    chmod +x "${script}"

    cat >"${VM_README}" <<EOF
If you have qemu installed (or in the SDK), you can start the image with:
  cd path/to/image
  ./$(basename "${script}") -curses

If you need to use a different ssh key or different ssh port:
  ./$(basename "${script}") -a ~/.ssh/authorized_keys -p 2223 -- -curses

If you rather you can use the -nographic option instad of -curses. In this
mode you can switch from the vm to the qemu monitor console with: Ctrl-a c
See the qemu man page for more details on the monitor console.

SSH into that host with:
  ssh 127.0.0.1 -p 2222
EOF

    VM_GENERATED_FILES+=( "${script}" "${VM_README}" )
}

_write_pxe_conf() {
    local dst_name=$(basename "$VM_DST_IMG")
    local vmlinuz_name="$(_dst_name ".vmlinuz")"

    cat >"${VM_README}" <<EOF
If you have qemu installed (or in the SDK), you can start the image with:
  cd path/to/image

  qemu-kvm -m 1024 -kernel ${vmlinuz_name} -initrd ${dst_name} -append 'state=tmpfs: root=squashfs: sshkey="PUT AN SSH KEY HERE"'

EOF

    VM_GENERATED_FILES+=( "${VM_README}" )
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
cleanShutdown = "TRUE"
displayName = "${VM_NAME}"
ethernet0.addressType = "generated"
ethernet0.present = "TRUE"
floppy0.present = "FALSE"
guestOS = "other26xlinux-64"
memsize = "${vm_mem}"
powerType.powerOff = "soft"
powerType.powerOn = "hard"
powerType.reset = "hard"
powerType.suspend = "hard"
scsi0.present = "TRUE"
scsi0.virtualDev = "lsilogic"
scsi0:0.fileName = "${dst_name}"
scsi0:0.present = "TRUE"
sound.present = "FALSE"
usb.generic.autoconnect = "FALSE"
usb.present = "TRUE"
rtc.diffFromUTC = 0
EOF
    VM_GENERATED_FILES+=( "${vmx_path}" )
}

_write_vmware_zip_conf() {
    local src_name=$(basename "$VM_SRC_IMG")
    local dst_name=$(basename "$VM_DST_IMG")
    local dst_dir=$(dirname "$VM_DST_IMG")
    local vmx_path="${dst_dir}/$(_src_to_dst_name "${src_name}" ".vmx")"
    local vmx_file=$(basename "${vmx_path}")
    local zip="${dst_dir}/$(_src_to_dst_name "${src_name}" ".zip")"

    _write_vmx_conf "$1"

    # Move the disk/vmx to tmp, they will be zipped.
    mv "${VM_DST_IMG}" "${VM_TMP_DIR}/${dst_name}"
    mv "${vmx_path}" "${VM_TMP_DIR}/${vmx_file}"
    cat > "${VM_TMP_DIR}/insecure_ssh_key" <<EOF
-----BEGIN RSA PRIVATE KEY-----
MIIEogIBAAKCAQEA6NF8iallvQVp22WDkTkyrtvp9eWW6A8YVr+kz4TjGYe7gHzI
w+niNltGEFHzD8+v1I2YJ6oXevct1YeS0o9HZyN1Q9qgCgzUFtdOKLv6IedplqoP
kcmF0aYet2PkEDo3MlTBckFXPITAMzF8dJSIFo9D8HfdOV0IAdx4O7PtixWKn5y2
hMNG0zQPyUecp4pzC6kivAIhyfHilFR61RGL+GPXQ2MWZWFYbAGjyiYJnAmCP3NO
Td0jMZEnDkbUvxhMmBYSdETk1rRgm+R4LOzFUGaHqHDLKLX+FIPKcF96hrucXzcW
yLbIbEgE98OHlnVYCzRdK8jlqm8tehUc9c9WhQIBIwKCAQEA4iqWPJXtzZA68mKd
ELs4jJsdyky+ewdZeNds5tjcnHU5zUYE25K+ffJED9qUWICcLZDc81TGWjHyAqD1
Bw7XpgUwFgeUJwUlzQurAv+/ySnxiwuaGJfhFM1CaQHzfXphgVml+fZUvnJUTvzf
TK2Lg6EdbUE9TarUlBf/xPfuEhMSlIE5keb/Zz3/LUlRg8yDqz5w+QWVJ4utnKnK
iqwZN0mwpwU7YSyJhlT4YV1F3n4YjLswM5wJs2oqm0jssQu/BT0tyEXNDYBLEF4A
sClaWuSJ2kjq7KhrrYXzagqhnSei9ODYFShJu8UWVec3Ihb5ZXlzO6vdNQ1J9Xsf
4m+2ywKBgQD6qFxx/Rv9CNN96l/4rb14HKirC2o/orApiHmHDsURs5rUKDx0f9iP
cXN7S1uePXuJRK/5hsubaOCx3Owd2u9gD6Oq0CsMkE4CUSiJcYrMANtx54cGH7Rk
EjFZxK8xAv1ldELEyxrFqkbE4BKd8QOt414qjvTGyAK+OLD3M2QdCQKBgQDtx8pN
CAxR7yhHbIWT1AH66+XWN8bXq7l3RO/ukeaci98JfkbkxURZhtxV/HHuvUhnPLdX
3TwygPBYZFNo4pzVEhzWoTtnEtrFueKxyc3+LjZpuo+mBlQ6ORtfgkr9gBVphXZG
YEzkCD3lVdl8L4cw9BVpKrJCs1c5taGjDgdInQKBgHm/fVvv96bJxc9x1tffXAcj
3OVdUN0UgXNCSaf/3A/phbeBQe9xS+3mpc4r6qvx+iy69mNBeNZ0xOitIjpjBo2+
dBEjSBwLk5q5tJqHmy/jKMJL4n9ROlx93XS+njxgibTvU6Fp9w+NOFD/HvxB3Tcz
6+jJF85D5BNAG3DBMKBjAoGBAOAxZvgsKN+JuENXsST7F89Tck2iTcQIT8g5rwWC
P9Vt74yboe2kDT531w8+egz7nAmRBKNM751U/95P9t88EDacDI/Z2OwnuFQHCPDF
llYOUI+SpLJ6/vURRbHSnnn8a/XG+nzedGH5JGqEJNQsz+xT2axM0/W/CRknmGaJ
kda/AoGANWrLCz708y7VYgAtW2Uf1DPOIYMdvo6fxIB5i9ZfISgcJ/bbCUkFrhoH
+vq/5CIWxCPp0f85R4qxxQ5ihxJ0YDQT9Jpx4TMss4PSavPaBH3RXow5Ohe+bYoQ
NE5OgEXk2wVfZczCZpigBKbKZHNYcelXtTt/nP3rsCuGcM4h53s=
-----END RSA PRIVATE KEY-----
EOF
    chmod 600 "${VM_TMP_DIR}/insecure_ssh_key"

    zip --junk-paths "${zip}" \
        "${VM_TMP_DIR}/${dst_name}" \
        "${VM_TMP_DIR}/${vmx_file}" \
        "${VM_TMP_DIR}/insecure_ssh_key"

    cat > "${VM_README}" <<EOF
Use insecure_ssh_key in the zip for login access.
TODO: more instructions!
EOF

    # Replace list, not append, since we packaged up the disk image.
    VM_GENERATED_FILES=( "${zip}" "${VM_README}" )
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
            --output_ovf "$ovf"

    local ovf_name=$(basename "${ovf}")
    cat > "${VM_README}" <<EOF
Copy ${dst_name} and ${ovf_name} to a VirtualBox host and run:
VBoxManage import ${ovf_name}
EOF

    VM_GENERATED_FILES+=( "$ovf" "${VM_README}" )
}

_write_vagrant_conf() {
    local vm_mem="${1:-$(_get_vm_opt MEM)}"
    local src_name=$(basename "$VM_SRC_IMG")
    local dst_name=$(basename "$VM_DST_IMG")
    local dst_dir=$(dirname "$VM_DST_IMG")
    local ovf="${VM_TMP_DIR}/box.ovf"
    local vfile="${VM_TMP_DIR}/Vagrantfile"
    local box="${dst_dir}/$(_src_to_dst_name "${src_name}" ".box")"

    # Move the disk image to tmp, it won't be a final output file
    mv "${VM_DST_IMG}" "${VM_TMP_DIR}/${dst_name}"

    "${BUILD_LIBRARY_DIR}/virtualbox_ovf.sh" \
            --vm_name "$VM_NAME" \
            --disk_vmdk "${VM_TMP_DIR}/${dst_name}" \
            --memory_size "$vm_mem" \
            --output_ovf "$ovf" \
            --output_vagrant "$vfile"

    cat > "${VM_TMP_DIR}"/metadata.json <<EOF
{"provider": "virtualbox"}
EOF

    tar -czf "${box}" -C "${VM_TMP_DIR}" "box.ovf" "Vagrantfile" "${dst_name}" "metadata.json"

    cat > "${VM_README}" <<EOF
Vagrant >= 1.2.3 is required. Use something like the following to get started:
vagrant box add coreos path/to/$(basename "${box}")
vagrant init coreos
vagrant up
vagrant ssh

You will get a warning about "No guest additions were detected...",
this is expected and should be ignored. SSH should work just dandy.
EOF

    # Replace list, not append, since we packaged up the disk image.
    VM_GENERATED_FILES=( "${box}" "${VM_README}" )
}

_write_vagrant_vmware_fusion_conf() {
    local vm_mem="${1:-$(_get_vm_opt MEM)}"
    local src_name=$(basename "$VM_SRC_IMG")
    local dst_name=$(basename "$VM_DST_IMG")
    local dst_dir=$(dirname "$VM_DST_IMG")
    local vmx_path="${dst_dir}/$(_src_to_dst_name "${src_name}" ".vmx")"
    local vmx_file=$(basename "${vmx_path}")
    local vfile="${VM_TMP_DIR}/Vagrantfile"
    local box="${dst_dir}/$(_src_to_dst_name "${src_name}" ".box")"

    # Move the disk image to tmp, it won't be a final output file
    mv "${VM_DST_IMG}" "${VM_TMP_DIR}/${dst_name}"

    _write_vmx_conf ${vm_mem}
    "${BUILD_LIBRARY_DIR}/virtualbox_ovf.sh" \
            --vm_name "$VM_NAME" \
            --disk_vmdk "${VM_TMP_DIR}/${dst_name}" \
            --memory_size "$vm_mem" \
            --output_vagrant "$vfile"

    cat > "${VM_TMP_DIR}"/metadata.json <<EOF
{"provider": "vmware_fusion"}
EOF

    mv "${vmx_path}" "${VM_TMP_DIR}/"

    tar -czf "${box}" -C "${VM_TMP_DIR}" "Vagrantfile" "${dst_name}" \
        "${vmx_file}" "metadata.json"

    cat > "${VM_README}" <<EOF
Vagrant master (unreleased) currently has full CoreOS support. In the meantime, you may encounter an error about networking that can be ignored
vagrant box add coreos path/to/$(basename "${box}")
vagrant init coreos
vagrant up
vagrant ssh

You will get a warning about "No guest additions were detected...",
this is expected and should be ignored. SSH should work just dandy.
EOF

    # Replace list, not append, since we packaged up the disk image.
    VM_GENERATED_FILES=( "${box}" "${VM_README}" )
}

_write_gce_conf() {
    local src_name=$(basename "$VM_SRC_IMG")
    local dst_dir=$(dirname "$VM_DST_IMG")
    local tar_path="${dst_dir}/$(_src_to_dst_name "${src_name}" ".tar.gz")"

    mv "${VM_DST_IMG}" "${VM_TMP_DIR}/disk.raw"
    tar -czf "${tar_path}" -C "${VM_TMP_DIR}" "disk.raw"
    VM_GENERATED_FILES=( "${tar_path}" )
}

vm_cleanup() {
    info "Cleaning up temporary files"
    if mountpoint -q "${VM_TMP_ROOT}"; then
        cleanup_mounts "${VM_TMP_ROOT}"
    fi
    sudo rm -rf "${VM_TMP_DIR}"
}

vm_upload() {
    local digests="$(_dst_dir)/$(_dst_name .DIGESTS)"
    upload_image -d "${digests}" "${VM_GENERATED_FILES[@]}"

    [[ -e "${digests}" ]] || return 0

    # FIXME(marineam): Temporary alternate name for .DIGESTS
    # This used to be derived from the first file listed in
    # ${VM_GENERATED_FILES[@]}", usually $VM_DST_IMG or similar.
    # Since not everything actually uploads $VM_DST_IMG this was not very
    # consistent and relying on ordering was breakable.
    # Now the common prefix, output by $(_dst_name) is used above.
    # Some download/install scripts may still refer to the old name.
    local uploaded legacy_uploaded
    for uploaded in "${VM_GENERATED_FILES[@]}"; do
        if [[ "${uploaded}" == "${VM_DST_IMG}" ]]; then
            legacy_uploaded="$(_dst_dir)/$(basename ${VM_DST_IMG})"
            break
        fi
    done

    # Since depending on the ordering of $VM_GENERATED_FILES is brittle only
    # use it if $VM_DST_IMG isn't included in the uploaded files.
    if [[ -z "${legacy_uploaded}" ]]; then
        legacy_uploaded="${VM_GENERATED_FILES[0]}"
    fi

    # If upload_images compressed $legacy_uploaded be sure to add .bz2
    if [[ "${legacy_uploaded}" =~ \.(img|bin|vdi|vmdk)$ ]]; then
        legacy_uploaded+="${IMAGE_ZIPEXT}"
    fi

    local legacy_digests="${legacy_uploaded}.DIGESTS"
    [[ "${legacy_digests}" != "${digests}" ]] || return 0

    local legacy_uploads=( "${legacy_digests}" )
    cp "${digests}" "${legacy_digests}"
    if [[ -e "${digests}.asc" ]]; then
        legacy_uploads+=( "${legacy_digests}.asc" )
        cp "${digests}.asc" "${legacy_digests}.asc"
    fi

    local def_upload_path="${UPLOAD_ROOT}/${BOARD}/${COREOS_VERSION_STRING}"
    upload_files "$(_dst_name)" "${def_upload_path}" "" "${legacy_uploads[@]}"
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
