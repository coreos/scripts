#!/bin/sh

SCRIPT_DIR="`dirname "$0"`"
VM_NAME=
VM_IMAGE=
VM_MEMORY=
VM_NCPUS="`grep -c ^processor /proc/cpuinfo`"
SSH_PORT=2222
USAGE="Usage: $0 [-p PORT] [--] [qemu options...]
Options:
    -p PORT     The port on localhost to map to the VM's sshd. [2222]
    -h          this ;-)

QEMU wrapper script for a VM that is compatible with Xen:
 - No x2apic, everything APIC related breaks when it is on.
 - No virtio, simply does not work whatsoever under Xen.

Any arguments after -p will be passed through to qemu, -- may be
used as an explicit separator. See the qemu(1) man page for more details.
"

while [ $# -ge 1 ]; do
    case "$1" in
        -p|-ssh-port)
            SSH_PORT="$2"
            shift 2 ;;
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

qemu-system-x86_64 \
    -machine accel=kvm \
    -cpu host,-x2apic \
    -smp "${VM_NCPUS}" \
    -name "$VM_NAME" \
    -m ${VM_MEMORY} \
    -net nic,vlan=0,model=e1000 \
    -net user,vlan=0,hostfwd=tcp::"${SSH_PORT}"-:22,hostname="${VM_NAME}" \
    -drive if=scsi,file="${SCRIPT_DIR}/${VM_IMAGE}" \
    "$@"
exit $?
