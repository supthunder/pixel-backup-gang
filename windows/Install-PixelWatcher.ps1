#Requires -Version 5.1
<#
.SYNOPSIS
    Pair a USB-connected, rooted original Pixel to one Windows SMB reader.
.EXAMPLE
    .\windows\Install-PixelWatcher.ps1 -Adb 'C:\platform-tools\adb.exe' -ToolsDirectory $tools -ComputerAddress 192.168.1.10 -Credential $reader
.NOTES
    Unlock the owner's profile and authorize USB debugging and Magisk for Shell.
    Prepare the binaries with Get-PixelTools.ps1 and enable private LAN file sharing first.
    Re-running checks the existing pairing and starts its watcher. It refuses conflicting files.
#>
param(
    [Parameter(Mandatory)][string]$Adb,
    [Parameter(Mandatory)][string]$ToolsDirectory,
    [Parameter(Mandatory)][string]$ComputerAddress,
    [Parameter(Mandatory)][PSCredential]$Credential
)

$ErrorActionPreference = 'Stop'
$utf8 = [Text.UTF8Encoding]::new($false, $true)
$adbPath = (Get-Item -LiteralPath $Adb).FullName
$tools = (Get-Item -LiteralPath $ToolsDirectory).FullName
$scripts = Join-Path $PSScriptRoot '..\android_client'
$names = @('mount_pc_folder.sh', 'watch_pc_folders.sh', 'start_pc_watcher.sh', 'rclone', 'fusermount3')
$ip = $null
if (-not [Net.IPAddress]::TryParse($ComputerAddress, [ref]$ip) -or
    $ip.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or
    $ip.ToString() -ne $ComputerAddress -or $ip.GetAddressBytes()[0] -in @(0, 127) -or
    $ip.GetAddressBytes()[0] -ge 224) {
    throw 'Supply the Windows PC LAN address in dotted IPv4 notation.'
}
if ($Credential.UserName -notmatch '^([A-Za-z0-9_-]{1,63})\\PixelReader$' -or $Credential.Password.Length -eq 0) {
    throw 'Pass an individual COMPUTER\PixelReader credential with its nonempty Windows password.'
}
$domain = $Matches[1].ToUpperInvariant()
if ($domain -ne $env:COMPUTERNAME -or -not (Get-NetIPAddress -AddressFamily IPv4 -IPAddress $ComputerAddress -ErrorAction SilentlyContinue)) {
    throw 'Use this Windows computer name and one of its assigned LAN IPv4 addresses for the SMB reader.'
}

