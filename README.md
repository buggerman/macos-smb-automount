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
- A per-share marker file under `state/` lets the agent distinguish "user manually unmounted this share" from "share has never been mounted" — manual unmounts stick until the host disconnects or the agent restarts (see [Behavior](#day-to-day-behavior))

## Prerequisites

- macOS (tested on Tahoe 26.2)
- Homebrew
- The SMB server's IP or hostname
- SMB credentials (username/password)

## Setup

### 1. Store credentials in Keychain

**Why:** keeps the SMB password out of plaintext. `mount.sh` fetches it at runtime with `security find-internet-password`. One entry covers every share on the same host (entries are keyed on `account` + `server`, not share).

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

**Why:** `scutil` can miss the reachability event on wake from sleep — the kernel fires it while the user agent is still suspended, and the agent never sees it. sleepwatcher uses IOKit power notifications (which always reach user-space on wake) to trigger a forced re-check.

```bash
brew install sleepwatcher
brew services start sleepwatcher
```

### 3. Create the mount script

**Why:** `mount.sh` is the long-running script that does everything. `mount.config.sh` holds your host, username, and share list — it's gitignored so even forks of this repo never leak personal values.

Copy `mount.sh` to a permanent location and create your local config from the example:

```bash
mkdir -p ~/Library/Application\ Support/SMBAutoMount
cp mount.sh ~/Library/Application\ Support/SMBAutoMount/
cp mount.config.example.sh ~/Library/Application\ Support/SMBAutoMount/mount.config.sh
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

`mount.config.sh` is gitignored so your hostnames, usernames, and share names never get committed. `mount.sh` sources it at startup. All shares listed in `SHARES` are mounted on the same `TARGET_HOST` using the same Keychain credential. To add a share later, append another line to the array in `mount.config.sh` and bounce the agent — `launchctl stop com.smb.automount` (KeepAlive in the plist relaunches it within a second).

### 4. Install the launchd agent

**Why:** `mount.sh` needs to be running continuously to watch reachability. launchd starts it at login (`RunAtLoad=true`), respawns it if it crashes (`KeepAlive=true`), and tears it down at logout — all without you having to remember to start anything.

```bash
cp com.smb.automount.plist ~/Library/LaunchAgents/
```

Edit `~/Library/LaunchAgents/com.smb.automount.plist` and replace the two `YOUR_USERNAME` placeholders with your macOS short username (or update the paths if you put the script somewhere else).

Load the agent:

```bash
launchctl load ~/Library/LaunchAgents/com.smb.automount.plist
```

### 5. Install the wake script

**Why:** sleepwatcher invokes `~/.wakeup` on wake from sleep. The script does `launchctl stop com.smb.automount` — combined with KeepAlive, that effectively restarts the agent, forcing it to re-evaluate reachability immediately rather than waiting for the next scutil event (which it might not see).

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

At runtime the agent also creates `~/Library/Application Support/SMBAutoMount/state/`, where it drops one empty marker file per mounted share (`mounted-<share>`). These are wiped on every agent start, so they never persist across reboots.

## Day-to-day Behavior

Once installed, the agent runs invisibly. The table below covers everything it does in response to your actions:

| What happens | What the agent does |
|---|---|
| Host becomes reachable (boot, login, VPN connect, Tailscale up) | Mounts every share in `SHARES` that isn't already mounted and has no marker. Drops a marker for each. |
| Host becomes unreachable (sleep, VPN disconnect, network drop) | Unmounts every currently-mounted share with `diskutil unmount force`. Removes its marker. |
| You manually unmount a share via Finder | Marker stays. On the next reachability event, the agent sees the marker and **leaves the share alone** for the rest of this session. |
| You manually mount a share via Finder while the agent is running | Agent observes it's already mounted and does nothing. On the next host disconnect/reconnect cycle, it goes back into auto-management. |
| Reboot or wake from sleep | Agent restarts (via launchd or sleepwatcher), wipes all markers, mounts everything reachable. |

To force-re-engage automount for a manually-unmounted share without waiting for a disconnect, pick one:
- Manually mount it (next disconnect/reconnect adopts it back into auto-management)
- Delete its marker file: `rm ~/Library/Application\ Support/SMBAutoMount/state/mounted-<share>`
- Bounce the whole agent: `launchctl kickstart -k gui/$(id -u)/com.smb.automount`

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

**Marker files for manual-unmount-sticks**: A scutil event fires several times per network change, and the agent loops through every share on each event. Without state, it would re-mount anything you'd intentionally ejected. The marker files (`state/mounted-<share>`) record "the agent owns this share" — if a share is unmounted but its marker is still present, the user did it, and the agent backs off. Markers are wiped on every agent start so a reboot or wake can never lock you out of your shares.

## License

MIT
