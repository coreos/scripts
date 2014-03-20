#!/bin/bash

# Mostly this just copies the below XML, but inserting random MAC address
# and UUID strings, and other options as appropriate.

SCRIPT_ROOT=$(readlink -f $(dirname "$0")/..)
. "${SCRIPT_ROOT}/common.sh" || exit 1

DEFINE_string vm_name "CoreOS" "Name for this VM"
DEFINE_string disk_vmdk "" "Disk image to reference, only basename is used."
DEFINE_integer memory_size 1024 "Memory size in MB"
DEFINE_string output_ovf "" "Path to write ofv file to, required."
DEFINE_string output_vagrant "" "Path to write Vagrantfile to, optional."

# Parse command line
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

# Die on any errors.
switch_to_strict_mode

if [[ ! -e "${FLAGS_disk_vmdk}" ]]; then
    echo "No such disk image '${FLAGS_disk_vmdk}'" >&2
    exit 1
fi

DISK_NAME=$(basename "${FLAGS_disk_vmdk}")
DISK_UUID=$(uuidgen)
DISK_SIZE_BYTES=$(qemu-img info -f vmdk "${FLAGS_disk_vmdk}" \
    | gawk 'match($0, /^virtual size:.*\(([0-9]+) bytes\)/, a) {print a[1]}')

if [[ -z "${DISK_SIZE_BYTES}" ]]; then
    echo "Unable to determine virtual size of ${FLAGS_disk_vmdk}" >&2
    exit 1
fi

# Generate random MAC addresses just as VirtualBox does, the format is
# their assigned prefix for the first 3 bytes followed by 3 random bytes.
VBOX_MAC_PREFIX=080027
macgen() {
    hexdump -n3 -e "\"${VBOX_MAC_PREFIX}%06X\n\"" /dev/urandom
}

# Used in both the ovf and Vagrantfile
PRIMARY_MAC=$(macgen)

# Date format as used in ovf
datez() {
    date -u "+%Y-%m-%dT%H:%M:%SZ"
}

if [[ -n "${FLAGS_output_vagrant}" ]]; then
    cat >"${FLAGS_output_vagrant}" <<EOF
if Vagrant::VERSION < "1.2.3"
  raise "Need at least vagrant version 1.2.3, please update"
end

Vagrant.configure("2") do |config|
  config.vm.base_mac = "${PRIMARY_MAC}"

  # SSH in as the default 'core' user, it has the vagrant ssh key.
  config.ssh.username = "core"

  # Disable the base shared folder, guest additions are unavailable.
  config.vm.synced_folder ".", "/vagrant", disabled: true
end
EOF
fi

if [[ -n "${FLAGS_output_ovf}" ]]; then
    cat >"${FLAGS_output_ovf}" <<EOF
