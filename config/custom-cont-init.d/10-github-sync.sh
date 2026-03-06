#!/usr/bin/with-contenv bash
# linuxserver custom init — GitHub sync (flat into /config/projects)
# Runs every container start; cron job persists between restarts via /config

echo "=== Setting up GitHub sync service ==="

apt-get update -qq && apt-get install -y --no-install-recommends cron jq git

mkdir -p /config/.local/bin

cat > /config/.local/bin/gh_sync.sh << 'SYNC'
#!/bin/bash
set -euo pipefail

GH_USER="nuniesmith"
TARGET_DIR="/config/projects"
LOG_TAG="[gh_sync]"

echo "$LOG_TAG === GitHub Sync Started at $(date) ==="

mkdir -p "$TARGET_DIR"
cd "$TARGET_DIR"

# Fetch repo list — bail out entirely if the API call fails or returns nothing
# to prevent the cleanup loop from deleting all local repos on a network blip
REPO_DATA=$(curl -fsSL "https://api.github.com/users/$GH_USER/repos?per_page=100" \
    | jq -r '.[] | "\(.name)|\(.clone_url)"') || {
    echo "$LOG_TAG ERROR: GitHub API call failed. Skipping sync to protect local repos."
    exit 1
}

if [ -z "$REPO_DATA" ]; then
    echo "$LOG_TAG WARNING: GitHub API returned no repos. Skipping sync to protect local repos."
    exit 0
fi

ACTIVE_REPOS=$(echo "$REPO_DATA" | cut -d'|' -f1)

# Remove repos that no longer exist on GitHub
# Guard: only runs when ACTIVE_REPOS is non-empty (checked above)
for local_dir in */; do
    [ -d "$local_dir" ] || continue
    dir_name="${local_dir%/}"
    if ! echo "$ACTIVE_REPOS" | grep -qx "$dir_name"; then
        echo "$LOG_TAG Removing deleted repo: $dir_name"
        rm -rf "$dir_name"
    fi
done

# Clone new repos, pull existing ones
while IFS='|' read -r REPO_NAME REPO_URL; do
    [ -z "$REPO_NAME" ] && continue
    if [ -d "$REPO_NAME" ]; then
        echo "$LOG_TAG Pulling:  $REPO_NAME"
        git -C "$REPO_NAME" fetch --prune origin
        git -C "$REPO_NAME" merge --ff-only FETCH_HEAD 2>/dev/null \
            || echo "$LOG_TAG   (skipped merge — local changes present in $REPO_NAME)"
    else
        echo "$LOG_TAG Cloning:  $REPO_NAME"
        git clone "$REPO_URL"
    fi
done <<< "$REPO_DATA"

echo "$LOG_TAG === GitHub Sync Finished at $(date) ==="
SYNC

chmod +x /config/.local/bin/gh_sync.sh

# Install hourly cron job (recreated on every container start)
echo "0 * * * * root /config/.local/bin/gh_sync.sh >> /config/gh_sync.log 2>&1" \
    > /etc/cron.d/github-sync
chmod 0644 /etc/cron.d/github-sync

service cron restart 2>/dev/null || /usr/sbin/cron

# Run once immediately on first start so repos are available right away
echo "=== Running initial sync ==="
/config/.local/bin/gh_sync.sh >> /config/gh_sync.log 2>&1 &

echo "=== GitHub sync service is live ==="
echo "    Repos:      /config/projects  (→ ./projects on host)"
echo "    Logs:       /config/gh_sync.log"
echo "    Schedule:   every hour"
