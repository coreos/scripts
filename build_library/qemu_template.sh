#!/bin/sh

SCRIPT_DIR="`dirname "$0"`"
VM_BOARD=
VM_NAME=
VM_UUID=
VM_IMAGE=
VM_KERNEL=
VM_INITRD=
VM_MEMORY=
VM_CDROM=
VM_PFLASH_RO=
VM_PFLASH_RW=
VM_NCPUS="`grep -c ^processor /proc/cpuinfo`"
SSH_PORT=2222
SSH_KEYS=""
CLOUD_CONFIG_FILE=""
IGNITION_CONFIG_FILE=""
CONFIG_IMAGE=""
SAFE_ARGS=0
USAGE="Usage: $0 [-a authorized_keys] [--] [qemu options...]
Options:
    -i FILE     File containing an Ignition config
    -u FILE     Cloudinit user-data as either a cloud config or script.
    -c FILE     Config drive as an iso or fat filesystem image.
    -a FILE     SSH public keys for login access. [~/.ssh/id_{dsa,rsa}.pub]
    -p PORT     The port on localhost to map to the VM's sshd. [2222]
    -s          Safe settings: single simple cpu and no KVM.
    -h          this ;-)

This script is a wrapper around qemu for starting CoreOS virtual machines.
The -a option may be used to specify a particular ssh public key to give
login access to. If -a is not provided ~/.ssh/id_{dsa,rsa}.pub is used.
If no public key is provided or found the VM will still boot but you may
be unable to login unless you built the image yourself after setting a
password for the core user with the 'set_shared_user_password.sh' script.

Any arguments after -a and -p will be passed through to qemu, -- may be
used as an explicit separator. See the qemu(1) man page for more details.
"

die(){
	echo "${1}"
	exit 1
}

check_conflict() {
    if [ -n "${CLOUD_CONFIG_FILE}${CONFIG_IMAGE}${SSH_KEYS}" ]; then
        echo "The -u -c and -a options cannot be combined!" >&2
        exit 1
    fi
}

while [ $# -ge 1 ]; do
    case "$1" in
        -i|-ignition-config)
            IGNITION_CONFIG_FILE="$2"
            shift 2 ;;
        -u|-user-data)
            check_conflict
            CLOUD_CONFIG_FILE="$2"
            shift 2 ;;
        -c|-config-drive)
            check_conflict
            CONFIG_IMAGE="$2"
            shift 2 ;;
        -a|-authorized-keys)
            check_conflict
            SSH_KEYS="$2"
            shift 2 ;;
        -p|-ssh-port)
            SSH_PORT="$2"
            shift 2 ;;
        -s|-safe)
            SAFE_ARGS=1
            shift ;;
        -v|-verbose)
            set -x
            shift ;;
        -h|-help|--help)
            echo "$USAGE"
            exit ;;
        --)
            shift
            break ;;
        *)
            break ;;
    esac
done


find_ssh_keys() {
    if [ -S "$SSH_AUTH_SOCK" ]; then
        ssh-add -L
    fi
    for default_key in ~/.ssh/id_*.pub; do
        if [ ! -f "$default_key" ]; then
            continue
        fi
        cat "$default_key"
    done
}

write_ssh_keys() {
    echo "#cloud-config"
    echo "ssh_authorized_keys:"
    sed -e 's/^/ - /'
}


if [ -z "${CONFIG_IMAGE}" ]; then
    CONFIG_DRIVE=$(mktemp -t -d coreos-configdrive.XXXXXXXXXX)
    if [ $? -ne 0 ] || [ ! -d "$CONFIG_DRIVE" ]; then
        echo "$0: mktemp -d failed!" >&2
        exit 1
    fi
    trap "rm -rf '$CONFIG_DRIVE'" EXIT
    mkdir -p "${CONFIG_DRIVE}/openstack/latest"


    if [ -n "$SSH_KEYS" ]; then
        if [ ! -f "$SSH_KEYS" ]; then
            echo "$0: SSH keys file not found: $SSH_KEYS" >&2
            exit 1
        fi
        SSH_KEYS_TEXT=$(cat "$SSH_KEYS")
        if [ $? -ne 0 ] || [ -z "$SSH_KEYS_TEXT" ]; then
            echo "$0: Failed to read SSH keys from $SSH_KEYS" >&2
            exit 1
        fi
        echo "$SSH_KEYS_TEXT" | write_ssh_keys > \
            "${CONFIG_DRIVE}/openstack/latest/user_data"
    elif [ -n "${CLOUD_CONFIG_FILE}" ]; then
        cp "${CLOUD_CONFIG_FILE}" "${CONFIG_DRIVE}/openstack/latest/user_data"
        if [ $? -ne 0 ]; then
            echo "$0: Failed to copy cloudinit file from $CLOUD_CONFIG_FILE" >&2
            exit 1
        fi
    else
        find_ssh_keys | write_ssh_keys > \
            "${CONFIG_DRIVE}/openstack/latest/user_data"
    fi