# Get-PixelTools checks its pinned package-member digests. Require the files
# up front so this installer only uses the already extracted Android binaries.
foreach ($toolName in @('rclone', 'fusermount3')) {
    if (-not [IO.File]::Exists((Join-Path $tools $toolName))) { throw "Prepare $toolName with Get-PixelTools.ps1 first." }
}
$null = & (Join-Path $PSScriptRoot 'Get-PixelTools.ps1') -Destination $tools
$files = foreach ($name in $names) {
    $isScript = $name.EndsWith('.sh')
    $parent = if ($isScript) { $scripts } else { $tools }
    $file = Get-Item -LiteralPath (Join-Path $parent $name)
    [pscustomobject]@{
        Local = $file.FullName
        Name = $name
        Target = if ($isScript) { $name } else { "bin/$name" }
        Hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

function Get-AdbText([string[]]$Arguments) {
    $result = & $adbPath @Arguments
    if ($LASTEXITCODE -ne 0) { throw "ADB failed during $($Arguments[0]). Check the USB cable and authorization on the Pixel." }
    ($result -join "`n").Trim()
}

# Pin all later operations to the initial USB transport, even if another
# phone connects, disconnects or reuses its serial during provisioning.
$serial = Get-AdbText @('-d', 'get-serialno')
if ($serial -notmatch '^[A-Za-z0-9_.-]+$' -or $serial -eq 'unknown') { throw 'Connect one authorized physical Pixel over USB.' }
$listing = Get-AdbText @('devices', '-l')
$deviceLine = [regex]::Match($listing, '(?m)^' + [regex]::Escape($serial) + '\s+device\b[^\r\n]*\btransport_id:(\d+)\s*$')
if (-not $deviceLine.Success) { throw 'ADB could not pin the authorized USB device. Update Android Platform Tools and reconnect.' }
$transport = $deviceLine.Groups[1].Value

function Invoke-Phone([string]$Command, [byte[]]$InputBytes, [int]$TimeoutSeconds = 120) {
    # These are fixed command templates. ADB gets one remote command and the
    # stdin bytes directly, independent of PowerShell's native-pipeline encoding.
    if ($Command.Contains('"') -or $Command.Contains("`n")) { throw 'Invalid internal ADB command.' }
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $adbPath
    $info.Arguments = "-t $transport shell -T `"$Command`""
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $p = [Diagnostics.Process]::new()
    $p.StartInfo = $info
    try {
        if (-not $p.Start()) { throw 'Could not start USB ADB.' }
        $output = $p.StandardOutput.ReadToEndAsync()
        $errors = $p.StandardError.ReadToEndAsync()
        try {
            if ($InputBytes.Length) { $p.StandardInput.BaseStream.Write($InputBytes, 0, $InputBytes.Length) }
        } finally {
            $p.StandardInput.BaseStream.Close()
        }
        if (-not $p.WaitForExit($TimeoutSeconds * 1000)) {
            $p.Kill()
            throw 'The Pixel did not finish the USB operation. Check the phone for a Magisk authorization prompt.'
        }
        $stdout = $output.GetAwaiter().GetResult()
        $stderr = $errors.GetAwaiter().GetResult()
        if ($p.ExitCode -ne 0) {
            # Only our own fixed diagnostics are suitable for printing during credential setup.
            $diagnostic = (($stderr + "`n" + $stdout) -split '\r?\n' | Where-Object { $_ -like 'Pixel pairing: *' } | Select-Object -Last 1)
            if ($diagnostic) { throw $diagnostic }
            throw 'The USB operation failed. Check device connectivity and grant Magisk root to Shell.'
        }
        $stdout.Trim()
    } finally { $p.Dispose() }
}

function ConvertTo-ShellBytes([string]$Text) {
    ,$utf8.GetBytes(($Text.Replace("`r`n", "`n").TrimEnd("`r", "`n")) + "`n")
}

$preflight = @'
set -eu
fail() { echo "Pixel pairing: $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] && magisk -V >/dev/null 2>&1 || fail 'Grant Magisk root to the USB Shell.'
device=$(getprop ro.product.device)
case "$device/$(getprop ro.product.model)" in 'sailfish/Pixel'|'marlin/Pixel XL') ;; *) fail 'Expected a 2016 Pixel or Pixel XL.' ;; esac
[ "$(getprop ro.product.brand)" = google ] && [ "$(getprop ro.product.manufacturer)" = Google ] &&
    [ "$(getprop ro.product.cpu.abi)" = arm64-v8a ] && [ "$(getprop ro.build.version.sdk)" = 29 ] &&
    [ "$(getprop ro.kernel.qemu)" != 1 ] && [ "$(getprop ro.boot.qemu)" != 1 ] ||
    fail 'Expected a physical Google Pixel running stock Android 10.'
case "$(getprop ro.build.fingerprint)" in "google/$device/$device:10/"*":user/release-keys") ;; *) fail 'Expected the stock Google Android 10 build fingerprint.' ;; esac
[ "$(getenforce)" = Enforcing ] && [ -c /dev/fuse ] || fail 'The phone needs enforcing SELinux and FUSE.'
[ "$(getprop sys.boot_completed)" = 1 ] && [ "$(am get-current-user)" = 0 ] &&
    [ "$(am get-started-user-state 0)" = RUNNING_UNLOCKED ] || fail 'Unlock the owner profile on the Pixel.'
