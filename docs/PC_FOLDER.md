# Share a Windows folder with the Pixel

Pair the PC and phone once. After that, double-click **Select-PixelFolder.cmd**, choose a finished photo folder and leave the dialog open. The Pixel discovers the temporary read-only Windows share over Wi-Fi. Google Photos can back up its media while the originals stay on the PC.

## One-time Windows and Pixel setup

You need a folder on a local NTFS, exFAT, FAT or FAT32 drive, 64-bit Windows PowerShell 5.1, Android Platform Tools and a USB data cable for pairing. The installer targets a Magisk-rooted original Pixel or Pixel XL on stock Android 10 with SELinux enforcing. Its stock kernel supports FUSE. [Android Platform Tools](https://developer.android.com/tools/releases/platform-tools) · [Pixel kernel configuration](https://android.googlesource.com/kernel/msm/+/72a7a64494e033f2213c9701dbf137d277bf2026/arch/arm64/configs/marlin_defconfig)

1. Connect both devices to your private home network. On the PC run `ipconfig` and find the **IPv4 Address** of the Wi-Fi or Ethernet adapter the phone can reach. Use that PC address during pairing. Reserving it in your router keeps the pairing valid after restarts. Windows file sharing uses TCP 445. If Windows Firewall blocks the connection, restrict the inbound SMB permission to the **Private** profile and the Pixel's reserved LAN address. Keep SMB off internet port forwarding. [Windows file sharing](https://support.microsoft.com/en-us/windows/experience/connectivity-networking/file-sharing-over-a-network-in-windows)
2. Enable USB debugging on the Pixel. Connect it as the only USB phone, unlock its owner profile and approve the PC's debugging key. Open **Windows PowerShell as administrator** at the repository root and use the same window for all setup commands. ADB should print `sailfish` for the Pixel or `marlin` for the Pixel XL. [Android debugging setup](https://developer.android.com/tools/adb#Enabling)

   ```powershell
   $adb = (Get-Command adb.exe -ErrorAction SilentlyContinue).Source
   if (-not $adb) { $adb = Read-Host 'Full path to the extracted adb.exe' }
   & $adb -d shell getprop ro.product.device
   $tools = .\windows\Get-PixelTools.ps1
   ```

   The tool downloader fetches the pinned Android ARM64 rclone and FUSE helper from Termux, verifies their SHA-256 hashes and returns their local directory. If a personal Windows PC blocks local scripts under its default `Restricted` policy, run `powershell.exe -NoProfile -ExecutionPolicy RemoteSigned` in the elevated window and repeat step 2 in that shell. This setting lasts for that process. [Tool downloader](../windows/Get-PixelTools.ps1) · [Windows PowerShell execution policies](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_execution_policies?view=powershell-5.1)

3. Choose the narrowest library folder containing the albums you plan to share. Enter a dedicated password for the local Windows account `PixelReader`. If this setup already created the account, enter its existing password. On NTFS, the initializer grants the reader inheritable **Read & execute** on the selected folder. Children with separate permissions may need an explicit read grant. FAT-family drives have no per-file access lists. On those drives, read-only access for the Pixel is enforced at the SMB share. You can repeat the command for another library. [Reader setup](../windows/Initialize-PixelReader.ps1) · [Windows filesystem permissions](https://learn.microsoft.com/en-us/windows/win32/fileio/filesystem-functionality-comparison#security)

   ```powershell
   $library = Read-Host 'Full path to your existing photo library folder'
   $readerPassword = Read-Host 'Windows password for PixelReader' -AsSecureString
   .\windows\Initialize-PixelReader.ps1 -LibraryPath $library -Password $readerPassword
   $credential = [PSCredential]::new("$env:COMPUTERNAME\PixelReader", $readerPassword)
   ```

4. Pair with the **PC's LAN IPv4 address** from step 1. When Magisk asks, allow root for **Shell**. Keep the phone unlocked and connected until the installer finishes.

   ```powershell
   $pcAddress = Read-Host 'PC LAN IPv4 address reachable from your Pixel'
   .\windows\Install-PixelWatcher.ps1 -Adb $adb -ToolsDirectory $tools -ComputerAddress $pcAddress -Credential $credential
   ```

   The installer checks the Pixel can authenticate to SMB, starts the watcher and installs a Magisk boot script. After each reboot, unlock the Pixel's owner profile once. The watcher waits for the PC and a folder selection. Daily use works over Wi-Fi, so you can disconnect the USB cable after pairing. The reader's SMB password is stored in reversible rclone form in the phone's root-only `/data/adb/pixel-backup/rclone.conf`. [Installer](../windows/Install-PixelWatcher.ps1) · [Watcher startup](../android_client/start_pc_watcher.sh) · [rclone credential storage](https://rclone.org/commands/rclone_obscure/)

## Mount and verify

1. Put a previously unuploaded JPEG and a short MP4 directly inside a test folder in the prepared library. On the PC, double-click **windows/Select-PixelFolder.cmd**, accept the administrator prompt and select that folder. Keep Windows awake and leave the sharing dialog open. The watcher exposes the folder at `/storage/emulated/0/PixelBackup` and requests an Android media scan. Rclone reads the media with its file-content disk cache off. [Windows launcher](../windows/Select-PixelFolder.cmd) · [Mount helper](../android_client/mount_pc_folder.sh) · [rclone caching](https://rclone.org/commands/rclone_mount/#vfs-cache-mode-off)
2. On the Pixel, open Google Photos → **Collections → On this device** (older versions use **Library**). Open the test photo and play the video. Select the intended backup account, then go to **Photos settings → Backup → Back up device folders** and enable the test folder. For nested albums, check each folder Photos actually shows. A `.nomedia` file can suppress indexing in its folder and all descendants. [Google device-folder backup](https://support.google.com/photos/answer/6193313?co=GENIE.Platform%3DAndroid&hl=en) · [Android media indexing](https://developer.android.com/reference/android/provider/MediaStore#MEDIA_IGNORE_FILENAME)
3. On the phone, check **More → About → Details** for each item. Look for **Backed up**, **Original quality**, and the line saying the item uses no account storage. Use the same check with a paid Google One account. Its overall storage meter can look unchanged even if a small upload counts. If Photos omits the storage line, the item's quota treatment is unverified. In a PC browser signed into the same account, open **Recently added**, find both files and play the video. The web **Info** panel may also identify Android as the upload source. [Google Photos verification](https://support.google.com/photos/answer/6193313?co=GENIE.Platform%3DDesktop&hl=en) · [First-generation Pixel policy](https://support.google.com/photos/answer/6220791?co=GENIE.Platform%3DAndroid&hl=en)
4. After verifying backup, close open photo or video previews and click **Stop sharing** (or **OK**) in the Windows dialog. The picker removes that session's share. The phone detaches it and waits for the next selection. Double-click the launcher again to choose another folder. The read-only SMB permissions protect the PC originals. [Picker](../windows/Select-PixelFolder.ps1) · [Session watcher](../android_client/watch_pc_folders.sh)

On an original Pixel, Windows recorded signed SMB 3.1.1 reads over Wi-Fi from this picker. Google Photos uploaded the test JPEG and video and showed **Original quality** and zero account storage used for each. Both reopened from the Photos library after Windows stopped sharing the folder. [Wi-Fi JPEG receipt](evidence/wifi-jpeg.png) · [Wi-Fi video receipt](evidence/wifi-video.png) · [Hardware results](STORAGE_REVIEW.md#on-device-result)

## Later additions and connection changes

- If a new NTFS folder is unreadable, close any open previews and choose **Give PixelReader read access** in its sharing dialog. On eligible folders this grants the existing reader **Read & execute** on the selected folder and inheriting children, then republishes it for a fresh scan. The NTFS grant persists after the share closes. Simply selecting a folder makes no change to its filesystem permissions. [Picker access handling](../windows/Select-PixelFolder.ps1)
- Select finished albums when possible. If you add a file during a session, allow at least 15 seconds for rclone's directory cache to expire. If Photos still misses it, close previews and the picker, then reselect the folder for a fresh mount and scan. You can also request a scan over authorized USB with the command below. Check the item in Photos for its backup status. [Android 10 scanner](https://github.com/aosp-mirror/platform_packages_providers_mediaprovider/blob/android-10.0.0_r47/src/com/android/providers/media/scan/ModernMediaScanner.java#L232-L270)

  ```powershell
  & $adb -d shell am broadcast --user 0 -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d file:///storage/emulated/0/PixelBackup/
  ```

- When albums reuse names such as `IMG_0001.JPG`, select their common parent. The phone then sees distinct paths such as `TripA/IMG_0001.JPG` and `TripB/IMG_0001.JPG`. Android 10 can skip a replacement file if its path, size and modification time all match a previous item. [Android scanner change detection](https://github.com/aosp-mirror/platform_packages_providers_mediaprovider/blob/android-10.0.0_r47/src/com/android/providers/media/scan/ModernMediaScanner.java#L337-L367)
- If Windows or Wi-Fi goes offline, restore connectivity, leave one picker session open and allow the watcher to rediscover it. If the PC's LAN address changes, restore the reserved address or pair with its new one. The dedicated reader follows Windows password policy. Check its expiry in Windows PowerShell with `Get-LocalUser PixelReader | Select-Object PasswordExpires`. If the password changes or expires, update the account and re-pair the Pixel. The watcher stops after an explicit sign-in rejection.
- If a picker was force-closed, inspect the temporary shares with `Get-SmbShare -IncludeHidden | Where-Object Name -like 'PixelBackup-*' | Format-List Name,ScopeName,Path,Description,Temporary`. The share's description contains `PixelBackup picker` and a unique ID. The `Path` field identifies the selected folder. Windows clears temporary shares at its next restart. [Windows temporary SMB shares](https://learn.microsoft.com/en-us/powershell/module/smbshare/new-smbshare#-temporary)

## Re-pairing or removing the setup

End the current sharing session and close Photos previews. The installer creates `/data/adb/service.d/80-pixel-backup.sh` and installs `mount_pc_folder.sh`, `watch_pc_folders.sh`, `start_pc_watcher.sh`, `rclone.conf`, `.pairing-receipt`, `bin/rclone` and `bin/fusermount3` under `/data/adb/pixel-backup`. Inspect the boot script and directory listing as root. Keep the configuration and any backup of it readable only by root. Rerunning the installer verifies an existing pairing before starting the watcher. If USB staging was interrupted, its cleanup warning identifies the temporary directories for that attempt. [Magisk boot scripts](https://topjohnwu.github.io/Magisk/guides.html#boot-scripts)

To disable automatic startup, move just the verified boot script **outside** `/data/adb/service.d` and reboot the Pixel. To pair with a new address or credential, set aside the verified private installation directory after that reboot, then run the installer again with the new values. For permanent removal, remove the verified installation files you no longer need. On Windows, retire the dedicated local account if it was created for this pairing. First remove its explicit read rule on each prepared NTFS library under **Properties → Security → Advanced**. The default PC tool cache is `%LOCALAPPDATA%\PixelBackup\tools`. [Windows reader setup](../windows/Initialize-PixelReader.ps1)

## Alternative tool source

The Windows installer checks both executables against the pinned hashes. If the packages are unavailable from its download URL, recover those exact versions from a trusted Termux mirror or use the manual foreground watcher. Termux supplies rclone and its FUSE helper with `pkg install rclone`, `pkg install root-repo` and `pkg install libfuse3`. Run those package commands as the Termux app user. The versions tested on the Pixel were rclone 1.76.0 and fusermount3 3.18.3. [Termux installation](https://github.com/termux/termux-app#installation) · [rclone package](https://github.com/termux/termux-packages/blob/master/packages/rclone/build.sh) · [FUSE package](https://github.com/termux/termux-packages/blob/master/root-packages/libfuse3/build.sh)

For a manual foreground run, enter the global root mount namespace, use `umask 077`, and create a root-only `/data/adb/pixel-backup` directory. Put `watch_pc_folders.sh` and `mount_pc_folder.sh` there. Place verified copies of both executables in a root-owned directory on PATH. Run `rclone --config /data/adb/pixel-backup/rclone.conf config` and create a remote named `pixelpc` with backend `smb`, the PC's LAN address, `PixelReader`, the computer name as its domain and the reader password. Give the configuration mode 600. With the owner profile unlocked, start `/system/bin/sh /data/adb/pixel-backup/watch_pc_folders.sh`. Leave that terminal open and press Ctrl-C after the session ends. Use one watcher at a time. [Manual watcher](../android_client/watch_pc_folders.sh) · [rclone SMB settings](https://rclone.org/smb/) · [Global namespace setup](https://github.com/master-hax/pixel-backup-gang/blob/7c7c311/docs/EXTERNAL_DRIVES.md#setup)
