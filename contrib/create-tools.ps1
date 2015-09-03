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

function Install-Wget($tooldir)
{
    # BitsTransfer is being difficult, wget to the rescue
    Download-File "https://eternallybored.org/misc/wget/wget.exe" -Outfile "$tooldir\wget.exe"
}