<?xml version="1.0"?>
<Envelope ovf:version="1.0" xml:lang="en-US" xmlns="http://schemas.dmtf.org/ovf/envelope/1" xmlns:ovf="http://schemas.dmtf.org/ovf/envelope/1" xmlns:rasd="http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/CIM_ResourceAllocationSettingData" xmlns:vssd="http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/CIM_VirtualSystemSettingData" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:vbox="http://www.virtualbox.org/ovf/machine">
  <References>
    <File ovf:href="${DISK_NAME}" ovf:id="file1"/>
  </References>
  <DiskSection>
    <Info>List of the virtual disks used in the package</Info>
    <Disk ovf:capacity="${DISK_SIZE_BYTES}" ovf:diskId="vmdisk1" ovf:fileRef="file1" ovf:format="http://www.vmware.com/interfaces/specifications/vmdk.html#streamOptimized" vbox:uuid="${DISK_UUID}"/>
  </DiskSection>
  <NetworkSection>
    <Info>Logical networks used in the package</Info>
    <Network ovf:name="NAT">
      <Description>Logical network used by this appliance.</Description>
    </Network>
  </NetworkSection>
  <VirtualSystem ovf:id="${FLAGS_vm_name}">
    <Info>A virtual machine</Info>
    <OperatingSystemSection ovf:id="100">
      <Info>The kind of installed guest operating system</Info>
      <Description>Linux26_64</Description>
      <vbox:OSType ovf:required="false">Linux26_64</vbox:OSType>
    </OperatingSystemSection>
    <VirtualHardwareSection>
      <Info>Virtual hardware requirements for a virtual machine</Info>
      <System>
        <vssd:ElementName>Virtual Hardware Family</vssd:ElementName>
        <vssd:InstanceID>0</vssd:InstanceID>
        <vssd:VirtualSystemIdentifier>${FLAGS_vm_name}</vssd:VirtualSystemIdentifier>
        <vssd:VirtualSystemType>virtualbox-2.2</vssd:VirtualSystemType>
      </System>
      <Item>
        <rasd:Caption>1 virtual CPU</rasd:Caption>
        <rasd:Description>Number of virtual CPUs</rasd:Description>
        <rasd:ElementName>1 virtual CPU</rasd:ElementName>
        <rasd:InstanceID>1</rasd:InstanceID>
        <rasd:ResourceType>3</rasd:ResourceType>
        <rasd:VirtualQuantity>1</rasd:VirtualQuantity>
      </Item>
      <Item>
        <rasd:AllocationUnits>MegaBytes</rasd:AllocationUnits>
        <rasd:Caption>${FLAGS_memory_size} MB of memory</rasd:Caption>
        <rasd:Description>Memory Size</rasd:Description>
        <rasd:ElementName>${FLAGS_memory_size} MB of memory</rasd:ElementName>
        <rasd:InstanceID>2</rasd:InstanceID>
        <rasd:ResourceType>4</rasd:ResourceType>
        <rasd:VirtualQuantity>${FLAGS_memory_size}</rasd:VirtualQuantity>
      </Item>
      <Item>
        <rasd:Address>0</rasd:Address>
        <rasd:Caption>ideController0</rasd:Caption>
        <rasd:Description>IDE Controller</rasd:Description>
        <rasd:ElementName>ideController0</rasd:ElementName>
        <rasd:InstanceID>3</rasd:InstanceID>
        <rasd:ResourceSubType>PIIX4</rasd:ResourceSubType>
        <rasd:ResourceType>5</rasd:ResourceType>
      </Item>
      <Item>
        <rasd:Address>1</rasd:Address>
        <rasd:Caption>ideController1</rasd:Caption>
        <rasd:Description>IDE Controller</rasd:Description>
        <rasd:ElementName>ideController1</rasd:ElementName>
        <rasd:InstanceID>4</rasd:InstanceID>
        <rasd:ResourceSubType>PIIX4</rasd:ResourceSubType>
        <rasd:ResourceType>5</rasd:ResourceType>
      </Item>
      <Item>
        <rasd:AutomaticAllocation>true</rasd:AutomaticAllocation>
        <rasd:Caption>Ethernet adapter on 'NAT'</rasd:Caption>
        <rasd:Connection>NAT</rasd:Connection>
        <rasd:ElementName>Ethernet adapter on 'NAT'</rasd:ElementName>
        <rasd:InstanceID>5</rasd:InstanceID>
        <rasd:ResourceSubType>E1000</rasd:ResourceSubType>
        <rasd:ResourceType>10</rasd:ResourceType>
      </Item>
      <Item>
        <rasd:AddressOnParent>0</rasd:AddressOnParent>
        <rasd:Caption>disk1</rasd:Caption>
        <rasd:Description>Disk Image</rasd:Description>
        <rasd:ElementName>disk1</rasd:ElementName>
        <rasd:HostResource>/disk/vmdisk1</rasd:HostResource>
        <rasd:InstanceID>6</rasd:InstanceID>
        <rasd:Parent>3</rasd:Parent>
        <rasd:ResourceType>17</rasd:ResourceType>
      </Item>
    </VirtualHardwareSection>
    <vbox:Machine ovf:required="false" version="1.12-linux" uuid="{$(uuidgen)}" name="${FLAGS_vm_name}" OSType="Linux26_64" snapshotFolder="Snapshots" lastStateChange="$(datez)">
      <ovf:Info>Complete VirtualBox machine configuration in VirtualBox format</ovf:Info>
      <Hardware version="2">
        <CPU count="1" hotplug="false">
          <HardwareVirtEx enabled="true" exclusive="true"/>
          <HardwareVirtExNestedPaging enabled="true"/>
          <HardwareVirtExVPID enabled="true"/>
          <PAE enabled="true"/>
          <HardwareVirtExLargePages enabled="false"/>
          <HardwareVirtForce enabled="false"/>
        </CPU>
        <Memory RAMSize="${FLAGS_memory_size}" PageFusion="false"/>
        <HID Pointing="PS2Mouse" Keyboard="PS2Keyboard"/>
        <HPET enabled="false"/>
        <Chipset type="PIIX3"/>
        <Boot>
          <Order position="1" device="HardDisk"/>
          <Order position="2" device="DVD"/>
          <Order position="3" device="None"/>
          <Order position="4" device="None"/>
        </Boot>
        <Display VRAMSize="8" monitorCount="1" accelerate3D="false" accelerate2DVideo="false"/>
        <VideoRecording enabled="false" file="Test.webm" horzRes="640" vertRes="480"/>
        <RemoteDisplay enabled="false" authType="Null"/>
        <BIOS>
          <ACPI enabled="true"/>
          <IOAPIC enabled="true"/>
          <Logo fadeIn="true" fadeOut="true" displayTime="0"/>
          <BootMenu mode="MessageAndMenu"/>
          <TimeOffset value="0"/>
          <PXEDebug enabled="false"/>
        </BIOS>
        <USBController enabled="false" enabledEhci="false"/>
        <Network>
          <Adapter slot="0" enabled="true" MACAddress="${PRIMARY_MAC}" cable="true" speed="0" type="82540EM">
            <DisabledModes/>
            <NAT>
              <DNS pass-domain="true" use-proxy="false" use-host-resolver="false"/>
              <Alias logging="false" proxy-only="false" use-same-ports="false"/>
            </NAT>
          </Adapter>
          <Adapter slot="1" enabled="false" MACAddress="$(macgen)" cable="true" speed="0" type="82540EM">
            <DisabledModes>
              <NAT>
                <DNS pass-domain="true" use-proxy="false" use-host-resolver="false"/>
                <Alias logging="false" proxy-only="false" use-same-ports="false"/>
              </NAT>
            </DisabledModes>
          </Adapter>
          <Adapter slot="2" enabled="false" MACAddress="$(macgen)" cable="true" speed="0" type="82540EM">
            <DisabledModes>
              <NAT>
                <DNS pass-domain="true" use-proxy="false" use-host-resolver="false"/>
                <Alias logging="false" proxy-only="false" use-same-ports="false"/>
              </NAT>
            </DisabledModes>
          </Adapter>
          <Adapter slot="3" enabled="false" MACAddress="$(macgen)" cable="true" speed="0" type="82540EM">
            <DisabledModes>
              <NAT>
                <DNS pass-domain="true" use-proxy="false" use-host-resolver="false"/>
                <Alias logging="false" proxy-only="false" use-same-ports="false"/>
              </NAT>
            </DisabledModes>
          </Adapter>
          <Adapter slot="4" enabled="false" MACAddress="$(macgen)" cable="true" speed="0" type="82540EM">
            <DisabledModes>
              <NAT>
                <DNS pass-domain="true" use-proxy="false" use-host-resolver="false"/>
                <Alias logging="false" proxy-only="false" use-same-ports="false"/>
              </NAT>
            </DisabledModes>
          </Adapter>
          <Adapter slot="5" enabled="false" MACAddress="$(macgen)" cable="true" speed="0" type="82540EM">
            <DisabledModes>
              <NAT>
                <DNS pass-domain="true" use-proxy="false" use-host-resolver="false"/>
                <Alias logging="false" proxy-only="false" use-same-ports="false"/>
              </NAT>
            </DisabledModes>
          </Adapter>
          <Adapter slot="6" enabled="false" MACAddress="$(macgen)" cable="true" speed="0" type="82540EM">
            <DisabledModes>
              <NAT>
                <DNS pass-domain="true" use-proxy="false" use-host-resolver="false"/>
                <Alias logging="false" proxy-only="false" use-same-ports="false"/>
              </NAT>
            </DisabledModes>
          </Adapter>
          <Adapter slot="7" enabled="false" MACAddress="$(macgen)" cable="true" speed="0" type="82540EM">
            <DisabledModes>
              <NAT>
                <DNS pass-domain="true" use-proxy="false" use-host-resolver="false"/>
                <Alias logging="false" proxy-only="false" use-same-ports="false"/>
              </NAT>
            </DisabledModes>
          </Adapter>
        </Network>
        <UART>
          <Port slot="0" enabled="false" IOBase="0x3f8" IRQ="4" hostMode="Disconnected"/>
          <Port slot="1" enabled="false" IOBase="0x2f8" IRQ="3" hostMode="Disconnected"/>
        </UART>
        <LPT>
          <Port slot="0" enabled="false" IOBase="0x378" IRQ="7"/>
          <Port slot="1" enabled="false" IOBase="0x378" IRQ="7"/>
        </LPT>
        <AudioAdapter controller="AC97" driver="Pulse" enabled="false"/>
        <RTC localOrUTC="local"/>
        <SharedFolders/>
        <Clipboard mode="Disabled"/>
        <DragAndDrop mode="Disabled"/>
        <IO>
          <IoCache enabled="true" size="5"/>
          <BandwidthGroups/>
        </IO>
        <HostPci>
          <Devices/>
        </HostPci>
        <EmulatedUSB>
          <CardReader enabled="false"/>
        </EmulatedUSB>
        <Guest memoryBalloonSize="0"/>
        <GuestProperties/>
      </Hardware>
      <StorageControllers>
        <StorageController name="IDE Controller" type="PIIX4" PortCount="2" useHostIOCache="true" Bootable="true">
          <AttachedDevice type="HardDisk" port="0" device="0">
            <Image uuid="{${DISK_UUID}}"/>
          </AttachedDevice>
        </StorageController>
      </StorageControllers>
    </vbox:Machine>
  </VirtualSystem>
</Envelope>
EOF
fi
