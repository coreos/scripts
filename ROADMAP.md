# CoreOS Roadmap

This is a high level overview of what we expect to achieve in CoreOS in
the future. For details on the direction of individual projects refer to
their individual roadmaps:

 - [rkt](https://github.com/coreos/rkt/blob/master/ROADMAP.md)
 - [etcd](https://github.com/coreos/etcd/milestones)
 - [mantle](https://github.com/coreos/mantle/blob/master/ROADMAP.md)

## July 1 - Aug 15

 - Initial release of [ignition](https://github.com/coreos/ignition/)
 - Complete secure/verified boot on UEFI hardware.
   - Boot with full chain of trust through up to user configuration.
 - Experimental support of SELinux support in CoreOS and rkt.
 - Begin building releases via new CI pipeline, using kola to test
   releases. Use Jenkins for managing builds and tests.
 - Replace current Google Cloud Storage download site with a new system
   that supports SSL and is (at least usually) available in China.
   - Makes skipping GPG validation of images less problematic.
   - Enables us to begin supporting deployments in China.
 - Initial ARM64 port.
   - Should be able to boot a basic image in QEMU and on hardware.

## Aug 16 - Sep 30

## Ignition
 - Provision bare metal and EC2 systems
 - Publish new documentation on CoreOS website for bare metal/EC2

## Release Tooling (plume)
 - Images uploaded and HTML indexes automatically generated in one command.
 - EC2 AMIs created remotely via API, AWS cli tools not required.
 - GCE images created and automatically garbage collected.

## CI

### Goals
 - Run comprehensive cluster-wide tests on release candidate OS images in a CI system, ensuring high quality releases.
 - Tests are executed by `kola` testing framework in the [mantle](https://github.com/coreos/mantle) repo.
 - Tests triggered in CI system by master image uploads from buildbot.

### Kola
 - Primary platform is QEMU. GCE is also supported and potentionally other platforms/providers in the future.
 - Tests must be comprehensive enough to verify that images are ready for release to a CoreOS channel.

### CI Tool
 - The currently proposed CI Tool is [Jenkins](https://jenkins-ci.org/).
 - The CI Tool needs a way to learn about new images. Currently, this may involve polling a URL.
   - builtbot could have a hook added to notify Jenkins about new image uploads.

## Unscheduled

 - Begin development on a new minimal image type, `amd64-rkt`.
   - Includes only what is required to provision a machine via ignition
     and launch rkt containers. Rest of user space lives in containers.
 - Release new `amd64-rkt` images as new recommended flavor of CoreOS.
   Updates and support for the existing `amd64-usr` images will
   continue under the name *CoreOS Classic*.
 - Add support for our gptprio boot scheme to systemd:
   - systemd-nspawn can boot CoreOS disk images as a container.
   - bootctl or similar tool can select between partitions.
   - coreos-setgoodroot converted to a new tool and stand-alone service.
   - Optional: support gptprio in systemd's UEFI bootloader.
 - Support OEM updates on CoreOS via rkt and strudel.
 - Support using the SDK as a stand-alone container.
   - Primary motivation is easier deployment of [CI](#CI) systems for the OS.
   - Secondary motivation is to support using the SDK on CoreOS itself.
   - Requires running `repo init` *after* entering the SDK.
   - Should support using loop devices without needing udev.
   
