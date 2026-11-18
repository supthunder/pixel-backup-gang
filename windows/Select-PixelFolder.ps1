#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Share a selected PC folder read-only for one Pixel session.
.PARAMETER Reader
    Existing local account with read access. Defaults to PixelReader on this PC.
.PARAMETER Folder
    Full path of a local folder. Omitting it opens the folder picker.
.PARAMETER OnShareReady
    Optional status callback that receives the live Windows SMB share object
    after its ACL is verified. Returning from the callback ends the session.
.EXAMPLE
    .\windows\Select-PixelFolder.ps1
.NOTES
    Run in 64-bit Windows PowerShell. Use an enabled local user with a password
    and permission to read the selected files. Pair the Pixel with this PC first.
    The sharing window can grant the paired PixelReader NTFS Read & execute on
    a new private folder. Choosing that action starts a new sharing session.
    Keep the sharing dialog open while the Pixel reads the folder. Verify
    backup in Google Photos and close open previews before clicking OK.
    The paired watcher detaches the folder when the session ends.
    If the shell is killed, compare the path, scope and ownership tag printed
    at startup with the output of this command. A temporary share expires at
    the next Windows restart.

    Get-SmbShare -IncludeHidden | Where-Object Name -like 'PixelBackup-*' |
        Format-List Name,ScopeName,Path,Description,Temporary
#>
param(
    [ValidateNotNullOrEmpty()]
    [string]$Reader = "$env:COMPUTERNAME\PixelReader",
    [ValidateNotNullOrEmpty()]
    [string]$Folder,
    [scriptblock]$OnShareReady
)

$ErrorActionPreference = 'Stop'

function Get-ReaderAccount([string]$Account) {
    $parts = $Account -split '\\'
    if ($parts.Count -ne 2 -or $parts[0] -notin @('.', $env:COMPUTERNAME)) {
        throw "Enter a local username such as $env:COMPUTERNAME\PixelReader."
    }
    $user = Get-LocalUser | Where-Object Name -eq $parts[1]
    if (-not $user -or -not $user.Enabled -or $user.SID.Value.EndsWith('-501')) {
        throw 'The reader must be an enabled individual local user with a password. The built-in Guest is ineligible.'
    }
    "$env:COMPUTERNAME\$($user.Name)"
}

function Show-FolderAccessDialog([string]$Message) {
    $form = [System.Windows.Forms.Form]::new()
    try {
        $form.Text = 'PixelBackup is sharing'
        $form.StartPosition = 'CenterScreen'
        $form.FormBorderStyle = 'FixedDialog'
        $form.MaximizeBox = $false
        $form.MinimizeBox = $false
        $form.AutoSize = $true
        $form.AutoSizeMode = 'GrowAndShrink'
        $form.Padding = [System.Windows.Forms.Padding]::new(12)

        $layout = [System.Windows.Forms.FlowLayoutPanel]::new()
        $layout.FlowDirection = 'TopDown'
        $layout.AutoSize = $true
        $layout.WrapContents = $false
        $label = [System.Windows.Forms.Label]::new()
        $label.AutoSize = $true
        $label.MaximumSize = [System.Drawing.Size]::new(520, 0)
        $label.UseMnemonic = $false
        $label.Text = $Message
        $layout.Controls.Add($label)

        $buttons = [System.Windows.Forms.FlowLayoutPanel]::new()
        $buttons.AutoSize = $true
        $grant = [System.Windows.Forms.Button]::new()
        $grant.Text = 'Give PixelReader read access'
        $grant.AutoSize = $true
        $grant.DialogResult = 'Retry'
        $stop = [System.Windows.Forms.Button]::new()
        $stop.Text = 'Stop sharing'
        $stop.AutoSize = $true
        $stop.DialogResult = 'OK'
        $buttons.Controls.AddRange(@($stop, $grant))
        $layout.Controls.Add($buttons)
        $form.Controls.Add($layout)
        $form.AcceptButton = $stop
        $form.CancelButton = $stop
        $form.ShowDialog()
    } finally {
        $form.Dispose()
    }
}

function Grant-SelectedFolderAccess([string]$Folder) {
    $acl = Get-Acl -LiteralPath $Folder
    $rules = $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])
    $read = [Security.AccessControl.FileSystemRights]::ReadAndExecute
    if ($rules | Where-Object { $_.AccessControlType -eq 'Deny' -and ($_.FileSystemRights -band $read) }) {
        throw 'An NTFS deny rule on this folder covers read or execute access. Review its existing permissions in Windows Security.'
    }
    $null = & (Join-Path $PSScriptRoot 'Initialize-PixelReader.ps1') -LibraryPath $Folder -ExistingReaderOnly
}

