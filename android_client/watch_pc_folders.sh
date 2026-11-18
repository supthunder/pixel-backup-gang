#!/system/bin/sh
# Watch the configured PC's SMB share names. Run beside mount_pc_folder.sh in
# an unlocked Android 10 owner's global root shell. Ctrl-C ends the session.

die() { echo "PixelBackup: $*" >&2; exit 1; }
[ "$#" -eq 0 ] || die "This watcher takes its PC from the private pixelpc SMB configuration."
[ "$(id -u)" = 0 ] || die "Run from a Magisk root shell."
[ "$(getprop ro.build.version.sdk)" = 29 ] || die "This watcher requires Android 10."
[ "$(getenforce)" = Enforcing ] || die "This watcher requires enforcing SELinux."
init_namespace=$(readlink /proc/1/ns/mnt) || die "Cannot inspect PID 1's mount namespace."
if [ -z "$init_namespace" ] || [ "$(readlink /proc/self/ns/mnt)" != "$init_namespace" ]; then
    die "Enter the global mount namespace with nsenter -t 1 -m first."
fi
directory=$(CDPATH='' cd -P "$(dirname "$0")" && pwd) || die "Cannot locate the mount helper."
helper="$directory/mount_pc_folder.sh"
if [ ! -f "$helper" ] || [ ! -r "$helper" ]; then die "Install mount_pc_folder.sh beside the watcher."; fi
config=${PIXEL_RCLONE_CONFIG:-/data/adb/pixel-backup/rclone.conf}
case "$config" in /*) ;; *) die "PIXEL_RCLONE_CONFIG must be absolute." ;; esac
if [ ! -f "$config" ] || [ -L "$config" ]; then die "A private rclone config file is required."; fi
case "$(stat -c '%u:%a' "$config")" in
    0:400|0:600) ;;
    *) die "Use a root-owned config file with mode 600 or 400." ;;
esac
export PIXEL_RCLONE_CONFIG="$config"
command -v rclone >/dev/null || die "Add the Android-compatible rclone binary to PATH."
if ! rclone listremotes --long --config "$config" --ask-password=false 2>/dev/null |
    LC_ALL=C grep -Eq '^pixelpc:[[:space:]]+smb([[:space:]]|$)'; then
    die "Configure a named SMB remote called pixelpc for the PC and its read-only account."
fi

umask 077
exec 8>>/mnt/.pixel-backup-watcher.lock || exit 1
flock -n 0 <&8 || die "Another PixelBackup watcher is running."
child=
started=
active=
last_status=
stop=0

announce() {
    if [ "$last_status" != "$1" ]; then
        printf 'PixelBackup: %s\n' "$1"
        last_status=$1
    fi
}

list_pc_shares() {
    # FD 3 carries only stdout to the caller. Inspect rclone's stderr in memory
    # so a diagnostic cannot become a share name or end up in a log.
    if diagnosis=$(timeout 12 rclone lsf pixelpc: --dirs-only --dir-slash=false --max-depth 1 \
        --config "$config" --ask-password=false --contimeout 4s --timeout 7s \
        --retries 1 --low-level-retries 1 2>&1 >&3 3>&-); then
        return 0
    fi
    # go-smb2 renders NTSTATUS replies as English MS-ERREF messages. A
    # transport failure or a generic access denial can have other causes.
    case "$diagnosis" in
        *'response error: The attempted logon is invalid.'*|\
        *'response error: The specified account does not exist.'*|\
        *'response error: The referenced account is currently disabled'*|\
        *'response error: The user account has been automatically locked'*|\
        *'response error: The user account has expired.'*|\
        *'response error: The user account password has expired.'*|\
        *'response error: The user password must be changed before logging on'*|\
        *'response error: When trying to update a password,'*'the current password is not correct.'*|\
        *'response error: Indicates a referenced user name and authentication information are valid, but some user account restriction'*|\
        *'response error: The authentication failed because NTLM was blocked.'*) return 2 ;;
    esac
    return 1
}

# Check both the parent and the kernel start time before signalling a numeric
# PID. Only the helper directly started by this watcher belongs to this session.
child_start() {
    IFS= read -r record 2>/dev/null <"/proc/$child/stat" || return 1
    # /proc/PID/stat after the final ')' starts with state, then PPid.
    # shellcheck disable=SC2086
    set -- ${record##*) }
    [ "$2" = "$$" ] && [ "$1" != Z ] && printf '%s\n' "${20}"
}
own_child() {
    [ -n "$started" ] && [ "$(child_start)" = "$started" ]
}
stop_child() {
    [ -n "$child" ] || return 0
    if own_child; then kill -TERM "$child" 2>/dev/null || :; fi
    while own_child; do wait "$child" 2>/dev/null || :; done
    wait "$child" 2>/dev/null || :
    child=
    started=
    active=
}
finish() {
    trap '' HUP INT TERM
    trap - EXIT
    stop_child
    exit "$1"
}
trap 'finish "$?"' EXIT
trap 'stop=1' HUP INT TERM

delay=5
retry_at=0
failed_share=
while [ "$stop" -eq 0 ]; do
    if [ -n "$child" ] && ! own_child; then
        failed_share=$active
        retry_at=$(( $(date +%s) + 30 ))
        stop_child
    fi
    wanted=
    # Listing the root of an SMB remote asks for share names through SMB RPC.
    # No selected directory or media files are traversed during discovery.
    if shares=$(list_pc_shares 3>&1); then
        delay=5
        matches=$(printf '%s\n' "$shares" | LC_ALL=C grep -E '^PixelBackup-[0-9a-f]{32}$')
        case "$matches" in
            '') announce "Waiting for a folder selection on the PC." ;;
            *'
'*) announce "Multiple folder selections are visible. Close the extra picker sessions." ;;
            *) wanted=$matches ;;
        esac
    else
        if [ "$?" -eq 2 ]; then
            die "The PC rejected the SMB login. Check the paired account and credentials, then restart the watcher."
        fi
        announce "Cannot list the PC's shares. Waiting for the configured PC or account."
        delay=$((delay * 2))
        if [ "$delay" -gt 30 ]; then delay=30; fi
    fi
    [ "$stop" -eq 0 ] || break
    if [ -n "$child" ] && [ "$active" != "$wanted" ]; then
        stop_child
        # Re-read the selection. Detaching an open media file can take time.
        continue
    fi
    if [ -n "$wanted" ] && [ -z "$child" ]; then
        if [ "$wanted" != "$failed_share" ] || [ "$(date +%s)" -ge "$retry_at" ]; then
            announce "Opening PC selection $wanted."
            setsid /system/bin/sh "$helper" "pixelpc:$wanted" 8>&- </dev/null &
            child=$!
            started=$(child_start)
            active=$wanted
        else
            announce "The mount stopped. Waiting to retry this selection."
        fi
    fi
    remaining=$delay
    while [ "$stop" -eq 0 ] && [ "$remaining" -gt 0 ]; do
        sleep 1
        remaining=$((remaining - 1))
    done
done
finish 0
