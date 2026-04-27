#!/bin/bash
# SMB Auto-Mount Script
#
# Watches reachability of a target host via scutil -W -r.
# scutil is kernel-notified on route changes — no polling, no network traffic at rest.
# On each reachability event: settles, re-checks, then mounts or unmounts each share as needed.
# Mount is via osascript/Finder (silent, DA-managed); password from Keychain.

# ==============================================================================
# CONFIGURATION — sourced from mount.config.sh (gitignored, lives next to this script)
# Copy mount.config.example.sh to mount.config.sh and fill in your values.
# ==============================================================================

LOG_FILE="$HOME/Library/Logs/smb-automount.log"

CONFIG_FILE="$(dirname "$0")/mount.config.sh"
if [ ! -f "$CONFIG_FILE" ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] FATAL: $CONFIG_FILE not found" >> "$LOG_FILE"
    exit 1
fi
# shellcheck disable=SC1090
source "$CONFIG_FILE"

if [ -z "${TARGET_HOST:-}" ] || [ -z "${SMB_USER:-}" ] || [ ${#SHARES[@]} -eq 0 ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] FATAL: TARGET_HOST, SMB_USER, or SHARES not set in $CONFIG_FILE" >> "$LOG_FILE"
    exit 1
fi

# ==============================================================================
# TUNING — Adjust if needed
# ==============================================================================

SETTLE_DELAY=3        # Seconds to wait after an event before acting (avoids flapping)
MOUNT_COOLDOWN=10     # Minimum seconds between mount attempts (per share)
declare -A LAST_MOUNT_TIME   # share -> epoch of last successful mount

# ==============================================================================
# FUNCTIONS
# ==============================================================================

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}

mount_path_for() {
    echo "/Volumes/$1"
}

is_mounted() {
    local path
    path=$(mount_path_for "$1")
    mount 2>/dev/null | grep -q " on ${path} "
}

# Ping with a 2-second timeout
is_reachable() {
    ping -c 1 "$TARGET_HOST" >/dev/null 2>&1 &
    local pid=$!
    local i=0
    while [ $i -lt 20 ]; do
        sleep 0.1
        if ! kill -0 $pid 2>/dev/null; then
            wait $pid
            return $?
        fi
        i=$((i + 1))
    done
    kill $pid 2>/dev/null
    wait $pid 2>/dev/null
    return 1
}

do_mount() {
    local share="$1"
    local path
    path=$(mount_path_for "$share")

    local pass
    pass=$(security find-internet-password -a "${SMB_USER}" -s "${TARGET_HOST}" -w 2>/dev/null)
    if [ -z "$pass" ]; then
        log "ERROR: No Keychain credential found for ${SMB_USER}@${TARGET_HOST}"
        return 1
    fi

    log "Mounting smb://${TARGET_HOST}/${share} via Finder..."
    osascript -e "tell application \"Finder\" to mount volume \"smb://${SMB_USER}:${pass}@${TARGET_HOST}/${share}\"" >/dev/null 2>&1

    # osascript mount is async — poll until it appears (up to 5s)
    local i=0
    while [ $i -lt 10 ]; do
        sleep 0.5
        if is_mounted "$share"; then
            log "Mount complete: ${path}"
            LAST_MOUNT_TIME[$share]=$(date +%s)
            return 0
        fi
        i=$((i + 1))
    done
    log "ERROR: Mount of ${share} did not appear within 5s"
    return 1
}

do_unmount() {
    local share="$1"
    local path
    path=$(mount_path_for "$share")
    log "Unmounting ${path}..."
    diskutil unmount force "${path}" >/dev/null 2>&1
    log "Unmount complete: ${path} (exit: $?)"
}

handle_event() {
    local event_line="$1"
    log "Event: ${event_line} — settling ${SETTLE_DELAY}s..."
    sleep "$SETTLE_DELAY"

    local reachable current
    current=$(scutil -r "$TARGET_HOST" 2>&1)
    if echo "$current" | grep -q "^Reachable"; then
        is_reachable && reachable=true || reachable=false
    else
        reachable=false
    fi

    log "Host ${TARGET_HOST} reachable=${reachable}"

    local share now last
    for share in "${SHARES[@]}"; do
        local mounted
        is_mounted "$share" && mounted=true || mounted=false
        log "  ${share}: mounted=${mounted}"

        if [ "$reachable" = true ] && [ "$mounted" = false ]; then
            now=$(date +%s)
            last=${LAST_MOUNT_TIME[$share]:-0}
            if [ $((now - last)) -lt $MOUNT_COOLDOWN ]; then
                log "  ${share}: mount cooldown active, skipping"
            else
                do_mount "$share"
            fi
        elif [ "$reachable" = false ] && [ "$mounted" = true ]; then
            do_unmount "$share"
        fi
    done
}

# ==============================================================================
# MAIN
# ==============================================================================

log "=== SMB Auto-Mount Agent started (PID $$) — host=${TARGET_HOST} shares=${SHARES[*]} ==="

while true; do
    # Watch both the target host and the default route (0.0.0.0).
    # The host watcher catches VPN/tunnel route changes (e.g. Tailscale toggled on/off).
    # The default route watcher catches transport changes (e.g. WiFi on/off) that the
    # host watcher can miss when the tunnel route persists without underlying connectivity.
    while IFS= read -r line; do
        case "$line" in
            Reachable*|"Not Reachable"*)
                handle_event "$line"
                ;;
        esac
    done < <(
        scutil -W -r "$TARGET_HOST" &
        scutil -W -r 0.0.0.0 &
        wait
    )

    # scutil watchers exited unexpectedly — restart after a delay
    log "scutil watchers exited unexpectedly, restarting in 5s..."
    sleep 5
done