function Show-ShareStatus([string]$Address, [string]$Folder, [string]$Account, [bool]$OfferGrant) {
    Add-Type -AssemblyName System.Windows.Forms
    $message = @"
$Address
$Folder

Read access for $Account

Keep this window open while the Pixel reads the folder. Verify backup in Google Photos and close any open previews before you stop sharing. The paired watcher will detach the folder.
"@
    $directory = [System.IO.DirectoryInfo]::new($Folder)
    if (-not $OfferGrant -or $Account -ne "$env:COMPUTERNAME\PixelReader" -or -not $directory.Parent -or
        [System.IO.DriveInfo]::new($directory.Root.FullName).DriveFormat -ne 'NTFS') {
        [void][System.Windows.Forms.MessageBox]::Show($message, 'PixelBackup is sharing', 'OK', 'Information')
        return
    }

    $message += "`r`n`r`nIf the Pixel cannot open this folder, close any open previews and choose Give PixelReader read access. This grants NTFS Read & execute on this folder and inheriting files and subfolders. The grant stays after sharing stops. The folder will reopen for a fresh scan."
    while ((Show-FolderAccessDialog $message) -eq 'Retry') {
        try {
            Grant-SelectedFolderAccess $Folder
            return 'Republish'
        } catch {
            [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'PixelBackup folder access', 'OK', 'Error')
        }
    }
}

function Publish-PixelFolder([string]$Folder, [string]$Account, [scriptblock]$OnShareReady, [bool]$OfferGrant = $true) {
    if ($Folder -notmatch '^[A-Za-z]:\\' -or
        [System.IO.DriveInfo]::new([System.IO.Path]::GetPathRoot($Folder)).DriveType -eq [System.IO.DriveType]::Network) {
        throw 'Select a folder on a local drive attached to this PC.'
    }
    $directory = Get-Item -LiteralPath $Folder -Force
    if (-not $directory.PSIsContainer) { throw 'Select an existing directory.' }
    $Folder = $directory.FullName
    $inspect = "Inspect session shares with Get-SmbShare -IncludeHidden | Where-Object Name -like 'PixelBackup-*' | Format-List Name,ScopeName,Path,Description,Temporary. A temporary share expires at the next Windows restart."
    $existing = @(Get-SmbShare -IncludeHidden | Where-Object { $_.Name -imatch '^PixelBackup-[0-9a-f]{32}$' })
    if ($existing.Count -gt 0) {
        throw "A session share already exists ($($existing.Name -join ', ')). $inspect"
    }

    $shareName = 'PixelBackup-' + [guid]::NewGuid().ToString('N')
    $ownershipTag = "PixelBackup picker $([guid]::NewGuid().ToString('N'))"
    $scope = '*'  # The default scope on a Windows PC, including a partially completed creation.
    try {
        $share = New-SmbShare -Name $shareName -Path $Folder -ReadAccess $Account -Temporary -CachingMode None -Description $ownershipTag
        $scope = $share.ScopeName
        $access = @(Get-SmbShareAccess -InputObject $share)
        if ($access.Count -ne 1 -or $access[0].AccountName -ne $Account -or
            $access[0].AccessControlType -ne 'Allow' -or $access[0].AccessRight -ne 'Read') {
            throw 'Windows reported unexpected share permissions. Closing the share.'
        }
        $address = "\\$env:COMPUTERNAME\$shareName"
        Write-Host "$address shares $Folder read-only for $Account (scope $scope, $ownershipTag)."
        if ($OnShareReady) {
            & $OnShareReady $share
        } else {
            Show-ShareStatus $address $Folder $Account $OfferGrant
        }
    } finally {
        try {
            $current = @(Get-SmbShare -IncludeHidden | Where-Object { $_.Name -eq $shareName -and $_.ScopeName -eq $scope })
            if ($current.Count -eq 1 -and $current[0].Description -ceq $ownershipTag -and $current[0].Path -eq $Folder) {
                Remove-SmbShare -InputObject $current[0] -Force
                Write-Host "Stopped sharing $Folder."
            } elseif ($current.Count -gt 0) {
                Write-Warning "The current share differs from this session. $inspect"
            }
        } catch {
            throw "Could not verify or finish cleanup of $shareName. $($_.Exception.Message) $inspect"
        }
    }
}

function Select-PhotoFolder {
    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.Application]::EnableVisualStyles()
    $picker = [System.Windows.Forms.FolderBrowserDialog]::new()
    try {
        $picker.Description = 'Select a local photo folder to share read-only with the Pixel.'
        $picker.ShowNewFolderButton = $false
        if ($picker.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $picker.SelectedPath }
    } finally {
        $picker.Dispose()
    }
}

function Start-PixelPicker([string]$Account, [string]$Folder, [scriptblock]$OnShareReady) {
    $isOwner = $false
    try {
        $pickerLock = [System.Threading.Mutex]::new($true, 'Global\PixelBackupGang.FolderPicker', [ref]$isOwner)
    } catch {
        throw "Windows could not reserve the PixelBackup picker on this PC. $($_.Exception.Message)"
    }
    try {
        if (-not $isOwner) { throw 'Another PixelBackup picker is already open on this PC.' }
        $readerAccount = Get-ReaderAccount $Account
        if (-not $Folder) { $Folder = Select-PhotoFolder }
        if (-not $Folder) { return }
        if ($OnShareReady) {
            Publish-PixelFolder $Folder $readerAccount $OnShareReady
            return
        }
        $action = Publish-PixelFolder $Folder $readerAccount
        if ($action -eq 'Republish') { Publish-PixelFolder $Folder $readerAccount -OfferGrant $false }
    } finally {
        if ($isOwner) { $pickerLock.ReleaseMutex() }
        $pickerLock.Dispose()
    }
}

try {
    Start-PixelPicker $Reader $Folder $OnShareReady
} catch {
    if (-not $OnShareReady) {
        Add-Type -AssemblyName System.Windows.Forms
        [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'PixelBackup', 'OK', 'Error')
    }
    throw
}
