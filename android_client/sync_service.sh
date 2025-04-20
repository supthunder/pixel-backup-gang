#!/bin/sh -e

################################################################################
# Description: Service to sync files from the backup server and mount them
# Contributors: Your Name
# Usage: ./sync_service.sh <SERVER_URL>
################################################################################

if [ "$#" -ne 1 ]; then
  echo "Usage: $0 <SERVER_URL> (e.g. http://192.168.1.100:8000)" >&2
  exit 1
fi

SERVER_URL=$1
TEMP_DIR="/data/local/tmp/pixel_backup_sync"
LAST_CHECK_FILE="$TEMP_DIR/last_check"
MOUNT_DIR="$TEMP_DIR/mount_point"

# Create necessary directories
mkdir -p "$TEMP_DIR"
mkdir -p "$MOUNT_DIR"
mkdir -p "$MOUNT_DIR/the_binding"

# Initialize last check time if not exists
if [ ! -f "$LAST_CHECK_FILE" ]; then
  echo "0" > "$LAST_CHECK_FILE"
fi

while true; do
  # Get last check timestamp
  LAST_CHECK=$(cat "$LAST_CHECK_FILE")
  
  # Check for new files
  NEW_FILES=$(curl -s "$SERVER_URL/check_new_files/$LAST_CHECK" | jq -r '.new_files[]')
  
  if [ -n "$NEW_FILES" ]; then
    # Download and process each new file
    for FILE in $NEW_FILES; do
      echo "Downloading $FILE..."
      curl -s -o "$MOUNT_DIR/the_binding/$FILE" "$SERVER_URL/download/$FILE"
    done
    
    # Mount the directory if not already mounted
    if ! mount | grep -q "$MOUNT_DIR/the_binding"; then
      # Enter global mount namespace if needed
      if [ "$(readlink /proc/self/ns/mnt)" != "$(readlink /proc/1/ns/mnt)" ]; then
        nsenter -t 1 -m -- /system/bin/sh -c "
          mount -t sdcardfs -o nosuid,nodev,noexec,noatime,gid=9997 \
          $MOUNT_DIR/the_binding /mnt/runtime/write/emulated/0/the_binding
        "
      else
        mount -t sdcardfs -o nosuid,nodev,noexec,noatime,gid=9997 \
        "$MOUNT_DIR/the_binding" "/mnt/runtime/write/emulated/0/the_binding"
      fi
    fi
    
    # Trigger media scanner
    am broadcast \
      -a android.intent.action.MEDIA_SCANNER_SCAN_FILE \
      -d "file:///storage/emulated/0/the_binding/"
  fi
  
  # Update last check time
  date +%s > "$LAST_CHECK_FILE"
  
  # Wait before next check
  sleep 60
done 