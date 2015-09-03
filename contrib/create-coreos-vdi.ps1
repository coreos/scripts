
Param ( 
  [string] $version = "stable"
)

"
This tool creates a CoreOS VDI image to be used with VirtualBox.
"  

. .\create-tools.ps1


function IsValidUrl
{
  Param ( 
    [string] [Parameter(Mandatory=$True,Position=1)]
    [string] $Url
  )
  Process {
    $isValid = $false
   
    try
    {
        $request = [System.Net.WebRequest]::Create($Url)
        $request.Method = "HEAD"

        [System.Net.HttpWebResponse] $response = $request.GetResponse()
        $httpStatus = $response.StatusCode
   
        $isValid = ($httpStatus -eq "OK")
        
        $response.Close()
    }
    catch
    {
        # Pass
    }
    
    return $isValid
  }
}

function Get-Hashed-From-File
{
  Param ( 
    [string] [Parameter(Mandatory=$True,Position=1)]
    [string] $Infile
  )
  Process { 
    gc "$Infile" | %{$h = @{}} {if ($_ -match "(.*)=(.*)") {$h[$matches[1]]=$matches[2];}}
    return $h
  }
}
function Install-Bzip2($tooldir)
{
    Install-Wget $tooldir
    # Redirects and get parameters does not work with BitsTransfer
    Invoke-Expression '& $tooldir\wget.exe --mirror --no-check-certificate --domains=s3.amazonaws.com -O "$tooldir\bzip2.zip" "https://github.com/philr/bzip2-windows/releases/download/v1.0.6/bzip2-1.0.6-win-x86.zip"'
    Expand-ZIP -Filename "$tooldir\bzip2.zip" -Destination "$tooldir"
}

[string] $VERSION_ID="stable"
[string] $GPG_KEY_URL="https://coreos.com/security/image-signing-key/CoreOS_Image_Signing_Key.pem"
[string] $GPG_LONG_ID="50E0885593D2DCB4"
$wc = New-Object system.Net.WebClient
[string] $GPG_KEY = $wc.downloadString($GPG_KEY_URL)

# VirtualBox tools required
$VBoxManage = $((Get-ItemProperty -Path Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Oracle\VirtualBox -Name InstallDir).InstallDir + "VBoxManage.exe") 
if ((Get-Command "$VBoxManage" -ErrorAction SilentlyContinue) -eq $null)  
{ 
  Write-Host "Unable to find VBoxManage.exe $VBoxManage"
}

[string] $RANDOM = Get-Random
[string] $WORKDIR="tmp.$RANDOM"

New-Item -Path "$WORKDIR" -Type directory | Out-Null

Install-Bzip2 $WORKDIR

[string] $RAW_IMAGE_NAME="coreos_production_image.bin"
[string] $IMAGE_NAME="${RAW_IMAGE_NAME}.bz2"
[string] $DIGESTS_NAME="${IMAGE_NAME}.DIGESTS.asc"

switch($VERSION_ID) {
  "stable" {
    [string] $BASE_URL="http://stable.release.core-os.net/amd64-usr/current"
  }
  "alpha" {
    [string] $BASE_URL="http://alpha.release.core-os.net/amd64-usr/current"
  }
  "beta" {
    [string] $BASE_URL="http://beta.release.core-os.net/amd64-usr/current"
  }
  default {
    [string] $BASE_URL="http://storage.core-os.net/coreos/amd64-usr/$VERSION_ID"
  }
}

[string] $IMAGE_URL="$BASE_URL/$IMAGE_NAME"
[string] $DIGESTS_URL="$BASE_URL/$DIGESTS_NAME"
[string] $DOWN_IMAGE="$WORKDIR\$RAW_IMAGE_NAME"

if (!(IsValidUrl($IMAGE_URL))) {
  Write-Host "Image URL unavailable: $IMAGE_URL"
}
if (!(IsValidUrl($DIGESTS_URL))) {
  Write-Host "Image signature URL unavailable: $DIGESTS_URL"
}

# Gets CoreOS version from version.txt file
[string] $VERSION_NAME="version.txt"
[string] $VERSION_URL="${BASE_URL}/$VERSION_NAME"

Download-File $VERSION_URL -Outfile "$WORKDIR\$VERSION_NAME"

$kv = Get-Hashed-From-File "$WORKDIR\$VERSION_NAME"
$VDI_IMAGE_NAME="coreos_production_$($kv["COREOS_BUILD"]).$($kv["COREOS_BRANCH"]).$($kv["COREOS_PATCH"]).vdi"
$VDI_IMAGE=$((Get-AbsolutePath ".\$VDI_IMAGE_NAME"))

Download-File "$IMAGE_URL" -Outfile "$WORKDIR\$IMAGE_NAME"

Write-Host "Writing $IMAGE_NAME to $DOWN_IMAGE ..."
Invoke-Expression '& $WORKDIR\bzip2.exe -d "$WORKDIR\$IMAGE_NAME"'

Write-Host "Converting $RAW_IMAGE_NAME to VirtualBox format... "
Invoke-Expression '& $VBoxManage convertdd "$DOWN_IMAGE" "$VDI_IMAGE" --format VDI'

Write-Host "Success CoreOS $VERSION_ID VDI image was created on $VDI_IMAGE"

Remove-Item $WORKDIR -Recurse
