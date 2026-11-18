# Pixel Backup Gang

This pilot shares a Windows photo folder with a rooted 2016 Google Pixel or Pixel XL. It keeps the originals on the PC and gives the Pixel a read-only SMB mount at `/storage/emulated/0/PixelBackup`. Android indexes the folder, and Google Photos on the phone can back up its eligible items.

**Verified over Wi-Fi on an original Pixel running stock Android 10 `QP1A.191005.007.A3`.** The picker shared a Windows folder and the phone automatically backed up its JPEG and MP4. Windows recorded signed SMB 3.1.1 reads from the Pixel. Google Photos showed **Backed up**, **Original quality**, and zero account storage used for both items, including after the share closed. [Hardware test and screenshots](docs/STORAGE_REVIEW.md#on-device-result) · [Google Photos quality policy](https://support.google.com/photos/answer/6220791?co=GENIE.Platform%3DAndroid&hl=en)

## Use the pilot

1. Pair the Pixel with your Windows PC once over USB. The setup creates a dedicated Windows reader, installs the Android tools, and starts a Magisk service that watches for selections after you unlock the Pixel. [Windows and Pixel setup](docs/PC_FOLDER.md#one-time-windows-and-pixel-setup)
2. Double-click **Select-PixelFolder.cmd** in the `windows` folder, accept the Windows prompt, and select a finished photo folder. Leave the sharing dialog open and keep the PC awake. [Windows folder picker](windows/Select-PixelFolder.cmd)
3. On first use, turn on backup for **PixelBackup** in Google Photos under **Collections → On this device**. The phone reads items over Wi-Fi. When Photos confirms the backup is complete, close the Windows dialog. Select another folder whenever you’re ready. [Verification and daily use](docs/PC_FOLDER.md)

The fork’s older HTTP uploader writes every original to the phone’s internal storage. For the evidence, the latest upstream NFS support, and the docked USB-drive alternative, see the [fork review and storage options](docs/STORAGE_REVIEW.md).
