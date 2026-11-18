#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Share a selected PC folder read-only for one Pixel session.
.EXAMPLE
    .\windows\Select-PixelFolder.ps1 -Reader "$env:COMPUTERNAME\PixelReader"
.NOTES
    Run in 64-bit Windows PowerShell. Use an enabled local user with a password
    and permission to read the selected files. Pair the Pixel with this PC first.
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
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$Reader
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

function Show-ShareStatus([string]$Address, [string]$Folder, [string]$Account) {
    $message = @"
$Address
$Folder

Read access for $Account

Keep this window open while the Pixel reads the folder. After you verify backup in Google Photos and close any open previews, click OK to stop sharing. The paired watcher will detach the folder.
"@
    [void][System.Windows.Forms.MessageBox]::Show($message, 'PixelBackup is sharing', 'OK', 'Information')
}

function Publish-PixelFolder([string]$Folder, [string]$Account) {
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
        Show-ShareStatus $address $Folder $Account
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

function Start-PixelPicker([string]$Account) {
    $isOwner = $false
    try {
        $pickerLock = [System.Threading.Mutex]::new($true, 'Global\PixelBackupGang.FolderPicker', [ref]$isOwner)
    } catch {
        throw "Windows could not reserve the PixelBackup picker on this PC. $($_.Exception.Message)"
    }
    try {
        if (-not $isOwner) { throw 'Another PixelBackup picker is already open on this PC.' }
        $readerAccount = Get-ReaderAccount $Account
        $folderPath = Select-PhotoFolder
        if ($folderPath) { Publish-PixelFolder $folderPath $readerAccount }
    } finally {
        if ($isOwner) { $pickerLock.ReleaseMutex() }
        $pickerLock.Dispose()
    }
}

Start-PixelPicker $Reader
