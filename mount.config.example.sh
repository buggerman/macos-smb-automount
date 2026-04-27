# Local config for mount.sh — copy to mount.config.sh and fill in.
# mount.config.sh is gitignored; never commit your real values.

TARGET_HOST="YOUR_SERVER_IP_OR_HOSTNAME"   # IP or hostname to watch for reachability
SMB_USER="your_username"                   # SMB username (must match Keychain entry)

# Each name mounts at /Volumes/<name>. Add or remove freely.
# All shares use the same TARGET_HOST + SMB_USER (one Keychain entry covers all).
SHARES=(
    "share_one"
    "share_two"
)
