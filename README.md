# Pixel Backup Gang

This pilot shares a Windows photo folder with a rooted 2016 Google Pixel or Pixel XL. It keeps the originals on the PC and gives the Pixel a read-only SMB mount at `/storage/emulated/0/PixelBackup`. Android indexes the folder, and Google Photos on the phone can back up its eligible items.

**Tested on an original Pixel running stock Android 10 `QP1A.191005.007.A3`.** The phone discovered the PC's SMB share, mounted it read-only and automatically backed up a PC-generated JPEG and MP4. Google Photos showed **Backed up**, **Original quality**, and zero account storage used for each item. The test carried SMB over a USB debugging tunnel. The normal Windows picker uses the home LAN. [Test details and screenshots](docs/STORAGE_REVIEW.md#on-device-result) · [Google Photos quality policy](https://support.google.com/photos/answer/6220791?co=GENIE.Platform%3DAndroid&hl=en)

## Use the pilot

1. Set up a read-only Windows account and the Android rclone client. Start the paired folder watcher on the unlocked Pixel and leave it running. [Windows and Pixel setup](docs/PC_FOLDER.md)
2. Start the Windows folder picker from an elevated 64-bit Windows PowerShell window at the repository root. Select a folder and leave the status dialog open.

   ```powershell
   .\windows\Select-PixelFolder.ps1 -Reader "$env:COMPUTERNAME\PixelReader"
   ```

3. The phone watcher discovers the selected folder over Wi-Fi, mounts it, and requests a media scan. On first use, enable backup for the device folder in Google Photos. After you verify backup, close the Windows dialog to end the session. The watcher can pick up the next folder without another phone command. [Mount and verify](docs/PC_FOLDER.md#mount-and-verify)

The fork’s older HTTP uploader writes every original to the phone’s internal storage. For the evidence, the latest upstream NFS support, and the docked USB-drive alternative, see the [fork review and storage options](docs/STORAGE_REVIEW.md).
