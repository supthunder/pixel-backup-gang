#Requires -Version 5.1
<#
.SYNOPSIS
    Prepare the two Android ARM64 executables used by the Pixel folder mount.
.EXAMPLE
    $tools = .\windows\Get-PixelTools.ps1
.EXAMPLE
    .\windows\Get-PixelTools.ps1 -Destination 'D:\Pixel tools'
.OUTPUTS
    The absolute path to the directory containing rclone and fusermount3.
#>
param(
    [ValidateNotNullOrEmpty()]
    [string]$Destination = (Join-Path $env:LOCALAPPDATA 'PixelBackup\tools')
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# Archive hashes are from the signed Termux aarch64 main/root package indexes.
# The November 2026 releases were verified with key CC72CF8BA7DBFA0182877D045A897D96E57CF20C.
$packages = @(
    @{
        Name = 'rclone'
        Url = 'https://packages.termux.dev/apt/termux-main/pool/main/r/rclone/rclone_1.76.0_aarch64.deb'
        ArchiveHash = 'b04924323468ffe2697784813690165f051d4413370a4db4c9ba0a53b868ad6a'
        BinaryHash = '2a99217da4e2e19c737fcc2cb42b41c3f679720aba12371684d498cab96e055e'
    },
    @{
        Name = 'fusermount3'
        Url = 'https://packages.termux.dev/apt/termux-root/pool/stable/libf/libfuse3/libfuse3_3.18.3_aarch64.deb'
        ArchiveHash = 'fcfe7f110621ba7f6c976110e51050e77d37e22ac9ef870ee3ac631f561d8f01'
        BinaryHash = '1b9dcc24088a2643cae4b2d723c5e9fe384dec74a49f562f1a2f789b5e1dac8c'
    }
)

function Assert-Sha256([string]$Path, [string]$Expected) {
    if ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ne $Expected) {
        throw "SHA-256 verification failed for $Path."
    }
}

$outputDir = [IO.Directory]::CreateDirectory($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Destination)).FullName
$missing = @(foreach ($package in $packages) {
    $target = Join-Path $outputDir $package.Name
    if (Test-Path -LiteralPath $target) { Assert-Sha256 $target $package.BinaryHash } else { $package }
})

if ($missing.Count -gt 0) {
    $tar = (Get-Command tar.exe -CommandType Application | Select-Object -First 1).Source
    $stage = [IO.Directory]::CreateDirectory((Join-Path $outputDir ('.download-' + [guid]::NewGuid().ToString('N')))).FullName
    $archive = Join-Path $stage 'package.deb'
    $data = Join-Path $stage 'data.tar.xz'
    try {
        foreach ($package in $missing) {
            try {
                Invoke-WebRequest -UseBasicParsing -Uri $package.Url -OutFile $archive -TimeoutSec 180
            } catch {
                throw "Could not fetch the pinned package at $($package.Url). See docs/PC_FOLDER.md for the Termux setup. $($_.Exception.Message)"
            }
            Assert-Sha256 $archive $package.ArchiveHash
            & $tar -xf $archive -C $stage data.tar.xz
            if ($LASTEXITCODE -ne 0) { throw "Could not extract data.tar.xz from $($package.Url)." }
            & $tar -xf $data -C $stage --strip-components 7 "./data/data/com.termux/files/usr/bin/$($package.Name)"
            if ($LASTEXITCODE -ne 0) { throw "Could not extract $($package.Name)." }
            Assert-Sha256 (Join-Path $stage $package.Name) $package.BinaryHash
        }
        foreach ($package in $missing) {
            $target = Join-Path $outputDir $package.Name
            try { [IO.File]::Move((Join-Path $stage $package.Name), $target) } catch [IO.IOException] {
                if (-not [IO.File]::Exists($target)) { throw }
                Assert-Sha256 $target $package.BinaryHash
            }
        }
    } finally {
        foreach ($name in @('package.deb', 'data.tar.xz', 'rclone', 'fusermount3')) {
            [IO.File]::Delete((Join-Path $stage $name))
        }
        [IO.Directory]::Delete($stage)
    }
}

$outputDir
