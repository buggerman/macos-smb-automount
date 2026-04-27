# macOS SMB Auto-Mount

Automatically mount one or more SMB shares when a network target becomes reachable, and unmount them when it disconnects. Silent, no popups, no polling.

This works with any network-driven event — a VPN connecting, a specific IP coming online, a host appearing on the local network. I use it with Tailscale to securely access SMB shares on my home server from anywhere.

## How It Works

- A launchd agent runs a bash script that watches for reachability changes using `scutil -W -r`
- `scutil` is kernel-notified on route changes — zero polling, zero network traffic at rest
- When the target becomes reachable, the script mounts every configured share via Finder (silent, no dialogs)
- When the target disconnects, it unmounts each one via `diskutil unmount force` (works even when server is unreachable)
- Credentials are pulled from Keychain at runtime — never stored in plain text. One Keychain entry covers all shares on the same host
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

Copy `mount.sh` and the example config to a permanent location:

```bash
mkdir -p ~/Library/Application\ Support/SMBAutoMount
cp mount.sh mount.config.example.sh ~/Library/Application\ Support/SMBAutoMount/
cp ~/Library/Application\ Support/SMBAutoMount/mount.config.example.sh \
   ~/Library/Application\ Support/SMBAutoMount/mount.config.sh
chmod 700 ~/Library/Application\ Support/SMBAutoMount/mount.sh
chmod 600 ~/Library/Application\ Support/SMBAutoMount/mount.config.sh
```

Edit `mount.config.sh` and fill in your values:

```bash
TARGET_HOST="YOUR_SERVER_IP_OR_HOSTNAME"  # IP or hostname to watch for reachability
SMB_USER="your_username"                  # Must match what you used in Keychain

SHARES=(
    "share_one"
    "share_two"
    # add more — each mounts at /Volumes/<name>
)
```

`mount.config.sh` is gitignored so your hostnames, usernames, and share names never get committed. `mount.sh` sources it at startup. All shares listed in `SHARES` are mounted on the same `TARGET_HOST` using the same Keychain credential (one entry, indexed by `SMB_USER` + `TARGET_HOST`). To add a share later, append another line to the array in `mount.config.sh` and restart the agent (`launchctl stop com.smb.automount`).

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
| `mount.config.example.sh` | Template config — copy to `mount.config.sh` (gitignored) and fill in |
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
