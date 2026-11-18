#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Prepare the Windows reader and a local photo library for Pixel Backup Gang.
.EXAMPLE
    .\windows\Initialize-PixelReader.ps1 -LibraryPath 'D:\Photo Library'
.NOTES
    Run in elevated, 64-bit Windows PowerShell. The new account stays local
    and the password is prompted for securely unless passed as a SecureString.
    The script reuses its own enabled standard reader without changing its
    password. Choose the parent of the folders you intend to share.
    NTFS folders get an inheritable read rule. For FAT, FAT32 and exFAT, the
    picker enforces read-only access through the SMB share.
    Use -ExistingReaderOnly to prepare another folder for an already paired PC.
#>
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$LibraryPath,

    [Security.SecureString]$Password,

    [switch]$ExistingReaderOnly
)

$ErrorActionPreference = 'Stop'

function Get-LibraryDirectory([string]$Path) {
    if ($Path -notmatch '^[A-Za-z]:[\\/]') {
        throw 'Enter an absolute path to a photo library on a local drive.'
    }
    $directory = Get-Item -LiteralPath $Path -Force
    if ($directory -isnot [System.IO.DirectoryInfo] -or $null -eq $directory.Parent) {
        throw 'Select an existing directory inside the drive.'
    }
    for ($ancestor = $directory; $null -ne $ancestor; $ancestor = $ancestor.Parent) {
        if ($ancestor.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
            throw "The library path passes through a junction, link, or other reparse point at $($ancestor.FullName)."
        }
    }
    $drive = [System.IO.DriveInfo]::new($directory.Root.FullName)
    if ($drive.DriveType -notin @('Fixed', 'Removable')) {
        throw 'Select a photo library on a fixed or removable drive attached to this PC.'
    }
    $fileSystem = $drive.DriveFormat
    if ($fileSystem -notin @('NTFS', 'exFAT', 'FAT', 'FAT32')) {
        throw 'Select an NTFS, exFAT, FAT or FAT32 photo library.'
    }
    [pscustomobject]@{
        Path = $directory.FullName
        FileSystem = $fileSystem
    }
}

function Confirm-DedicatedReader($Reader, [string]$Description) {
    if (-not $Reader.Enabled -or $Reader.PrincipalSource -ne 'Local' -or
        $Reader.Description -cne $Description -or
        $Reader.SID.IsWellKnown([Security.Principal.WellKnownSidType]::AccountGuestSid) -or
        $Reader.SID.IsWellKnown([Security.Principal.WellKnownSidType]::AccountAdministratorSid)) {
        throw 'PixelReader already exists and is disabled or differs from the dedicated account created by this script.'
    }

    # The standard Users group has a fixed SID across Windows languages.
    foreach ($group in Get-LocalGroup | Where-Object { $_.SID.Value -ne 'S-1-5-32-545' }) {
        $members = Get-LocalGroupMember -SID $group.SID
        if ($members | Where-Object { $_.SID -eq $Reader.SID }) {
            throw "PixelReader belongs to $($group.Name). Use an ordinary account reserved for this pairing."
        }
    }
}

function Add-LibraryReadRule([string]$Path, $Acl, [Security.Principal.SecurityIdentifier]$Sid) {
    $rights = [Security.AccessControl.FileSystemRights]::ReadAndExecute
    $inheritance = [Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit'
    $propagation = [Security.AccessControl.PropagationFlags]::None
    $allow = [Security.AccessControl.AccessControlType]::Allow
    $rules = $Acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])
    $existingRule = $rules | Where-Object {
        $_.IdentityReference -eq $Sid -and $_.AccessControlType -eq $allow -and
        ($_.FileSystemRights -band $rights) -eq $rights -and
        $_.InheritanceFlags -eq $inheritance -and $_.PropagationFlags -eq $propagation
    }
    if ($existingRule) { return $false }

    $rule = [Security.AccessControl.FileSystemAccessRule]::new($Sid, $rights, $inheritance, $propagation, $allow)
    $Acl.AddAccessRule($rule)
    Set-Acl -LiteralPath $Path -AclObject $Acl
    $true
}

if (-not [Environment]::Is64BitProcess) {
    throw 'Run this script in 64-bit Windows PowerShell.'
}
$library = Get-LibraryDirectory $LibraryPath
$acl = $null
if ($library.FileSystem -eq 'NTFS') {
    $acl = Get-Acl -LiteralPath $library.Path
    if (-not $acl.AreAccessRulesCanonical) {
        throw 'Windows must repair the order of the existing library permissions before they can be extended.'
    }
}

$description = 'Pixel Backup Gang dedicated reader'
$reader = Get-LocalUser | Where-Object Name -eq 'PixelReader'
$accountCreated = $false
if ($reader) {
    Confirm-DedicatedReader $reader $description
} else {
    if ($ExistingReaderOnly) { throw 'PixelReader is missing. Run the Windows pairing setup first.' }
    $prompted = -not $PSBoundParameters.ContainsKey('Password')
    if ($prompted) { $Password = Read-Host -Prompt 'Choose a new Windows password for PixelReader' -AsSecureString }
    try {
        if (-not $Password -or $Password.Length -eq 0) { throw 'PixelReader requires a nonempty password.' }
        $reader = New-LocalUser -Name 'PixelReader' -Password $Password -Description $description
        $accountCreated = $true
    } finally {
        if ($prompted -and $Password) { $Password.Dispose() }
    }
}

$accessAdded = $false
if ($acl) {
    $accessAdded = Add-LibraryReadRule $library.Path $acl $reader.SID
}
[pscustomobject]@{
    ComputerName = $env:COMPUTERNAME
    Reader = "$env:COMPUTERNAME\$($reader.Name)"
    LibraryPath = $library.Path
    AccountCreated = $accountCreated
    AccessAdded = $accessAdded
}