[ -d /data/adb ] && [ ! -L /data/adb ] && [ "$(stat -c %u /data/adb)" = 0 ] || fail 'Expected the Magisk root data directory.'
if [ -e /data/adb/pixel-backup ] || [ -L /data/adb/pixel-backup ]; then echo CHECK; else echo NEW; fi
'@
$mode = Invoke-Phone 'su -c /system/bin/sh' (ConvertTo-ShellBytes $preflight)
if ($mode -notin @('NEW', 'CHECK')) { throw 'Unexpected response from the rooted Pixel preflight.' }
$id = [guid]::NewGuid().ToString('N')
$rootStage = "/data/adb/.pixel-backup-pair-$id"
$usbStage = "/data/local/tmp/.pixel-backup-pair-$id"
$records = ($files | ForEach-Object { "$($_.Target) $($_.Hash)" }) -join "`n"

$install = @'
set -eu
umask 077
unset LD_PRELOAD
export LD_LIBRARY_PATH=/system/lib64:/apex/com.android.runtime/lib64/bionic
fail() { echo "Pixel pairing: $*" >&2; exit 1; }
base=/data/adb/pixel-backup
stage=__ROOT_STAGE__
usb=__USB_STAGE__
service=/data/adb/service.d
hook=$service/80-pixel-backup.sh
bundle=$stage/bundle
private_file() { [ -f "$1" ] && [ ! -L "$1" ] && [ "$(stat -c '%u:%g:%a' "$1")" = "0:0:$2" ]; }
private_dir() { [ -d "$1" ] && [ ! -L "$1" ] && [ "$(stat -c '%u:%g:%a' "$1")" = '0:0:700' ]; }
digest() { line=$(sha256sum "$1") || return 1; echo "${line%% *}"; }
exists() { [ -e "$1" ] || [ -L "$1" ]; }
exec 8>>/mnt/.pixel-backup-pair.lock
flock -n 0 <&8 || fail 'Another Pixel pairing is in progress.'
IFS= read -r proof || fail 'Credential input was interrupted.'
case "$proof" in *[!a-f0-9]*|'') fail 'Invalid credential framing.' ;; esac
[ "${#proof}" -eq 64 ] || fail 'Invalid credential framing.'

cat >"$stage/hook" <<'HOOK'
#!/system/bin/sh
# Pixel Backup Gang boot launcher
exec /system/bin/sh /data/adb/pixel-backup/start_pc_watcher.sh
HOOK
chmod 700 "$stage/hook"
if exists "$service"; then
    [ -d "$service" ] && [ ! -L "$service" ] && [ "$(stat -c %u:%g "$service")" = 0:0 ] ||
        fail 'Inspect the existing Magisk service.d directory and its ownership.'
    # In Android mksh a leading zero does not select octal arithmetic.
    case "$(stat -c %a "$service")" in
        *[2367][0-7]|*[2367]) fail 'The existing Magisk service.d directory permits group or other writes.' ;;
    esac
fi
if exists "$hook"; then
    private_file "$hook" 700 && cmp -s "$stage/hook" "$hook" || fail 'A different Magisk service already occupies 80-pixel-backup.sh.'
fi

if exists "$base"; then
    private_dir "$base" && private_dir "$base/bin" && private_file "$base/.pairing-receipt" 600 &&
        private_file "$base/rclone.conf" 600 || fail 'Existing Pixel Backup files have no matching private pairing receipt. Inspect them before re-pairing.'
    active=$base
else
    [ -d "$usb" ] || fail 'Pairing state changed. Run the installer again.'
    mkdir "$bundle" "$bundle/bin"
    active=$bundle
