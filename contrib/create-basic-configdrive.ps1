<#

.SYNOPSIS
This tool creates a basic config-drive ISO image.

.DESCRIPTION
Usage: .\create-basic-configdrive.ps1 -H HOSTNAME -S SSH_FILE [-d|-e|-i|-n|-t]
Options:
    -d URL             Full URL path to discovery endpoint.
    -e http://IP:PORT  Adviertise URL for client communication.
    -H HOSTNAME        Machine hostname.
    -i http://IP:PORT  URL for server communication.
    -l http://IP:PORT  Listen URL for client communication.
    -u http://IP:PORT  Listen URL for server communication.
    -n NAME            etcd node name.
    -S FILE            SSH keys file.
    -t TOKEN           Token ID from https://discovery.etcd.io.

#>

Param ( 
    [Parameter(Mandatory=$True)][Alias('H')]
    [string] $HOSTNAME,
    [string] [Parameter(Mandatory=$True)][Alias('S')]
    [string] $SSH_FILE,
    [string] [Parameter(Mandatory=$False)][Alias('t')]
    [string] $TOKEN,
    [string] [Parameter(Mandatory=$False)][Alias('n')]
    [string] $ETCD_NAME,
    [string] [Parameter(Mandatory=$False)][Alias('d')]
    [string] $ETCD_DISCOVERY,
    [string] [Parameter(Mandatory=$False)][Alias('e')]
    [string] $ETCD_ADDR,
    [string] [Parameter(Mandatory=$False)][Alias('i')]
    [string] $ETCD_PEER_URLS,
    [string] [Parameter(Mandatory=$False)][Alias('u')]
    [string] $ETCD_LISTEN_PEER_URLS,
    [string] [Parameter(Mandatory=$False)][Alias('l')]
    [string] $ETCD_LISTEN_CLIENT_URLS
  )
  

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
  etcd2:
    name: <ETCD_NAME>
    advertise-client-urls: <ETCD_ADDR>
    initial-advertise-peer-urls: <ETCD_PEER_URLS>
    discovery: <ETCD_DISCOVERY>
    listen-peer-urls: <ETCD_LISTEN_PEER_URLS>
    listen-client-urls: <ETCD_LISTEN_CLIENT_URLS>
  units:
    - name: etcd2.service
      command: start
    - name: fleet.service
      command: start
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
$DEFAULT_ETCD_ADDR="http://\`$public_ipv4:2379"
$DEFAULT_ETCD_PEER_URLS="http://\`$private_ipv4:2380"
$DEFAULT_ETCD_LISTEN_PEER_URLS="http://0.0.0.0:2380"
$DEFAULT_ETCD_LISTEN_CLIENT_URLS="http://0.0.0.0:2379,http://0.0.0.0:4001"

$REGEX_SSH_FILE="^ssh-(rsa|dss|ed25519) [-A-Za-z0-9+\/]+[=]{0,2} .+"

if(($TOKEN) -and ($ETCD_DISCOVERY)) { Throw "You cannot specify both discovery token and discovery URL." }

if ( -not (Test-Path $SSH_FILE)) {
    Throw "($SSH_FILE) was not found." 
}
if ( -not (Get-Content $SSH_FILE) ) { 
    Throw "The SSH file ($SSH_FILE) is empty."
}

if ( -not ((Get-Content $SSH_FILE) -match $REGEX_SSH_FILE)) { 
    Throw "The SSH file $SSH_FILE content is invalid."
}

if (($TOKEN)) {
    $ETCD_DISCOVERY=($DEFAULT_ETCD_DISCOVERY -replace '/TOKEN', $('/' + $TOKEN))
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

if (!$ETCD_PEER_URLS) {
    $ETCD_PEER_URLS=$DEFAULT_ETCD_PEER_URLS
}

if (!$ETCD_LISTEN_PEER_URLS) {
    $ETCD_LISTEN_PEER_URLS=$DEFAULT_LISTEN_PEER_URLS
}

if (!$ETCD_LISTEN_CLIENT_URLS) {
    $ETCD_LISTEN_CLIENT_URLS=$DEFAULT_ETCD_LISTEN_CLIENT_URLS
}

$SSH_KEY=(Get-Content $SSH_FILE)

$CLOUD_CONFIG=($CLOUD_CONFIG -replace '<ETCD_NAME>',$ETCD_NAME)
$CLOUD_CONFIG=($CLOUD_CONFIG -replace '<ETCD_DISCOVERY>',$ETCD_DISCOVERY)
$CLOUD_CONFIG=($CLOUD_CONFIG -replace '<ETCD_ADDR>',$ETCD_ADDR)
$CLOUD_CONFIG=($CLOUD_CONFIG -replace '<ETCD_PEER_URLS>',$ETCD_PEER_URLS)
$CLOUD_CONFIG=($CLOUD_CONFIG -replace '<ETCD_LISTEN_PEER_URLS>',$ETCD_LISTEN_PEER_URLS)
$CLOUD_CONFIG=($CLOUD_CONFIG -replace '<ETCD_LISTEN_CLIENT_URLS>',$ETCD_LISTEN_CLIENT_URLS)
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
