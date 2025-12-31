#!/bin/bash
# GSD Auto-Deploy - Pulls from main every 10 minutes via cron
# Log: /opt/geodineum/GSD-BAK/deploy.log (capped at 1000 lines)

set -uo pipefail

# Source cargo environment (needed for cron which has minimal PATH)
[ -f "$HOME/.cargo/env" ] && source "$HOME/.cargo/env"

GSD_DIR="/opt/geodineum/GSD"
LOG_FILE="/opt/geodineum/GSD-BAK/deploy.log"
MAX_LOG_ENTRIES=1000
BRANCH="main"
PAT="***REMOVED***"
REMOTE_URL="https://${PAT}@github.com/nierto/GSD.git"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
    # Cap log file
    local lc=$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)
    [ "$lc" -gt "$MAX_LOG_ENTRIES" ] && tail -n "$MAX_LOG_ENTRIES" "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
}

cd "$GSD_DIR" || { log "ERROR dir-not-found"; exit 1; }
git remote set-url origin "$REMOTE_URL" 2>/dev/null || true
git fetch origin "$BRANCH" 2>/dev/null || { log "ERROR fetch-failed"; exit 1; }

LOCAL=$(git rev-parse --short HEAD)
REMOTE=$(git rev-parse --short "origin/$BRANCH")

[ "$LOCAL" = "$REMOTE" ] && exit 0  # No changes, silent exit

CHANGED=$(git diff --name-only HEAD "origin/$BRANCH")
COUNT=$(git rev-list --count HEAD.."origin/$BRANCH")

if git pull origin "$BRANCH" 2>/dev/null; then
    log "PULL $LOCAL→$REMOTE ($COUNT commits)"

    # Auto-reload Lua functions
    if echo "$CHANGED" | grep -q "^daemon/functions/"; then
        if "$GSD_DIR/scripts/load-valkey-functions.sh" >/dev/null 2>&1; then
            log "RELOAD lua-functions"
        else
            log "WARN lua-reload-failed"
        fi
    fi

    # Auto-rebuild daemon when Rust source changes
    if echo "$CHANGED" | grep -q "^daemon/src/\|^daemon/Cargo"; then
        log "BUILD starting release build..."
        cd "$GSD_DIR/daemon"
        if cargo build --release 2>> "$LOG_FILE"; then
            log "BUILD success"
            # Restart service if running
            if systemctl is-active --quiet gsd-daemon; then
                if sudo systemctl restart gsd-daemon 2>> "$LOG_FILE"; then
                    log "RESTART gsd-daemon success"
                else
                    log "WARN restart-failed"
                fi
            fi
        else
            log "ERROR build-failed"
        fi
        cd "$GSD_DIR"
    fi

    # Auto-reinstall service file when it changes
    if echo "$CHANGED" | grep -q "\.service$"; then
        log "SERVICE updating systemd service..."
        if sudo cp "$GSD_DIR/daemon/config/gsd-daemon.service" /etc/systemd/system/ 2>> "$LOG_FILE"; then
            sudo systemctl daemon-reload 2>> "$LOG_FILE"
            log "SERVICE updated and reloaded"
        else
            log "WARN service-update-failed"
        fi
    fi
else
    log "ERROR pull-failed $LOCAL→$REMOTE"
    exit 1
fi