fi
while read -r path expected; do
    if [ "$active" = "$bundle" ]; then
        incoming="$usb/${path##*/}"
        [ -f "$incoming" ] && [ ! -L "$incoming" ] || fail "Missing staged $path."
        mv "$incoming" "$active/$path"
        chown 0:0 "$active/$path"
        chmod 700 "$active/$path"
    fi
    private_file "$active/$path" 700 && [ "$(digest "$active/$path")" = "$expected" ] ||
        fail "Installed or staged $path differs from the verified release."
done <<'FILES'
__RECORDS__
FILES
if [ "$active" = "$bundle" ]; then
    cat >"$active/rclone.conf" <<'CONFIG'
[pixelpc]
type = smb
host = __ADDRESS__
user = PixelReader
domain = __DOMAIN__
CONFIG
    printf 'pass = ' >>"$active/rclone.conf"
    "$active/bin/rclone" obscure - >>"$active/rclone.conf" 2>/dev/null || fail 'The verified Android rclone could not read the credential.'
else
    # Consume the rest of the credential frame without saving or echoing it.
    cat >/dev/null
fi
printf 'pixel-backup-v1\n%s\n%s\n' "$(digest "$active/rclone.conf")" "$proof" >"$stage/expected-receipt"
if [ "$active" = "$base" ]; then
    cmp -s "$base/.pairing-receipt" "$stage/expected-receipt" ||
        fail 'The paired PC, reader credential, or installed configuration differs. Existing files were preserved.'
else
    mv "$stage/expected-receipt" "$active/.pairing-receipt"
fi
"$active/bin/fusermount3" --version >/dev/null 2>&1 || fail 'The verified FUSE helper cannot run on this build.'
timeout 25 "$active/bin/rclone" lsf pixelpc: --config "$active/rclone.conf" --dirs-only --max-depth 1 \
    --ask-password=false --contimeout 5s --timeout 8s --retries 1 --low-level-retries 1 >/dev/null 2>&1 ||
    fail 'SMB sign-in or share discovery failed. Check the PC address, password, private-network firewall and file sharing.'
if [ "$active" = "$bundle" ]; then mv "$bundle" "$base"; fi
if ! exists "$service"; then mkdir "$service"; fi
if ! exists "$hook"; then mv "$stage/hook" "$hook"; fi
private_file "$hook" 700 && private_file "$base/.pairing-receipt" 600 || fail 'Could not verify the boot installation.'
/system/bin/sh "$base/start_pc_watcher.sh" || fail 'The watcher launcher failed.'
watcher_ready() {
    # Magisk may place this installer in a different namespace. Inspect
    # PID 1's lock and the descriptor the genuine watcher keeps open.
    lock=/proc/1/root/mnt/.pixel-backup-watcher.lock
    [ -f "$lock" ] && [ ! -L "$lock" ] || return 1
    if flock -n 0 <"$lock"; then return 1; fi
    inode=$(stat -L -c '%d:%i' "$lock") || return 1
    global=$(readlink /proc/1/ns/mnt) || return 1
    for pid in $(pgrep -f 'watch_pc_folders[.]sh'); do
        [ "$(stat -c %u "/proc/$pid" 2>/dev/null)" = 0 ] &&
            [ "$(readlink "/proc/$pid/ns/mnt" 2>/dev/null)" = "$global" ] &&
            [ "$(stat -L -c '%d:%i' "/proc/$pid/fd/8" 2>/dev/null)" = "$inode" ] || continue
        args=$(tr '\000' '\n' <"/proc/$pid/cmdline" 2>/dev/null) || continue
        case "$args" in
            "/system/bin/sh
$base/watch_pc_folders.sh"|"sh
$base/watch_pc_folders.sh") return 0 ;;
        esac
    done
    return 1
}
seconds=0
until watcher_ready; do
    [ "$seconds" -lt 20 ] || fail 'Files and boot hook are installed, but the global watcher did not hold its lock. Check the phone and run pairing again.'
    sleep 1
    seconds=$((seconds + 1))