fi

# Start assembling our default command line arguments
if [ "${SAFE_ARGS}" -eq 1 ]; then
    # Disable KVM, for testing things like UEFI which don't like it
    set -- -machine accel=tcg "$@"
else
    case "${VM_BOARD}+$(uname -m)" in
        amd64-usr+x86_64)
            # Emulate the host CPU closely in both features and cores.
            set -- -machine accel=kvm -cpu host -smp "${VM_NCPUS}" "$@" ;;
        amd64-usr+*)
            set -- -machine pc-q35-2.8 -cpu kvm64 -smp 1 -nographic "$@" ;;
        arm64-usr+aarch64)
            set -- -machine virt,accel=kvm,gic-version=3 -cpu host -smp "${VM_NCPUS}" -nographic "$@" ;;
        arm64-usr+*)
            set -- -machine virt -cpu cortex-a57 -smp 1 -nographic "$@" ;;
        *)
            die "Unsupported arch" ;;
    esac
fi

# ${CONFIG_DRIVE} or ${CONFIG_IMAGE} will be mounted in CoreOS as /media/configdrive
if [ -n "${CONFIG_DRIVE}" ]; then
    set -- \
        -fsdev local,id=conf,security_model=none,readonly,path="${CONFIG_DRIVE}" \
        -device virtio-9p-pci,fsdev=conf,mount_tag=config-2 "$@"
fi

if [ -n "${CONFIG_IMAGE}" ]; then
    set -- -drive if=virtio,file="${CONFIG_IMAGE}" "$@"
fi

if [ -n "${VM_IMAGE}" ]; then
    case "${VM_BOARD}" in
        amd64-usr)
            set -- -drive if=virtio,file="${SCRIPT_DIR}/${VM_IMAGE}" "$@" ;;
        arm64-usr)
            set -- -drive if=none,id=blk,file="${SCRIPT_DIR}/${VM_IMAGE}" \
            -device virtio-blk-device,drive=blk "$@"
            ;;
        *) die "Unsupported arch" ;;
    esac
fi

if [ -n "${VM_KERNEL}" ]; then
    set -- -kernel "${SCRIPT_DIR}/${VM_KERNEL}" "$@"
fi

if [ -n "${VM_INITRD}" ]; then
    set -- -initrd "${SCRIPT_DIR}/${VM_INITRD}" "$@"
fi

if [ -n "${VM_UUID}" ]; then
    set -- -uuid "$VM_UUID" "$@"
fi

if [ -n "${VM_CDROM}" ]; then
    set -- -boot order=d \
	-drive file="${SCRIPT_DIR}/${VM_CDROM}",media=cdrom,format=raw "$@"
fi

if [ -n "${VM_PFLASH_RO}" ] && [ -n "${VM_PFLASH_RW}" ]; then
    set -- \
        -drive if=pflash,file="${SCRIPT_DIR}/${VM_PFLASH_RO}",format=raw,readonly \
        -drive if=pflash,file="${SCRIPT_DIR}/${VM_PFLASH_RW}",format=raw "$@"
fi

if [ -n "${IGNITION_CONFIG_FILE}" ]; then
    set -- -fw_cfg name=opt/com.coreos/config,file="${IGNITION_CONFIG_FILE}" "$@"
fi

case "${VM_BOARD}" in
    amd64-usr)
        # Default to KVM, fall back on full emulation
        qemu-system-x86_64 \
            -name "$VM_NAME" \
            -m ${VM_MEMORY} \
            -net nic,vlan=0,model=virtio \
            -net user,vlan=0,hostfwd=tcp::"${SSH_PORT}"-:22,hostname="${VM_NAME}" \
            -object rng-random,filename=/dev/urandom,id=rng0 -device virtio-rng-pci,rng=rng0 \
            "$@"
        ;;
    arm64-usr)
        qemu-system-aarch64 \
            -name "$VM_NAME" \
            -m ${VM_MEMORY} \
            -netdev user,id=eth0,hostfwd=tcp::"${SSH_PORT}"-:22,hostname="${VM_NAME}" \
            -device virtio-net-device,netdev=eth0 \
            -object rng-random,filename=/dev/urandom,id=rng0 -device virtio-rng-pci,rng=rng0 \
            "$@"
        ;;
    *) die "Unsupported arch" ;;
esac

exit $?
