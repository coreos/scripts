#!/bin/bash

# Mostly this just copies the below XML, but inserting random MAC address
# and UUID strings, and other options as appropriate.

SCRIPT_ROOT=$(readlink -f $(dirname "$0")/..)
. "${SCRIPT_ROOT}/common.sh" || exit 1

DEFINE_string vm_name "CoreOS" "Name for this VM"
DEFINE_string disk_image "" "Disk image to reference, only basename is used."
DEFINE_integer memory_size 1024 "Memory size in MB"
DEFINE_string output_dir "" "Path to the output directory, required."

# Parse command line
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

# Die on any errors.
switch_to_strict_mode

if [[ ! -e "${FLAGS_disk_image}" ]]; then
    echo "No such disk image '${FLAGS_disk_image}'" >&2
    exit 1
fi

if [[ ! -d "${FLAGS_output_dir}" ]]; then
    echo "Output directory '${FLAGS_output_dir}' not found" >&2
    exit 1
fi

DISK_UUID=$(uuidgen)
DISK_VIRTUAL_SIZE_BYTES=$(qemu-img info -f parallels --output json "${FLAGS_disk_image}" \
    | jq --raw-output '.["virtual-size"]')
DISK_ACTUAL_SIZE_BYTES=$(du --bytes "${FLAGS_disk_image}" | cut -f1)

if [[ -z "${DISK_VIRTUAL_SIZE_BYTES}" ]]; then
    echo "Unable to determine virtual size of ${FLAGS_disk_image}" >&2
    exit 1
fi

PARALLELS_MAC_PREFIX=001C42
macgen() {
    hexdump -n3 -e "\"${PARALLELS_MAC_PREFIX}%06X\n\"" /dev/urandom
}

datez() {
    date -u "+%Y-%m-%d %H:%M:%S"
}

pvm_dir="${FLAGS_output_dir}"/"${FLAGS_vm_name}".pvm
mkdir -p ${pvm_dir}