done
echo PAIRED
'@
$install = $install.Replace('__ROOT_STAGE__', $rootStage).Replace('__USB_STAGE__', $usbStage).Replace('__RECORDS__', $records).Replace('__ADDRESS__', $ComputerAddress).Replace('__DOMAIN__', $domain)
$rootCreated = $false
$usbCreated = $false
try {
    $null = Invoke-Phone "su -c 'umask 077 && mkdir $rootStage'" @()
    $rootCreated = $true
    if ($mode -eq 'NEW') {
        $null = Invoke-Phone "umask 077 && mkdir $usbStage" @()
        $usbCreated = $true
        foreach ($file in $files) {
            $null = Get-AdbText @('-t', $transport, 'push', $file.Local, "$usbStage/$($file.Name)")
        }
    }
    $null = Invoke-Phone "su -c 'cat > $rootStage/provision.sh'" (ConvertTo-ShellBytes $install)
    # A private pairing receipt detects a different password on a later run
    # without sending the stored rclone password back to the PC.
    $bstr = [IntPtr]::Zero
    $chars = $password = $frame = $kdf = $null
    try {
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Credential.Password)
        $chars = [char[]]::new($Credential.Password.Length)
        [Runtime.InteropServices.Marshal]::Copy($bstr, $chars, 0, $chars.Length)
        if ($chars -contains [char]0 -or $chars -contains [char]10 -or $chars -contains [char]13) {
            throw 'Use a Windows reader password without NUL or line breaks.'
        }
        $password = $utf8.GetBytes($chars)
        $salt = $utf8.GetBytes("PixelBackup-v1|$serial|$ComputerAddress|$domain|PixelReader")
        $kdf = [Security.Cryptography.Rfc2898DeriveBytes]::new($password, $salt, 150000, [Security.Cryptography.HashAlgorithmName]::SHA256)
        $proof = [BitConverter]::ToString($kdf.GetBytes(32)).Replace('-', '').ToLowerInvariant()
        $prefix = $utf8.GetBytes($proof + "`n")
        $frame = [byte[]]::new($prefix.Length + $password.Length)
        [Array]::Copy($prefix, $frame, $prefix.Length)
        [Array]::Copy($password, 0, $frame, $prefix.Length, $password.Length)
        $result = Invoke-Phone "su -c '/system/bin/sh $rootStage/provision.sh'" $frame
    } finally {
        if ($frame) { [Array]::Clear($frame, 0, $frame.Length) }
        if ($password) { [Array]::Clear($password, 0, $password.Length) }
        if ($chars) { [Array]::Clear($chars, 0, $chars.Length) }
        if ($kdf) { $kdf.Dispose() }
        if ($bstr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    }
    if ($result -ne 'PAIRED') { throw 'The Pixel returned an unexpected installation status.' }
    Write-Output "Verified the running Pixel watcher for $domain\PixelReader at $ComputerAddress."
} finally {
    # Enumerate the known temporary names. Leave unrelated or unexpected files alone.
    $cleanup = "set -e`n"
    if ($usbCreated) { $cleanup += "`nrm -f " + (($names | ForEach-Object { "$usbStage/$_" }) -join ' ') + "`nrmdir $usbStage`n" }
    if ($rootCreated) {
        $temporary = @('hook', 'expected-receipt', 'provision.sh', 'bundle/.pairing-receipt', 'bundle/rclone.conf') + @($files | ForEach-Object { "bundle/$($_.Target)" })
        $cleanup += "`nrm -f " + (($temporary | ForEach-Object { "$rootStage/$_" }) -join ' ') + "`n"
        $cleanup += "for d in $rootStage/bundle/bin $rootStage/bundle $rootStage; do if [ -d `"`$d`" ]; then rmdir `"`$d`"; fi; done`n"
    }
    if ($rootCreated -or $usbCreated) {
        try { $null = Invoke-Phone 'su -c /system/bin/sh' (ConvertTo-ShellBytes $cleanup) }
        catch { Write-Warning "USB staging cleanup was interrupted. Inspect $rootStage and $usbStage on the original Pixel." }
    }
}
