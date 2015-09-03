
Param ( 
    [string] [Parameter(Mandatory=$True)]
    [string] $HOSTNAME,
    [string] [Parameter(Mandatory=$True)]
    [string] $SSH_FILE,
    [string] [Parameter(Mandatory=$False)]
    [string] $ETCD_NAME,
    [string] [Parameter(Mandatory=$False)]
    [string] $TOKEN,
    [string] [Parameter(Mandatory=$False)]
    [string] $ETCD_DISCOVERY,
    [string] [Parameter(Mandatory=$False)]
    [string] $ETCD_ADDR,
    [string] [Parameter(Mandatory=$False)]
    [string] $ETCD_PEER_ADDR 
  )
  
"
This tool creates a basic config-drive ISO image.
"

. .\create-tools.ps1


function Install-Mkisofs($tooldir)
{
  # Redirects and get parameters does not work with BitsTransfer
  Invoke-Expression '& $tooldir\wget.exe --mirror --no-check-certificate --domains=* -O "$tooldir\mkisofs.zip" "http://downloads.sourceforge.net/project/mkisofs-md5/mkisofs-md5-v2.01/mkisofs-md5-2.01-Binary.zip?r=http%3A%2F%2Fsourceforge.net%2Fprojects%2Fmkisofs-md5%2Ffiles%2Fmkisofs-md5-v2.01%2Fmkisofs-md5-2.01-Binary.zip%2Fdownload&ts=1441282840&use_mirror=netcologne"'
  Expand-ZIP -Filename "$tooldir\mkisofs.zip" -Destination "$tooldir"
}

function Make-ConfigDrive($tooldir, $source, $destination) {
  Install-Wget $tooldir
  Install-Mkisofs $tooldir
  Invoke-Expression '& $tooldir\Binary\MinGW\Gcc-4.4.5\mkisofs.exe -R -V config-2 -o $destination $source'
}  

$CLOUD_CONFIG="#cloud-config

coreos:
  units:
    - name: br0.netdev
      runtime: true
      content: |
        [NetDev]
        Name=br0
        Kind=bridge
    - name: enp0s3.network
      runtime: true
      content: |
        [Match]
        Name=enp0s3

        [Network]
        Bridge=br0
    - name: br0.network
      runtime: true
      content: |
        [Match]
        Name=br0

        [Network]
        DNS=1.2.3.4
        Address=10.0.2.2/24
    - name: etcd2.service
      command: start
    - name: fleet.service
      command: start
  etcd2:
    name: <ETCD_NAME>
    discovery: <ETCD_DISCOVERY>
    addr: <ETCD_ADDR>
    peer-addr: <ETCD_PEER_ADDR>
ssh_authorized_keys:
  - <SSH_KEY>
hostname: <HOSTNAME>
"

[string] $RANDOM = Get-Random
[string] $WORKDIR="tmp.$RANDOM"
[string] $TOOLDIR="$WORKDIR\tools"
[string] $DATADIR="$WORKDIR\data"
    
New-Item -Path "$WORKDIR" -Type directory | Out-Null
New-Item -Path "$TOOLDIR" -Type directory | Out-Null
New-Item -Path "$DATADIR" -Type directory | Out-Null

$DEFAULT_ETCD_DISCOVERY="https//discovery.etcd.io/TOKEN"
$DEFAULT_ETCD_ADDR="\`$public_ipv4:4001"
$DEFAULT_ETCD_PEER_ADDR="\`$private_ipv4:7001"

$REGEX_SSH_FILE="^ssh-(rsa|dss|ed25519) [-A-Za-z0-9+\/]+[=]{0,2} .+"

if(($TOKEN) -and ($ETCD_DISCOVERY)) { Throw "You cannot specify both discovery token and discovery URL." }

if ( -not (Test-Path $SSH_FILE)) {
    Throw "($SSH_FILE) was not found." 
}
if ( (Get-Content $SSH_FILE).length -eq 0 ) { 
    Throw "The SSH file (${SSH_FILE}) is empty."
}

#if ( (Get-Content $SSH_FILE) -match $REGEX_SSH_FILE) { 
#    Throw "The SSH file $SSH_FILE content is invalid."
#}

if (($TOKEN)) {
    $ETCD_DISCOVERY=($DEFAULT_ETCD_DISCOVERY -replace '//TOKEN','/($TOKEN)')
}

if (!$ETCD_DISCOVERY) {
    $ETCD_DISCOVERY=$DEFAULT_ETCD_DISCOVERY
}

if (!$ETCD_NAME) {
    $ETCD_NAME=$HOSTNAME
}
if (!$ETCD_ADDR) {
    $ETCD_ADDR=$DEFAULT_ETCD_ADDR
}

if (!$ETCD_PEER_ADDR) {
    $ETCD_PEER_ADDR=$DEFAULT_ETCD_PEER_ADDR
}

$SSH_KEY=(Get-Content $SSH_FILE)

$CLOUD_CONFIG=($CLOUD_CONFIG -replace '<ETCD_NAME>',$ETCD_NAME)
$CLOUD_CONFIG=($CLOUD_CONFIG -replace '<ETCD_DISCOVERY>',$ETCD_DISCOVERY)
$CLOUD_CONFIG=($CLOUD_CONFIG -replace '<ETCD_ADDR>',$ETCD_ADDR)
$CLOUD_CONFIG=($CLOUD_CONFIG -replace '<ETCD_PEER_ADDR>',$ETCD_PEER_ADDR)
$CLOUD_CONFIG=($CLOUD_CONFIG -replace '<SSH_KEY>',$SSH_KEY)
$CLOUD_CONFIG=($CLOUD_CONFIG -replace '<HOSTNAME>',$HOSTNAME)


$CONFIG_DIR="$DATADIR\openstack\latest"
$CONFIG_FILE="$CONFIG_DIR\user_data"
$CONFIGDRIVE_FILE="$HOSTNAME.iso"

New-Item -Path "$CONFIG_DIR" -Type directory | Out-Null

$CLOUD_CONFIG=($CLOUD_CONFIG -replace "`r`n", "`n")
[IO.File]::WriteAllText($CONFIG_FILE, $CLOUD_CONFIG)

Make-ConfigDrive $TOOLDIR -source $DATADIR -destination $CONFIGDRIVE_FILE

Write-Host "Success! The config-drive image was created on ${CONFIGDRIVE_FILE}"

Remove-Item $WORKDIR -Recurse