cat >"${pvm_dir}"/config.pvs <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<ParallelsVirtualMachine schemaVersion="1.0" dyn_lists="VirtualAppliance 0">
   <AppVersion>10.3.0-29227</AppVersion>
   <ValidRc>0</ValidRc>
   <Identification dyn_lists="">
      <VmUuid>{$(uuidgen)}</VmUuid>
      <SourceVmUuid>{$(uuidgen)}</SourceVmUuid>
      <LinkedVmUuid></LinkedVmUuid>
      <LinkedSnapshotUuid></LinkedSnapshotUuid>
      <VmName>${FLAGS_vm_name}</VmName>
      <ServerUuid></ServerUuid>
      <LastServerUuid>{0ba0dd3e-d0bf-420c-a0b2-b83cb4d885c1}</LastServerUuid>
      <ServerHost></ServerHost>
      <VmFilesLocation>1</VmFilesLocation>
      <VmCreationDate>$(datez)</VmCreationDate>
      <VmUptimeStartDateTime>$(datez)</VmUptimeStartDateTime>
      <VmUptimeInSeconds>0</VmUptimeInSeconds>
      <EnvId>1336536201</EnvId>
   </Identification>
   <Security ParentalControlEnabled_patch="1" dyn_lists="">
      <AccessControlList dyn_lists="AccessControl"/>
      <LockedOperationsList dyn_lists="LockedOperation"/>
      <Owner></Owner>
      <IsOwner>0</IsOwner>
      <AccessForOthers>0</AccessForOthers>
      <LockedSign>0</LockedSign>
      <ParentalControlEnabled>1</ParentalControlEnabled>
   </Security>
   <Settings dyn_lists="">
      <General dyn_lists="PrevOsNumber">
         <OsType>9</OsType>
         <OsNumber>2309</OsNumber>
         <VmDescription></VmDescription>
         <IsTemplate>1</IsTemplate>
         <CustomProperty></CustomProperty>
         <SwapDir></SwapDir>
         <VmColor>0</VmColor>
         <Profile Custom_patch="1" dyn_lists="">
            <Type>0</Type>
            <Custom>0</Custom>
         </Profile>
         <AssetId></AssetId>
      </General>
      <Startup AutoStart_patch="2" dyn_lists="">
         <AutoStart>0</AutoStart>
         <AutoStartDelay>0</AutoStartDelay>
         <VmStartLoginMode>0</VmStartLoginMode>
         <VmFastRebootUser></VmFastRebootUser>
         <VmStartAsUser></VmStartAsUser>
         <VmStartAsPassword></VmStartAsPassword>
         <WindowMode>0</WindowMode>
         <LockInFullScreenMode>0</LockInFullScreenMode>
         <StartInDetachedWindow>0</StartInDetachedWindow>
         <BootingOrder dyn_lists="BootDevice 10">
            <BootDevice id="6" dyn_lists="">
               <Index>0</Index>
               <Type>6</Type>
               <BootingNumber>1</BootingNumber>
               <InUse>1</InUse>
            </BootDevice>
            <BootDevice id="7" dyn_lists="">
               <Index>0</Index>
               <Type>5</Type>
               <BootingNumber>2</BootingNumber>
               <InUse>1</InUse>
            </BootDevice>
            <BootDevice id="8" dyn_lists="">
               <Index>0</Index>
               <Type>15</Type>
               <BootingNumber>3</BootingNumber>
               <InUse>0</InUse>
            </BootDevice>
            <BootDevice id="9" dyn_lists="">
               <Index>0</Index>
               <Type>8</Type>
               <BootingNumber>4</BootingNumber>
               <InUse>0</InUse>
            </BootDevice>
         </BootingOrder>
         <AllowSelectBootDevice>0</AllowSelectBootDevice>
         <FastReboot>0</FastReboot>
         <Bios dyn_lists="">
            <EfiEnabled>0</EfiEnabled>
         </Bios>
         <ExternalDeviceSystemName></ExternalDeviceSystemName>
      </Startup>
      <Shutdown dyn_lists="">
         <AutoStop>1</AutoStop>
         <OnVmWindowClose>2</OnVmWindowClose>
         <WindowOnShutdown>0</WindowOnShutdown>
      </Shutdown>
      <ClusterOptions dyn_lists="">
         <Running>0</Running>
         <ServiceName></ServiceName>
      </ClusterOptions>
      <Runtime StickyMouse_patch="1" OptimizePowerConsumptionMode_patch="1" dyn_lists="IoLimit 0">
         <ForegroundPriority>1</ForegroundPriority>
         <BackgroundPriority>1</BackgroundPriority>
         <IoPriority>4</IoPriority>
         <IopsLimit>0</IopsLimit>
         <DiskCachePolicy>1</DiskCachePolicy>
         <CloseAppOnShutdown>0</CloseAppOnShutdown>
         <ActionOnStop>0</ActionOnStop>
         <DockIcon>0</DockIcon>
         <OsResolutionInFullScreen>0</OsResolutionInFullScreen>
         <FullScreen CornerAction_patch="2" dyn_lists="CornerAction">
            <UseAllDisplays>0</UseAllDisplays>
            <UseActiveCorners>0</UseActiveCorners>
            <UseNativeFullScreen>1</UseNativeFullScreen>
            <CornerAction>1</CornerAction>
            <CornerAction>0</CornerAction>
            <CornerAction>0</CornerAction>
            <CornerAction>0</CornerAction>
            <ScaleViewMode>1</ScaleViewMode>
            <EnableGammaControl>1</EnableGammaControl>
         </FullScreen>
         <UndoDisks>0</UndoDisks>
         <SafeMode>0</SafeMode>
         <SystemFlags></SystemFlags>
         <DisableAPIC>0</DisableAPIC>
         <OptimizePowerConsumptionMode>1</OptimizePowerConsumptionMode>
         <ShowBatteryStatus>1</ShowBatteryStatus>
         <Enabled>0</Enabled>
         <EnableAdaptiveHypervisor>0</EnableAdaptiveHypervisor>
         <UseSMBiosData>0</UseSMBiosData>
         <DisableSpeaker>1</DisableSpeaker>
         <HideBiosOnStartEnabled>0</HideBiosOnStartEnabled>
         <UseDefaultAnswers>0</UseDefaultAnswers>
         <CompactHddMask>0</CompactHddMask>
         <CompactMode>0</CompactMode>
         <DisableWin7Logo>1</DisableWin7Logo>
         <OptimizeModifiers>0</OptimizeModifiers>
         <StickyMouse>0</StickyMouse>
         <PauseOnDeactivation>0</PauseOnDeactivation>
         <FEATURES_MASK>0</FEATURES_MASK>
         <EXT_FEATURES_MASK>0</EXT_FEATURES_MASK>
         <EXT_80000001_ECX_MASK>0</EXT_80000001_ECX_MASK>
         <EXT_80000001_EDX_MASK>0</EXT_80000001_EDX_MASK>
         <EXT_80000007_EDX_MASK>0</EXT_80000007_EDX_MASK>
         <EXT_80000008_EAX>0</EXT_80000008_EAX>
         <EXT_00000007_EBX_MASK>0</EXT_00000007_EBX_MASK>
         <EXT_0000000D_EAX_MASK>0</EXT_0000000D_EAX_MASK>
         <CpuFeaturesMaskValid>0</CpuFeaturesMaskValid>
         <UnattendedInstallLocale></UnattendedInstallLocale>
         <UnattendedInstallEdition></UnattendedInstallEdition>
         <HostRetinaEnabled>0</HostRetinaEnabled>
      </Runtime>
      <Schedule dyn_lists="">
         <SchedBasis>0</SchedBasis>
         <SchedGranularity>0</SchedGranularity>
         <SchedDayOfWeek>0</SchedDayOfWeek>
         <SchedDayOfMonth>0</SchedDayOfMonth>
         <SchedDay>0</SchedDay>
         <SchedWeek>0</SchedWeek>
         <SchedMonth>0</SchedMonth>
         <SchedStartDate>1752-01-01</SchedStartDate>
         <SchedStartTime>00:00:00</SchedStartTime>
         <SchedStopDate>1752-01-01</SchedStopDate>
         <SchedStopTime>00:00:00</SchedStopTime>
      </Schedule>
      <RemoteDisplay dyn_lists="">
         <Mode>0</Mode>
         <Password></Password>
         <HostName>0.0.0.0</HostName>
         <PortNumber>0</PortNumber>
         <Encrypted>0</Encrypted>
      </RemoteDisplay>
      <Tools dyn_lists="">
         <IsolatedVm>0</IsolatedVm>
         <NonAdminToolsUpgrade>1</NonAdminToolsUpgrade>
         <LockGuestOnSuspend>0</LockGuestOnSuspend>
         <Coherence GroupAllWindows_patch="1" RelocateTaskBar_patch="1" MultiDisplay_patch="1" ExcludeDock_patch="1" ShowTaskBar_patch="1" DoNotMinimizeToDock_patch="1" AlwaysOnTop_patch="1" BringToFront_patch="1" dyn_lists="">
            <ShowTaskBar>1</ShowTaskBar>
            <ShowTaskBarInCoherence>0</ShowTaskBarInCoherence>
            <RelocateTaskBar>0</RelocateTaskBar>
            <ExcludeDock>1</ExcludeDock>
            <MultiDisplay>1</MultiDisplay>
            <GroupAllWindows>0</GroupAllWindows>
            <DisableDropShadow>0</DisableDropShadow>
            <DoNotMinimizeToDock>0</DoNotMinimizeToDock>
            <BringToFront>0</BringToFront>
            <AppInDock>0</AppInDock>
            <ShowWinSystrayInMacMenu>1</ShowWinSystrayInMacMenu>
            <UseBorders>0</UseBorders>
            <UseSeamlessMode>0</UseSeamlessMode>
            <SwitchToFullscreenOnDemand>1</SwitchToFullscreenOnDemand>
            <PauseIdleVM>0</PauseIdleVM>
            <DisableAero>0</DisableAero>
            <CoherenceButtonVisibility>1</CoherenceButtonVisibility>
            <AlwaysOnTop>0</AlwaysOnTop>
            <WindowAnimation>1</WindowAnimation>
         </Coherence>
         <SharedFolders dyn_lists="">
            <HostSharing MapSharedFoldersOnLetters_patch="1" dyn_lists="SharedFolder 0">
               <Enabled>0</Enabled>
               <ShareAllMacDisks>0</ShareAllMacDisks>
               <ShareUserHomeDir>1</ShareUserHomeDir>
               <MapSharedFoldersOnLetters>1</MapSharedFoldersOnLetters>
               <UserDefinedFoldersEnabled>1</UserDefinedFoldersEnabled>
               <SetExecBitForFiles>0</SetExecBitForFiles>
               <VirtualLinks>1</VirtualLinks>
               <EnableDos8dot3Names>1</EnableDos8dot3Names>
               <SharedShortcuts>0</SharedShortcuts>
               <SharedCloud>0</SharedCloud>
            </HostSharing>
            <GuestSharing dyn_lists="">
               <Enabled>0</Enabled>
               <AutoMount>1</AutoMount>
               <AutoMountNetworkDrives>0</AutoMountNetworkDrives>
               <EnableSpotlight>0</EnableSpotlight>
               <AutoMountCloudDrives>1</AutoMountCloudDrives>
            </GuestSharing>
         </SharedFolders>
         <SharedProfile dyn_lists="">
            <Enabled>0</Enabled>
            <UseDesktop>1</UseDesktop>
            <UseDocuments>1</UseDocuments>
            <UsePictures>1</UsePictures>
            <UseMusic>1</UseMusic>
            <UseMovies>1</UseMovies>
            <UseDownloads>1</UseDownloads>
            <UseTrashBin>1</UseTrashBin>
         </SharedProfile>
         <SharedApplications dyn_lists="">
            <FromWinToMac>0</FromWinToMac>
            <FromMacToWin>0</FromMacToWin>
            <SmartSelect>0</SmartSelect>
            <AppInDock>2</AppInDock>
            <ShowWindowsAppInDock>1</ShowWindowsAppInDock>
            <ShowGuestNotifications>1</ShowGuestNotifications>
            <BounceDockIconWhenAppFlashes>1</BounceDockIconWhenAppFlashes>
            <WebApplications dyn_lists="">
               <WebBrowser>0</WebBrowser>
               <EmailClient>0</EmailClient>
               <FtpClient>0</FtpClient>
               <Newsgroups>0</Newsgroups>
               <Rss>0</Rss>
               <RemoteAccess>0</RemoteAccess>
            </WebApplications>
            <IconGroupingEnabled>1</IconGroupingEnabled>
            <AddInstalledApplicationsToLaunchpad>1</AddInstalledApplicationsToLaunchpad>
         </SharedApplications>
         <AutoUpdate dyn_lists="">
            <Enabled>0</Enabled>
         </AutoUpdate>
         <ClipboardSync Enabled_patch="1" dyn_lists="">
            <Enabled>0</Enabled>
            <PreserveTextFormatting>1</PreserveTextFormatting>
         </ClipboardSync>
         <DragAndDrop Enabled_patch="1" dyn_lists="">
            <Enabled>0</Enabled>
         </DragAndDrop>
         <KeyboardLayoutSync dyn_lists="">
            <Enabled>0</Enabled>
         </KeyboardLayoutSync>
         <MouseSync dyn_lists="">
            <Enabled>0</Enabled>
         </MouseSync>
         <MouseVtdSync dyn_lists="">
            <Enabled>0</Enabled>
         </MouseVtdSync>
         <SmartMouse dyn_lists="">
            <Enabled>0</Enabled>
         </SmartMouse>
         <SmoothScrolling dyn_lists="">
            <Enabled>0</Enabled>
         </SmoothScrolling>
         <TimeSync SyncInterval_patch="1" dyn_lists="">
            <Enabled>1</Enabled>
            <SyncInterval>60</SyncInterval>
            <KeepTimeDiff>0</KeepTimeDiff>
            <SyncHostToGuest>0</SyncHostToGuest>
         </TimeSync>
         <TisDatabase dyn_lists="">
            <Data></Data>
         </TisDatabase>
         <Modality Opacity_patch="1" StayOnTop_patch="1" dyn_lists="">
            <Opacity>0.8</Opacity>
            <StayOnTop>1</StayOnTop>
            <CaptureMouseClicks>1</CaptureMouseClicks>
            <UseWhenAppInBackground>1</UseWhenAppInBackground>
         </Modality>
         <SharedVolumes dyn_lists="">
            <Enabled>0</Enabled>
            <UseExternalDisks>0</UseExternalDisks>
            <UseDVDs>0</UseDVDs>
            <UseConnectedServers>0</UseConnectedServers>
            <UseInversedDisks>0</UseInversedDisks>
         </SharedVolumes>
         <Gestures Enabled_patch="1" dyn_lists="">
            <Enabled>0</Enabled>
            <OneFingerSwipe>1</OneFingerSwipe>
         </Gestures>
         <RemoteControl dyn_lists="">
            <Enabled>0</Enabled>
         </RemoteControl>
         <NativeLook dyn_lists="">
            <Enabled>0</Enabled>
         </NativeLook>
         <AutoSyncOSType dyn_lists="">
            <Enabled>0</Enabled>
         </AutoSyncOSType>
         <Win7Look dyn_lists="">
            <Enabled>0</Enabled>
         </Win7Look>
      </Tools>
      <Autoprotect Period_patch="1" dyn_lists="">
         <Enabled>0</Enabled>
         <Period>86400</Period>
         <TotalSnapshots>10</TotalSnapshots>
         <Schema>2</Schema>
         <NotifyBeforeCreation>1</NotifyBeforeCreation>
      </Autoprotect>
      <AutoCompress Enabled_patch="1" dyn_lists="">
         <Enabled>0</Enabled>
         <Period>86400</Period>
         <FreeDiskSpaceRatio>50</FreeDiskSpaceRatio>
      </AutoCompress>
      <GlobalNetwork dyn_lists="DnsIPAddress SearchDomain OfflineService">
         <HostName></HostName>
         <DefaultGateway></DefaultGateway>
         <DefaultGatewayIPv6></DefaultGatewayIPv6>
         <OfflineManagementEnabled>0</OfflineManagementEnabled>
         <AutoApplyIpOnly>0</AutoApplyIpOnly>
         <NetworkRates dyn_lists="NetworkRate 0">
            <RateBound>0</RateBound>
         </NetworkRates>
      </GlobalNetwork>
      <VmEncryptionInfo dyn_lists="">
         <Enabled>0</Enabled>
         <PluginId></PluginId>
         <Hash1></Hash1>
         <Hash2></Hash2>
      </VmEncryptionInfo>
      <VmProtectionInfo dyn_lists="">
         <Enabled>0</Enabled>
         <Hash1></Hash1>
         <Hash2></Hash2>
         <Hash3></Hash3>
         <ExpirationInfo dyn_lists="">
            <Enabled>0</Enabled>
            <ExpirationDate>1752-01-01 00:00:00</ExpirationDate>
            <TrustedTimeServerUrl>https://parallels.com</TrustedTimeServerUrl>
            <Note></Note>
            <TimeCheckIntervalSeconds>1800</TimeCheckIntervalSeconds>
            <OfflineTimeToLiveSeconds>864000</OfflineTimeToLiveSeconds>
         </ExpirationInfo>
      </VmProtectionInfo>
      <SharedCamera Enabled_patch="1" dyn_lists="">
         <Enabled>0</Enabled>
      </SharedCamera>
      <VirtualPrintersInfo UseHostPrinters_patch="1" dyn_lists="">
         <UseHostPrinters>0</UseHostPrinters>
         <SyncDefaultPrinter>0</SyncDefaultPrinter>
      </VirtualPrintersInfo>
      <SharedBluetooth Enabled_patch="" dyn_lists="">
         <Enabled>0</Enabled>
      </SharedBluetooth>
      <LockDown dyn_lists="">
         <Hash></Hash>
      </LockDown>
      <UsbController UhcEnabled_patch="1" dyn_lists="">
         <UhcEnabled>0</UhcEnabled>
         <EhcEnabled>0</EhcEnabled>
         <XhcEnabled>0</XhcEnabled>
         <ExternalDevices dyn_lists="">
            <Disks>1</Disks>
            <HumanInterfaces>1</HumanInterfaces>
            <Communication>1</Communication>
            <Audio>1</Audio>
            <Video>1</Video>
            <SmartCards>1</SmartCards>
            <Printers>1</Printers>
            <SmartPhones>1</SmartPhones>
            <Other>1</Other>
         </ExternalDevices>
      </UsbController>
      <HighAvailability dyn_lists="">
         <Enabled>1</Enabled>
         <Priority>0</Priority>
      </HighAvailability>
      <OnlineCompact Mode_patch="3" dyn_lists="">
         <Mode>0</Mode>
      </OnlineCompact>
   </Settings>
   <Hardware dyn_lists="Fdd 0 CdRom 1 Hdd 2 Serial 0 Parallel 0 Printer 0 NetworkAdapter 1 Sound 1 USB 1 PciVideoAdapter 0 GenericDevice 0 GenericPciDevice 0 GenericScsiDevice 0">
      <Cpu EnableVTxSupport_patch="1" dyn_lists="">
         <Number>1</Number>
         <Mode>0</Mode>
         <AccelerationLevel>2</AccelerationLevel>
         <EnableVTxSupport>1</EnableVTxSupport>
         <EnableHotplug>0</EnableHotplug>
         <CpuUnits>0</CpuUnits>
         <CpuLimit>0</CpuLimit>
         <CpuLimitType>2</CpuLimitType>
         <CpuLimitValue>0</CpuLimitValue>
         <CpuMask></CpuMask>
         <VirtualizedHV>0</VirtualizedHV>
         <VirtualizePMU>0</VirtualizePMU>
      </Cpu>
      <Chipset Version_patch="1" dyn_lists="">
         <Type>1</Type>
         <Version>3</Version>
      </Chipset>
      <Clock dyn_lists="">
         <TimeShift>0</TimeShift>
      </Clock>
      <Memory dyn_lists="">
         <RAM>${FLAGS_memory_size}</RAM>
         <EnableHotplug>0</EnableHotplug>
         <HostMemQuotaMin>128</HostMemQuotaMin>
         <HostMemQuotaMax>4294967295</HostMemQuotaMax>
         <HostMemQuotaPriority>50</HostMemQuotaPriority>
         <AutoQuota>1</AutoQuota>
         <MaxBalloonSize>70</MaxBalloonSize>
      </Memory>
      <Video VideoMemorySize_patch="1" dyn_lists="">
         <Enabled>1</Enabled>
         <VideoMemorySize>32</VideoMemorySize>
         <EnableDirectXShaders>1</EnableDirectXShaders>
         <ScreenResolutions dyn_lists="ScreenResolution 0">
            <Enabled>0</Enabled>
         </ScreenResolutions>
         <Enable3DAcceleration>0</Enable3DAcceleration>
         <EnableVSync>1</EnableVSync>
         <MaxDisplays>0</MaxDisplays>
         <EnableHiResDrawing>0</EnableHiResDrawing>
         <UseHiResInGuest>1</UseHiResInGuest>
      </Video>
      <CdRom id="0" dyn_lists="">
         <Index>0</Index>
         <Enabled>0</Enabled>
         <Connected>0</Connected>
         <EmulatedType>0</EmulatedType>
         <SystemName></SystemName>
         <UserFriendlyName></UserFriendlyName>
         <Remote>0</Remote>
         <InterfaceType>2</InterfaceType>
         <StackIndex>1</StackIndex>
         <Passthrough>1</Passthrough>
         <SubType>0</SubType>
         <DeviceDescription></DeviceDescription>
      </CdRom>
      <Hdd id="1" dyn_lists="Partition 0">
         <Uuid>{$(uuidgen)}</Uuid>
         <Index>0</Index>
         <Enabled>1</Enabled>
         <Connected>1</Connected>
         <EmulatedType>1</EmulatedType>
         <SystemName>${FLAGS_vm_name}.hdd</SystemName>
         <UserFriendlyName>${FLAGS_vm_name}.hdd</UserFriendlyName>
         <Remote>0</Remote>
         <InterfaceType>2</InterfaceType>
         <StackIndex>0</StackIndex>
         <DiskType>1</DiskType>
         <Size>$((DISK_VIRTUAL_SIZE_BYTES / 1024 / 1024))</Size>
         <SizeOnDisk>$((DISK_ACTUAL_SIZE_BYTES / 1024 / 1024))</SizeOnDisk>
         <Passthrough>0</Passthrough>
         <SubType>0</SubType>
         <Splitted>0</Splitted>
         <DiskVersion>2</DiskVersion>
         <CompatLevel>level2</CompatLevel>
         <DeviceDescription></DeviceDescription>
      </Hdd>
      <NetworkAdapter AdapterType_patch="1" id="0" dyn_lists="NetAddress DnsIPAddress SearchDomain">
         <Index>0</Index>
         <Enabled>1</Enabled>
         <Connected>1</Connected>
         <EmulatedType>1</EmulatedType>
         <SystemName>eth0</SystemName>
         <UserFriendlyName>eth0</UserFriendlyName>
         <Remote>0</Remote>
         <AdapterNumber>-1</AdapterNumber>
         <AdapterName>Default Adapter</AdapterName>
         <MAC>$(macgen)</MAC>
         <HostMAC>$(macgen)</HostMAC>
         <HostInterfaceName></HostInterfaceName>
         <Router>0</Router>
         <DHCPUseHostMac>2</DHCPUseHostMac>
         <ForceHostMacAddress>0</ForceHostMacAddress>
         <VirtualNetworkID></VirtualNetworkID>
         <AdapterType>3</AdapterType>
         <StaticAddress>0</StaticAddress>
         <PktFilter dyn_lists="">
            <PreventPromisc>1</PreventPromisc>
            <PreventMacSpoof>1</PreventMacSpoof>
            <PreventIpSpoof>1</PreventIpSpoof>
         </PktFilter>
         <AutoApply>0</AutoApply>
         <ConfigureWithDhcp>0</ConfigureWithDhcp>
         <DefaultGateway></DefaultGateway>
         <ConfigureWithDhcpIPv6>0</ConfigureWithDhcpIPv6>
         <DefaultGatewayIPv6></DefaultGatewayIPv6>
         <Firewall dyn_lists="">
            <Enabled>0</Enabled>
            <Incoming dyn_lists="">
               <Direction dyn_lists="">
                  <DefaultPolicy>0</DefaultPolicy>
                  <FirewallRules dyn_lists="FirewallRule 0"/>
               </Direction>
            </Incoming>
            <Outgoing dyn_lists="">
               <Direction dyn_lists="">
                  <DefaultPolicy>0</DefaultPolicy>
                  <FirewallRules dyn_lists="FirewallRule 0"/>
               </Direction>
            </Outgoing>
         </Firewall>
         <DeviceDescription></DeviceDescription>
      </NetworkAdapter>
   </Hardware>
   <InstalledSoftware>0</InstalledSoftware>
   <ExternalConfigInfo dyn_lists="">
      <Type>0</Type>
      <ConfigPath></ConfigPath>
      <CheckSum></CheckSum>
   </ExternalConfigInfo>
