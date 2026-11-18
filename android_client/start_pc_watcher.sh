#!/system/bin/sh
# A Magisk service.d script can call this launcher with no arguments.
# The foreground watcher remains available separately for live diagnostics.

base=/data/adb/pixel-backup
export PATH=/system/bin:/system/xbin
# The provisioned ARM64 tools need Android's libc, libdl and liblog. Prefer
# the stock libraries to the Termux RUNPATH embedded in the package binaries.
unset LD_PRELOAD
export LD_LIBRARY_PATH=/system/lib64:/apex/com.android.runtime/lib64/bionic
export PIXEL_RCLONE_CONFIG="$base/rclone.conf"
umask 077
die() { echo "PixelBackup boot: $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "Root is required."

# The persistent root service executes only its provisioned tools and scripts.
# Check them using system utilities before putting the private bin on PATH.
for path in "$base" "$base/bin" "$base/start_pc_watcher.sh" "$base/watch_pc_folders.sh" \
    "$base/mount_pc_folder.sh" "$base/bin/rclone" "$base/bin/fusermount3"; do
    if [ -L "$path" ] || [ "$(stat -c '%u' "$path" 2>/dev/null)" != 0 ]; then
        die "Expected a root-owned installed path at $path."
    fi
    mode=$(stat -c '%a' "$path") || exit 1
    # Permission digits 2, 3, 6 and 7 include write access.
    case "$mode" in *[2367]?|*[2367]) die "Group or other write access on $path." ;; esac
done
for tool in "$base/bin/rclone" "$base/bin/fusermount3"; do
    if [ ! -f "$tool" ] || [ ! -x "$tool" ]; then die "Install the executable $tool."; fi
done

case "$#:${1-}" in
    0:)
        # Return immediately to Magisk or adb. The worker has its own session
        # and holds no terminal or log pipe open.
        setsid /system/bin/sh "$base/start_pc_watcher.sh" --wait-for-unlock </dev/null >/dev/null 2>&1 &
        exit 0 ;;
    1:--wait-for-unlock) ;;
    *) echo "Usage: start_pc_watcher.sh" >&2; exit 1 ;;
esac

init_namespace=$(readlink /proc/1/ns/mnt) || exit 1
if [ "$(readlink /proc/self/ns/mnt)" != "$init_namespace" ]; then
    exec nsenter -t 1 -m -- /system/bin/sh "$base/start_pc_watcher.sh" --wait-for-unlock
fi

# Keep one waiter across repeated invocations, including the time spent at
# the lock screen. Explicit redirections pass the descriptor through mksh.
exec 7>>/mnt/.pixel-backup-boot.lock || exit 1
flock -n 0 <&7 || exit 0
until [ "$(getprop sys.boot_completed)" = 1 ] &&
    [ "$(am get-started-user-state 0 2>/dev/null)" = RUNNING_UNLOCKED ] &&
    [ -d /mnt/runtime/write/emulated/0 ]; do
    sleep 5
done

export PATH="$base/bin:$PATH"
exec /system/bin/sh "$base/watch_pc_folders.sh" 7>&7
