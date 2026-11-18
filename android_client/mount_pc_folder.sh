#!/system/bin/sh
# Run as root in PID 1's mount namespace on an unlocked Android 10 owner profile.
# Usage: mount_pc_folder.sh [configured-remote:path]
# Stop with Ctrl-C. Close apps using the folder if ordinary unmount reports busy.

die() { echo "PixelBackup: $*" >&2; exit 1; }

[ "$#" -le 1 ] || die "Expected at most one named rclone remote and path."
remote=${1-pixelpc:PixelBackup}
case "$remote" in
    *:*) name=${remote%%:*} ;;
    *) die "Use a named remote such as pixelpc:PixelBackup." ;;
esac
case "$name" in
    ''|-*|*[!A-Za-z0-9_.-]*) die "Use a remote name from the private config." ;;
esac
config=${PIXEL_RCLONE_CONFIG:-/data/adb/pixel-backup/rclone.conf}
case "$config" in /*) ;; *) die "PIXEL_RCLONE_CONFIG must be absolute." ;; esac

[ "$(id -u)" = 0 ] || die "Run from a Magisk root shell."
[ "$(getprop ro.build.version.sdk)" = 29 ] || die "This pilot requires Android 10."
[ "$(getenforce)" = Enforcing ] || die "This pilot requires enforcing SELinux."
init_namespace=$(readlink /proc/1/ns/mnt) || die "Cannot inspect PID 1's mount namespace."
if [ -z "$init_namespace" ] || [ "$(readlink /proc/self/ns/mnt)" != "$init_namespace" ]; then
    die "Enter the global mount namespace with nsenter -t 1 -m first."
fi
if [ "$(am get-current-user)" != 0 ] || [ "$(am get-started-user-state 0)" != RUNNING_UNLOCKED ]; then
    die "Unlock Android's owner profile before mounting."
fi
[ -c /dev/fuse ] || die "The FUSE device is unavailable."
if [ ! -f "$config" ] || [ -L "$config" ]; then die "A private rclone config file is required."; fi
case "$(stat -c '%u:%a' "$config")" in
    0:400|0:600) ;;
    *) die "Use a root-owned config file with mode 600 or 400." ;;
esac
command -v rclone >/dev/null || die "Add the Android-compatible rclone binary to PATH."
command -v fusermount3 >/dev/null || die "Add fusermount3 to PATH for the Android rclone build."

umask 077
# /mnt is root-controlled tmpfs. The kernel releases the lock when this shell exits.
exec 9>>/mnt/.pixel-backup-folder.lock || exit 1
# mksh marks extra shell descriptors close-on-exec. Pass the same open file
# description to flock on stdin; this shell keeps the lock through descriptor 9.
flock -n 0 <&9 || die "Another PixelBackup mount is running."

public=/storage/emulated/0/PixelBackup
default=/mnt/runtime/default/emulated/0/PixelBackup
read_view=/mnt/runtime/read/emulated/0/PixelBackup
write_view=/mnt/runtime/write/emulated/0/PixelBackup
views="$default $read_view $write_view"
if [ -d /mnt/runtime/full/emulated/0 ]; then views="$views /mnt/runtime/full/emulated/0/PixelBackup"; fi
views="$views $public"
IFS= read -r uuid </proc/sys/kernel/random/uuid || die "Cannot identify this mount."
tag="pixelbackup-$uuid"

# An exact mountinfo match avoids mistaking an empty directory for a mount.
# A stacked mount is ambiguous. Leave it for the operator to resolve.
mount_state() {
    state=absent
    while read -r _id _parent _device _root target opts rest; do
        [ "$target" = "$1" ] || continue
        case " $rest " in
            *" - fuse.rclone $tag "*|*" - fuse $tag "*)
                case ",$opts," in *,ro,*) current=owned ;; *) current=owned_rw ;; esac ;;
            *) current=foreign ;;
        esac
        case "$state:$current" in
            absent:*) state=$current ;;
            foreign:foreign) ;;
            *) state=stacked ;;
        esac
    done </proc/self/mountinfo
    echo "$state"
}

identity() { stat -L -c '%d:%i' "$1"; }

check_empty() {
    [ "$(mount_state "$1")" = absent ] || die "A mount already occupies $1."
    [ ! -L "$1" ] || die "Symlink at $1."
    if [ -e "$1" ]; then
        [ "$(find "$1" -maxdepth 0 -type d -empty -print)" = "$1" ] ||
            die "Expected an empty, readable directory at $1."
    fi
}

for path in $views; do
    [ -d "${path%/*}" ] || die "Android storage view ${path%/*} is unavailable."
    check_empty "$path"
done

anchor=$(mktemp -d /mnt/pixel-backup.XXXXXX) || die "Could not create a private mount point."
child=
created_id=
stop=0

detach() {
    case "$(mount_state "$1")" in
        owned|owned_rw) umount "$1" 2>/dev/null ;;
        stacked) return 1 ;;
        *) return 0 ;;
    esac
}

cleanup() {
    result=$1
    trap '' HUP INT TERM
    trap - EXIT
    warned=0
    while :; do
        busy=0
        for path in $views; do detach "$path" || busy=1; done
        if [ "$busy" -eq 0 ] && [ "$(mount_state "$anchor")" != foreign ] && detach "$anchor"; then break; fi
        if [ "$warned" -eq 0 ]; then
            echo "PixelBackup: close apps using the folder or clear an overlapping mount; waiting to detach." >&2
            warned=1
        fi
        sleep 2
    done
    if [ -n "$child" ]; then
        kill -TERM "$child" 2>/dev/null || :
        wait "$child" 2>/dev/null || :
    fi
    rmdir "$anchor" || result=1
    if [ -n "$created_id" ] && [ "$(identity "$write_view" 2>/dev/null)" = "$created_id" ]; then
        rmdir "$write_view" || result=1
    fi
    exit "$result"
}
trap 'cleanup "$?"' EXIT
trap 'stop=1' HUP INT TERM

if [ ! -d "$write_view" ]; then
    mkdir "$write_view" || die "Cannot create the empty PixelBackup folder."
    created_id=$(identity "$write_view") || die "Cannot identify the new folder."
fi
for path in $views; do [ -d "$path" ] || die "Folder missing from $path."; done

# Own the child for the lifetime of this invocation. Isolate it from terminal
# signals so open app handles can drain before we shut down the FUSE server.
setsid rclone mount "$remote" "$anchor" --config "$config" --devname "$tag" \
    --allow-other --read-only --vfs-cache-mode off --dir-cache-time 15s \
    --umask 022 --dir-perms 0555 --file-perms 0444 \
    --daemon=false --ask-password=false --log-level ERROR 9>&- </dev/null &
child=$!
# Defer an early signal only until both the directory and child are tracked.
# After this point a signal can clean up safely even between the scan and wait.
trap 'exit 0' HUP INT TERM
[ "$stop" -eq 0 ] || exit 0
elapsed=0
while [ "$(mount_state "$anchor")" != owned ]; do
    if ! kill -0 "$child" 2>/dev/null; then
        wait "$child" 2>/dev/null
        child=
        die "rclone exited before the read-only mount was ready."
    fi
    [ "$elapsed" -lt 40 ] || die "Timed out waiting for rclone's read-only FUSE mount."
    sleep 1
    elapsed=$((elapsed + 1))
done
mounted_id=$(identity "$anchor") || die "Cannot read the FUSE root."

for path in $views; do
    # Stock Android may already have propagated the bind to this view.
    if [ "$(identity "$path")" != "$mounted_id" ]; then
        check_empty "$path"
        mount -o bind "$anchor" "$path" || die "Could not bind $path."
    fi
    [ "$(identity "$path")" = "$mounted_id" ] || die "The FUSE root is hidden at $path."
    case "$(mount_state "$path")" in
        owned|absent) ;; # An alias through an already-bound parent may have no exact entry.
        *) die "Conflicting or writable mount at $path." ;;
    esac
done
timeout 45 ls -A "$public" >/dev/null || die "Cannot list the share through $public."
am broadcast --user 0 -a android.intent.action.MEDIA_SCANNER_SCAN_FILE \
    -d file:///storage/emulated/0/PixelBackup/ >/dev/null ||
    echo "PixelBackup: Android rejected the media scan request." >&2
echo "PixelBackup mounted read-only at $public. Press Ctrl-C to detach."
wait "$child"
result=$?
child=
cleanup "$result"