</ParallelsVirtualMachine>
EOF

disk_dir="${pvm_dir}"/"${FLAGS_vm_name}".hdd
mkdir -p ${disk_dir}

cat >"${disk_dir}"/DiskDescriptor.xml <<EOF
<?xml version='1.0' encoding='UTF-8'?>
<Parallels_disk_image Version="1.0">
    <Disk_Parameters>
        <Disk_size>$((DISK_VIRTUAL_SIZE_BYTES / 16 / 32))</Disk_size>
        <Cylinders>$((DISK_VIRTUAL_SIZE_BYTES / 16 / 32 / 512))</Cylinders>
        <PhysicalSectorSize>512</PhysicalSectorSize>
        <Heads>16</Heads>
        <Sectors>32</Sectors>
        <Padding>0</Padding>
        <Encryption>
            <Engine>{00000000-0000-0000-0000-000000000000}</Engine>
            <Data></Data>
        </Encryption>
        <UID>{$(uuidgen)}</UID>
        <Name>coreos</Name>
        <Miscellaneous>
            <CompatLevel>level2</CompatLevel>
            <Bootable>1</Bootable>
            <SuspendState>0</SuspendState>
        </Miscellaneous>
    </Disk_Parameters>
    <StorageData>
        <Storage>
            <Start>0</Start>
            <End>$((DISK_VIRTUAL_SIZE_BYTES / 16 / 32))</End>
            <Blocksize>2048</Blocksize>
            <Image>
                <GUID>{5fbaabe3-6958-40ff-92a7-860e329aab41}</GUID>
                <Type>Compressed</Type>
                <File>${FLAGS_vm_name}.hdd.0.{5fbaabe3-6958-40ff-92a7-860e329aab41}.hds</File>
            </Image>
        </Storage>
    </StorageData>
    <Snapshots>
        <Shot>
            <GUID>{5fbaabe3-6958-40ff-92a7-860e329aab41}</GUID>
            <ParentGUID>{00000000-0000-0000-0000-000000000000}</ParentGUID>
        </Shot>
    </Snapshots>
</Parallels_disk_image>
EOF

touch "${disk_dir}"/"${FLAGS_vm_name}".hdd
cp ${FLAGS_disk_image} "${disk_dir}"/"${FLAGS_vm_name}".hdd.0.{5fbaabe3-6958-40ff-92a7-860e329aab41}.hds
