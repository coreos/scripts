# CoreOS Roadmap

This is a high level overview of what we expect to achieve in CoreOS in
the future. For details on the direction of individual projects refer to
their individual roadmaps:

 - [rkt](https://github.com/coreos/rkt/blob/master/ROADMAP.md)
 - [etcd](https://github.com/coreos/etcd/milestones)
 - [mantle](https://github.com/coreos/mantle/blob/master/ROADMAP.md)

## Q2 2015

 - Initial release of [ignition](https://github.com/coreos/ignition/)
 - Complete secure/verified boot on UEFI hardware.
   - Boot with full chain of trust through up to user configuration.
   - Prototype providing trusted user configuration via UEFI variables
     and integrate with ignition.
 - Complete initial automated test framework, kola.
 - Support using the SDK as a stand-alone container.
   - Primary motivation is easier deployment of CI systems for the OS.
   - Secondary motivation is to support using the SDK on CoreOS itself.
   - Requires running `repo init` *after* entering the SDK.
   - Should support using loop devices without needing udev.
 - Begin development on a new minimal image type, `amd64-rkt`.
   - Includes only what is required to provision a machine via ignition
     and launch rkt containers. Rest of user space lives in containers.
 - Research improvements to overlayfs and alternatives such as reflinks.

## Q3 2015

 - Release new `amd64-rkt` images as new recommended flavor of CoreOS.
   Updates and support for the existing `amd64-usr` images will
   continue under the name *CoreOS Classic*.
 - Initial ARM64 port.
   - Should be able to boot a basic image in QEMU and on hardware.
