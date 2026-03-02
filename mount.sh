#!/bin/bash
# SMB Auto-Mount Script
#
# Watches reachability of a target IP via scutil -W -r.
# scutil is kernel-notified on route changes — no polling, no network traffic at rest.
# On each reachability event: settles, re-checks, then mounts or unmounts as needed.
# Mount is via osascript/Finder (silent, DA-managed); password from Keychain.

# ==============================================================================
# CONFIGURATION — Edit these for your setup
# ==============================================================================

TARGET_IP="YOUR_SERVER_IP"            # IP or hostname to watch for reachability
SHARE_NAME="YOUR_SHARE_NAME"                    # SMB share name on the server
MOUNT_PATH="/Volumes/YOUR_SHARE_NAME"           # Where it will mount (Finder creates this)
SMB_USER="your_username"              # SMB username (must match Keychain entry)
LOG_FILE="$HOME/Library/Logs/smb-automount.log"

# ==============================================================================
# TUNING — Adjust if needed
# ==============================================================================

SETTLE_DELAY=3        # Seconds to wait after an event before acting (avoids flapping)
MOUNT_COOLDOWN=10     # Minimum seconds between mount attempts
LAST_MOUNT_TIME=0

# ==============================================================================
# FUNCTIONS
# ==============================================================================

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}

is_mounted() {
    mount 2>/dev/null | grep -q " on ${MOUNT_PATH} "
}

# Ping with a 2-second timeout
is_reachable() {
    ping -c 1 "$TARGET_IP" >/dev/null 2>&1 &
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
    local pass
    pass=$(security find-internet-password -a "${SMB_USER}" -s "${TARGET_IP}" -w 2>/dev/null)
    if [ -z "$pass" ]; then
        log "ERROR: No Keychain credential found for ${SMB_USER}@${TARGET_IP}"
        return 1
    fi

    log "Mounting smb://${TARGET_IP}/${SHARE_NAME} via Finder..."
    osascript -e "tell application \"Finder\" to mount volume \"smb://${SMB_USER}:${pass}@${TARGET_IP}/${SHARE_NAME}\"" >/dev/null 2>&1

    # osascript mount is async — poll until it appears (up to 5s)
    local i=0
    while [ $i -lt 10 ]; do
        sleep 0.5
        if is_mounted; then
            log "Mount complete"
            LAST_MOUNT_TIME=$(date +%s)
            return 0
        fi
        i=$((i + 1))
    done
    log "ERROR: Mount did not appear within 5s"
    return 1
}

do_unmount() {
    log "Unmounting ${MOUNT_PATH}..."
    diskutil unmount force "${MOUNT_PATH}" >/dev/null 2>&1
    log "Unmount complete (exit: $?)"
}

handle_event() {
    local event_line="$1"
    log "Event: ${event_line} — settling ${SETTLE_DELAY}s..."
    sleep "$SETTLE_DELAY"

    local mounted reachable current

    is_mounted && mounted=true || mounted=false

    # Re-check reachability after settle (instant route check first)
    current=$(scutil -r "$TARGET_IP" 2>&1)
    if echo "$current" | grep -q "^Reachable"; then
        # Route exists — verify host actually responds before mounting
        is_reachable && reachable=true || reachable=false
    else
        reachable=false
    fi

    log "State: reachable=${reachable} mounted=${mounted}"

    if [ "$reachable" = true ] && [ "$mounted" = false ]; then
        local now=$(date +%s)
        if [ $((now - LAST_MOUNT_TIME)) -lt $MOUNT_COOLDOWN ]; then
            log "Mount cooldown active, skipping"
        else
            do_mount
        fi
    elif [ "$reachable" = false ] && [ "$mounted" = true ]; then
        do_unmount
    else
        log "No action needed"
    fi
}

# ==============================================================================
# MAIN
# ==============================================================================

log "=== SMB Auto-Mount Agent started (PID $$) ==="

while true; do
    # Watch both the target IP and the default route (0.0.0.0).
    # The IP watcher catches VPN/tunnel route changes (e.g. Tailscale toggled on/off).
    # The default route watcher catches transport changes (e.g. WiFi on/off) that the
    # IP watcher can miss when the tunnel route persists without underlying connectivity.
    while IFS= read -r line; do
        case "$line" in
            Reachable*|"Not Reachable"*)
                handle_event "$line"
                ;;
        esac
    done < <(
        scutil -W -r "$TARGET_IP" &
        scutil -W -r 0.0.0.0 &
        wait
    )

    # scutil watchers exited unexpectedly — restart after a delay
    log "scutil watchers exited unexpectedly, restarting in 5s..."
    sleep 5
done
