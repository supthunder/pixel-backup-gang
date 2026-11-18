# Share a Windows folder with the Pixel

This pilot exposes one local Windows folder, including existing subdirectories, to the owner profile on a rooted Android 10 Pixel. Keep Windows awake and the phone powered during the session. The Windows picker gives each session a unique SMB share name. The phone watches that PC for a new session and presents each selection at the same Android path. The watcher runs in the foreground and can stay ready between batches.

## One-time Windows setup

1. Create an ordinary, password-backed local Windows user named `PixelReader`. Give that user **Read & execute**, **List folder contents**, and **Read** in the selected test folder’s **Properties → Security**, including the files and subfolders. For later selections, inherited read permission on the photo-library parent can cover its albums. The picker grants read access at the SMB share level. Windows also applies the folder’s existing filesystem permissions. [Windows local accounts](https://support.microsoft.com/en-us/windows/security/identity-signin/manage-user-accounts-in-windows) · [Windows file sharing](https://support.microsoft.com/en-us/windows/experience/connectivity-networking/file-sharing-over-a-network-in-windows)
2. Use your private home network. The phone must be able to reach Windows file sharing, normally TCP 445. If the firewall blocks it, scope the private-network file-sharing rule to the phone’s reserved LAN address. Keep the share off internet port forwarding. Note the PC's LAN address and computer name for the phone configuration.
3. In elevated, 64-bit **Windows PowerShell**, run the picker from the repository root. For the first session, pick a folder with a previously unuploaded JPEG and a short MP4 directly inside it. Keep the status dialog open.

   ```powershell
   .\windows\Select-PixelFolder.ps1 -Reader "$env:COMPUTERNAME\PixelReader"
   ```

   For recurring use, a Windows shortcut can open this script with the same reader argument. Set the shortcut to run as administrator so Windows can create the session share.

   The picker uses Windows' SMB service, verifies that the share grants the named reader read-only access, and leaves the selected files in place. An existing share matching the pilot’s session name causes it to stop. Normal dialog closure removes the share created by that session. After an abrupt process exit, inspect `Get-SmbShare | Where-Object Name -like 'PixelBackup-*' | Format-List Name,Path,ScopeName,Description,Temporary` before taking action. A temporary share expires when Windows restarts. [Microsoft SMB share behavior](https://learn.microsoft.com/en-us/powershell/module/smbshare/new-smbshare#-temporary)

## One-time Pixel setup

The phone needs Magisk root, an Android build of rclone with the SMB backend, and its matching FUSE helper. The stock `QP1A.191005.007.A3` kernel already includes FUSE. To identify a phone connected by USB, use `adb -d shell getprop ro.product.device` and `adb -d shell getprop ro.build.id`. When Android asks, authorize your own PC on the phone. [Android Platform Tools](https://developer.android.com/tools/releases/platform-tools) · [Stock kernel](https://android.googlesource.com/kernel/msm/+/72a7a64494e033f2213c9701dbf137d277bf2026/arch/arm64/configs/marlin_defconfig)

1. One maintained source of compatible userspace packages is Termux. Install Termux from a supported distribution channel, then run these commands as its ordinary app user. The tested Android versions were rclone 1.76.0 and fusermount3 3.18.3. The `libfuse3` package provides the helper. An older rclone 1.60.1 client could read a known share in our Linux test but failed to discover share names on a server requiring SMB signing. The older Magisk module linked in the original SMB report is archived. [Termux installation](https://github.com/termux/termux-app#installation) · [rclone package](https://github.com/termux/termux-packages/blob/master/packages/rclone/build.sh) · [FUSE helper package](https://github.com/termux/termux-packages/blob/master/root-packages/libfuse3/build.sh)

   ```sh
   pkg install rclone
   pkg install root-repo
   pkg install libfuse3
   ```

2. From the Windows checkout, copy both scripts to the phone and open an interactive shell.

   ```powershell
   adb -d push android_client/mount_pc_folder.sh /data/local/tmp/pbg-mount-pc-folder.sh
   adb -d push android_client/watch_pc_folders.sh /data/local/tmp/pbg-watch-pc-folders.sh
   adb -d shell
   ```

3. In the phone shell, enter Magisk's global mount namespace and prepare a private configuration directory. Grant **Shell** root in Magisk if asked. On stock builds where the namespace check fails, use `nsenter -t 1 -m -- /system/bin/sh` from the root shell and set the PATH again. [MagiskSU options](https://topjohnwu.github.io/Magisk/tools.html#magisksu) · [Upstream namespace setup](https://github.com/master-hax/pixel-backup-gang/blob/7c7c311/docs/EXTERNAL_DRIVES.md#setup)

   ```sh
   su -mm
   umask 077
   export PATH="$PATH:/data/data/com.termux/files/usr/bin"
   mkdir -p /data/adb/pixel-backup
   chmod 700 /data/adb/pixel-backup
   cp /data/local/tmp/pbg-mount-pc-folder.sh /data/adb/pixel-backup/mount_pc_folder.sh
   cp /data/local/tmp/pbg-watch-pc-folders.sh /data/adb/pixel-backup/watch_pc_folders.sh
   chmod 700 /data/adb/pixel-backup/mount_pc_folder.sh /data/adb/pixel-backup/watch_pc_folders.sh
   command -v rclone
   command -v fusermount3
   rclone --config /data/adb/pixel-backup/rclone.conf config
   ```

4. In rclone's interactive configuration, create a remote named `pixelpc`. Select backend `smb`, set the host to the PC's LAN address, use `PixelReader` as the user, the computer name as its local account domain, and enter the reader’s password at the prompt. Save the remote. Rclone's stored password is reversible, so keep the config in the root-only directory. Confirm rclone lists the `PixelBackup-…` session shown in the open Windows dialog.

   ```sh
   chmod 600 /data/adb/pixel-backup/rclone.conf
   rclone --config /data/adb/pixel-backup/rclone.conf lsf pixelpc: --dirs-only --dir-slash=false
   ```

   A listing verifies SMB authentication. The next step checks the separate Android storage view. [rclone SMB settings](https://rclone.org/smb/) · [rclone credential storage](https://rclone.org/commands/rclone_obscure/)

## Mount and verify

1. With the owner profile unlocked, start the watcher in the global root shell. It can start before or after the PC picker. Use a terminal on the phone if you want to unplug the debugging cable. After a phone restart, unlock it and start the watcher again with the same `su -mm` and PATH setup.

   ```sh
   /system/bin/sh /data/adb/pixel-backup/watch_pc_folders.sh
   ```

   The watcher polls the paired PC for session share names. A new session starts the mount helper, which uses a read-only rclone mount with its file-content disk cache off. It presents the mount in Android's app storage views, checks it can list `/storage/emulated/0/PixelBackup`, and requests an Android media scan. It refuses to cover an occupied mount point or a populated local directory. [Session watcher](../android_client/watch_pc_folders.sh) · [Mount helper](../android_client/mount_pc_folder.sh) · [rclone cache behavior](https://rclone.org/commands/rclone_mount/#vfs-cache-mode-off)
2. On the Pixel, open Google Photos → **Collections → On this device** (older versions use **Library**). Find the test folder, open the JPEG and play or seek in the video. Enable **Backup** for that device folder under the intended Google account. For nested albums, check the folders Photos actually shows. Open each sample’s **More → About → Details** and look for **Backed up**. A `.nomedia` file in a folder or its ancestors can suppress discovery. [Google device-folder backup](https://support.google.com/photos/answer/6193313?co=GENIE.Platform%3DAndroid&hl=en) · [Android media indexing](https://developer.android.com/reference/android/provider/MediaStore#MEDIA_IGNORE_FILENAME)
3. In a PC browser signed into the same account, find the two items on Google Photos using **Recently added** if their capture dates are old. Open each item and its **Info** panel. Verify Original quality, play the video, and record the upload source and storage-charge message when shown. The source may say “Uploaded from Android device”. The camera model in EXIF identifies the camera that captured the file. A clear per-item statement that it uses no account storage is evidence for that item. If Google omits the charge detail, leave quota unverified. An unchanged aggregate storage meter or a local thumbnail is insufficient. [Google’s web verification instructions](https://support.google.com/photos/answer/6193313?co=GENIE.Platform%3DDesktop&hl=en)
4. Add one more previously unuploaded file on the PC after the mount starts. The folder listing cache expires after 15 seconds. If an item is missing, wait for that interval, then in a second phone shell request another scan. Android 10 can walk the folder on a scan. The broadcast completion is a request acknowledgement. Reopen Photos and repeat the per-item checks. For a large library, start with one album and measure the time until a representative video is available online. [Android 10 media scanner](https://github.com/aosp-mirror/platform_packages_providers_mediaprovider/blob/android-10.0.0_r47/src/com/android/providers/media/scan/ModernMediaScanner.java#L232-L270)

   ```sh
   am broadcast --user 0 -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d file:///storage/emulated/0/PixelBackup/
   ```

5. Once the items are verified, close any app preview reading the mount and click OK in the Windows dialog. The watcher detaches and waits for the next selection. To switch folders, launch the picker again. To end the watcher itself, press Ctrl-C in its terminal and allow time for open file handles to close. The Windows share permission protects the originals even if a phone app offers to free up space. If the phone helper was force-killed and its mount is still occupied, a phone restart clears the temporary mounts.

### Scope of the pilot

If you already have a read-only share on a PC or NAS, you can also run the mount helper with its configured rclone path, for example `/system/bin/sh /data/adb/pixel-backup/mount_pc_folder.sh pixelpc:FamilyPhotos`. End that manual foreground mount with Ctrl-C. Use one mount at a time.

On a physical `sailfish` running `QP1A.191005.007.A3`, the current watcher and mount helper discovered a real SMB share, exposed both PC files to Android and indexed them in MediaStore. Google Photos automatically backed up both and showed Original quality and zero account storage for each. SMB traveled through an authenticated USB debugging connection to a test server on the PC. The Pixel could also open a Wi-Fi TCP connection to native Windows file sharing. Both items also appeared in the main Photos library after the share was disconnected. The per-item receipts come from the phone. The available desktop browser was signed into a different Google account. [Hardware results and receipts](STORAGE_REVIEW.md#on-device-result)

An independent integration test used an authenticated Samba share on the PC, the actual shell helper under mksh, real rclone/FUSE and simulated Android storage views in Linux. An unprivileged process read a generated JPEG and MP4 with hashes matching the PC originals. Attempts to open them for writing returned a read-only filesystem error. Switching between two picker sessions replaced the visible contents and closing the session detached the mount. A later file appeared after the 15-second directory cache expired. Windows PowerShell checks exercised the picker's share creation, permission checks and cleanup using simulated SMB cmdlets. Creating an actual Windows SMB share requires an elevated desktop session.

After initial setup, selecting a folder on the PC triggers mounting and the initial scan while the watcher is running. Files added during an open session may need the rescan above. Start with finished albums to avoid scanning a file while Windows is still writing it. The pilot reports sharing and mounting. Confirm cloud backup and storage treatment in Google Photos. [Evidence and alternatives](STORAGE_REVIEW.md)

If two albums reuse names such as `IMG_0001.JPG`, select their common parent so Android sees `TripA/IMG_0001.JPG` and `TripB/IMG_0001.JPG` under distinct paths. Selecting each album separately gives both files the same path on the phone. Android 10's scanner can skip a different file at that path if its size and modification time also match. [Android scanner change detection](https://github.com/aosp-mirror/platform_packages_providers_mediaprovider/blob/android-10.0.0_r47/src/com/android/providers/media/scan/ModernMediaScanner.java#L337-L367)
