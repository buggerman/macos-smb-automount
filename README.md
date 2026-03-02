# macOS SMB Auto-Mount

Automatically mount an SMB share when a network target becomes reachable, and unmount when it disconnects. Silent, no popups, no polling.

This works with any network-driven event — a VPN connecting, a specific IP coming online, a host appearing on the local network. I use it with Tailscale to securely access SMB shares on my home server from anywhere.

## How It Works

- A launchd agent runs a bash script that watches for reachability changes using `scutil -W -r`
- `scutil` is kernel-notified on route changes — zero polling, zero network traffic at rest
- When the target becomes reachable, the script mounts the share via Finder (silent, no dialogs)
- When the target disconnects, it unmounts via `diskutil unmount force` (works even when server is unreachable)
- Credentials are pulled from Keychain at runtime — never stored in plain text
- sleepwatcher handles wake-from-sleep by restarting the agent, which re-checks reachability immediately

## Prerequisites

- macOS (tested on Tahoe 26.2)
- Homebrew
- The SMB server's IP or hostname
- SMB credentials (username/password)

## Setup

### 1. Store credentials in Keychain

```bash
security add-internet-password \
  -a "YOUR_SMB_USERNAME" \
  -s "YOUR_SERVER_IP_OR_HOSTNAME" \
  -w "YOUR_PASSWORD" \
  -T "" \
  ~/Library/Keychains/login.keychain-db
```

Replace:
- `YOUR_SMB_USERNAME` — your SMB username
- `YOUR_SERVER_IP_OR_HOSTNAME` — the IP or hostname of your SMB server
- `YOUR_PASSWORD` — your SMB password

### 2. Install sleepwatcher

```bash
brew install sleepwatcher
brew services start sleepwatcher
```

### 3. Create the mount script

Copy `mount.sh` to a permanent location:

```bash
mkdir -p ~/Library/Application\ Support/SMBAutoMount
cp mount.sh ~/Library/Application\ Support/SMBAutoMount/
chmod 700 ~/Library/Application\ Support/SMBAutoMount/mount.sh
```

Edit the script and update the variables at the top:

```bash
TARGET_IP="YOUR_SERVER_IP"      # IP or hostname to watch for reachability
SHARE_NAME="YOUR_SHARE_NAME"              # SMB share name
MOUNT_PATH="/Volumes/YOUR_SHARE_NAME"     # Where it will mount (auto-created by Finder)
SMB_USER="your_username"        # Must match what you used in Keychain
```

### 4. Install the launchd agent

Copy and edit the plist:

```bash
cp com.smb.automount.plist ~/Library/LaunchAgents/
```

Edit `~/Library/LaunchAgents/com.smb.automount.plist` and update the path to your mount.sh if needed.

Load the agent:

```bash
launchctl load ~/Library/LaunchAgents/com.smb.automount.plist
```

### 5. Install the wake script

```bash
cp wakeup ~/.wakeup
chmod 700 ~/.wakeup
```

If you changed the launchd label in the plist, update it in `~/.wakeup` too.

## Files

| File | Description |
|------|-------------|
| `mount.sh` | Main script — watches reachability, mounts/unmounts |
| `com.smb.automount.plist` | launchd agent — runs mount.sh at login, keeps it alive |
| `wakeup` | sleepwatcher script — restarts agent on wake from sleep |

## Logs

The agent logs to `~/Library/Logs/smb-automount.log`. Tail it to watch activity:

```bash
tail -f ~/Library/Logs/smb-automount.log
```

## Uninstall

```bash
launchctl unload ~/Library/LaunchAgents/com.smb.automount.plist
rm ~/Library/LaunchAgents/com.smb.automount.plist
rm -rf ~/Library/Application\ Support/SMBAutoMount
rm ~/.wakeup
brew services stop sleepwatcher
brew uninstall sleepwatcher
security delete-internet-password -a "YOUR_SMB_USERNAME" -s "YOUR_SERVER_IP_OR_HOSTNAME"
```

## Why This Approach?

**Mount via Finder (`osascript`)**: Silent when credentials are in the URL. Creates a Disk Arbitration-managed mount that's user-accessible and appears in Finder.

**Unmount via `diskutil unmount force`**: Works even when the server is unreachable. Raw `umount -f` doesn't work on Finder-managed mounts.

**Watch via `scutil -W -r`**: Kernel-notified on route changes. No polling, no timers, no network traffic. The script runs two watchers in parallel — one on the target IP (catches VPN/tunnel route changes) and one on the default route (catches WiFi/transport changes that the IP watcher can miss when a tunnel route persists without underlying connectivity).

**Wake detection via sleepwatcher**: `scutil` can miss the reachability event on wake from sleep (the event fires while the process is still suspended). sleepwatcher detects wake via IOKit power notifications and restarts the agent, which re-checks state immediately.

## License

MIT
