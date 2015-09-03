function Get-AbsolutePath ($Path)
{
    # System.IO.Path.Combine has two properties making it necesarry here:
    #   1) correctly deals with situations where $Path (the second term) is an absolute path
    #   2) correctly deals with situations where $Path (the second term) is relative
    # (join-path) commandlet does not have this first property
    $Path = [System.IO.Path]::Combine( ((pwd).Path), ($Path) );

    # this piece strips out any relative path modifiers like '..' and '.'
    $Path = [System.IO.Path]::GetFullPath($Path);

    return $Path;
}

function Expand-ZIP
{
  Param ( 
    [string] [Parameter(Mandatory=$True,Position=1)]
    [string] $Filename,
    [string] [Parameter(Mandatory=$True)]
    [string] $Destination
  )
  
  Process {
    $shell = new-object -com shell.application
    if (!(Test-Path "$Filename"))
    {
        throw "$Filename does not exist" 
    }
        # Flags and values found at: https://msdn.microsoft.com/en-us/library/windows/desktop/bb759795%28v=vs.85%29.aspx
        $FOF_NOCONFIRMATION = 0x0010
 
        # Set the flag values based on the parameters provided.
        $copyFlags = $FOF_NOCONFIRMATION
 
        # Get the Shell object, Destination Directory, and Zip file.
        $shell = New-Object -ComObject Shell.Application
        $destinationDirectoryShell = $shell.NameSpace((Get-AbsolutePath $Destination))
        $zipShell = $shell.NameSpace((Get-AbsolutePath $Filename))
         
        # Start copying the Zip files into the destination directory, using the flags specified by the user. This is an asynchronous operation.
        $destinationDirectoryShell.CopyHere($zipShell.Items(), $copyFlags)
  }
}

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


function Download-File 
{ 
  Param ( 
    [string] [Parameter(Mandatory=$True,Position=1)]
    [string] $Url,
    [string] [Parameter(Mandatory=$True,Position=1)]
    [string] $Outfile
  )
  Process {
    Write-Host "Dl: $Url"
    Import-Module BitsTransfer
    Start-BitsTransfer -Source $Url -Destination $Outfile -Description "$Url" -DisplayName "Downloading"

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

function Create-Coreos 
{ 

  Param ( 
    [string] $version = "stable"
  )
  
  Begin { 
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
    
    # BitsTransfer is being difficult, wget to the rescue
    Download-File "https://eternallybored.org/misc/wget/wget.exe" -Outfile "$WORKDIR\wget.exe"
    # Redirects and get parameters does not work with BitsTransfer
    Invoke-Expression '& $WORKDIR\wget.exe --mirror --no-check-certificate --domains=s3.amazonaws.com -O "$WORKDIR\bzip2.zip" "https://github.com/philr/bzip2-windows/releases/download/v1.0.6/bzip2-1.0.6-win-x86.zip"'
    Expand-ZIP -Filename "$WORKDIR\bzip2.zip" -Destination "$WORKDIR"
    
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
  } #End Begin 
  End {
    Remove-Item $WORKDIR -Recurse
  }
} #End Create-Coreos 

Create-Coreos
