#!/bin/sh

SCRIPT_DIR="`dirname "$0"`"
VM_NAME=
VM_UUID=
VM_IMAGE=
VM_KERNEL=
VM_INITRD=
VM_MEMORY=
VM_CDROM=
VM_NCPUS="`grep -c ^processor /proc/cpuinfo`"
SSH_PORT=2222
SSH_KEYS=""
SAFE_ARGS=0
USAGE="Usage: $0 [-a authorized_keys] [--] [qemu options...]
Options:
    -a FILE     SSH public keys for login access. [~/.ssh/id_{dsa,rsa}.pub]
    -p PORT     The port on localhost to map to the VM's sshd. [2222]
    -s          Safe settings: single simple cpu, ide disks.
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

while [ $# -ge 1 ]; do
    case "$1" in
        -a|-authorized-keys)
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


METADATA=$(mktemp -t -d coreos-meta-data.XXXXXXXXXX)
if [ $? -ne 0 ] || [ ! -d "$METADATA" ]; then
    echo "$0: mktemp -d failed!" >&2
    exit 1
fi
trap "rm -rf '$METADATA'" EXIT


# Do our best to create an authorized_keys file
if [ -n "$SSH_KEYS" ]; then
    if [ ! -f "$SSH_KEYS" ]; then
        echo "$0: SSH keys file not found: $SSH_KEYS" >&2
        exit 1
    elif ! cp "$SSH_KEYS" "${METADATA}/authorized_keys"; then
        echo "$0: Failed to copy SSH keys from $SSH_KEYS" >&2
        exit 1
    fi
else
    # Nothing provided, try fetching from ssh-agent and the local fs
    if [ -S "$SSH_AUTH_SOCK" ]; then
        ssh-add -L >> "${METADATA}/authorized_keys"
    fi
    for default_key in ~/.ssh/id_*.pub; do
        if [ ! -f "$default_key" ]; then
            continue
        fi
        cat "$default_key" >> "${METADATA}/authorized_keys"
    done
fi

# Start assembling our default command line arguments
if [ "${SAFE_ARGS}" -eq 1 ]; then
    disk_type="ide"
else
    disk_type="virtio"
    # Emulate the host CPU closely in both features and cores.
    set -- -cpu host -smp "${VM_NCPUS}" "$@"
fi

if [ -n "${VM_IMAGE}" ]; then
    set -- -drive if=${disk_type},file="${SCRIPT_DIR}/${VM_IMAGE}" "$@"
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
    set -- -cdrom "$VM_CDROM" "$@"
fi

# Default to KVM, fall back on full emulation
# ${METADATA} will be mounted in CoreOS as /media/metadata
qemu-system-x86_64 \
    -name "$VM_NAME" \
    -m ${VM_MEMORY} \
    -machine accel=kvm:tcg \
    -net nic,vlan=0,model=virtio \
    -net user,vlan=0,hostfwd=tcp::"${SSH_PORT}"-:22 \
    -fsdev local,id=metadata,security_model=none,readonly,path="${METADATA}" \
    -device virtio-9p-pci,fsdev=metadata,mount_tag=metadata \
    "$@"
RET=$?


# Cleanup!
rm -rf "${METADATA}"
trap - EXIT
exit ${RET}
