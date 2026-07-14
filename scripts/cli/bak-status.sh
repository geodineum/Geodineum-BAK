#!/bin/bash
set -euo pipefail

GEODINEUM_ROOT="${GEODINEUM_ROOT:-/opt/geodineum}"

COMMON="${GEODINEUM_ROOT}/Geodineum/lib/common.sh"
[[ -f "$COMMON" ]] && source "$COMMON"

BAK_ROOT="${GEODINEUM_ROOT}/Geodineum-BAK"
BACKUP_SCRIPT="${BAK_ROOT}/scripts/backup-valkey.sh"
BACKUP_DIR="${BAK_ROOT}/backups/valkey"
TIMER="valkey-backup.timer"
SERVICE="valkey-backup.service"

# Scheduling: the installer provisions a systemd timer (02:00 daily,
# 300s jitter) — there is no cron entry to check.
timer_active=$(systemctl is-active "$TIMER" 2>/dev/null || true)
timer_enabled=$(systemctl is-enabled "$TIMER" 2>/dev/null || true)
if [[ "$timer_active" == "active" ]]; then
    echo -e "  ${GREEN:-}●${NC:-} Backup timer: ACTIVE (${timer_enabled})"
else
    echo -e "  ${RED:-}●${NC:-} Backup timer: ${timer_active:-not installed} (${timer_enabled:-—})"
fi

next_run=$(systemctl show "$TIMER" --property=NextElapseUSecRealtime --value 2>/dev/null || true)
if [[ -n "$next_run" && "$next_run" != "n/a" ]]; then
    echo "  Next run: ${next_run}"
fi

# Last run outcome, straight from the oneshot service.
last_result=$(systemctl show "$SERVICE" --property=Result --value 2>/dev/null || true)
last_exit=$(systemctl show "$SERVICE" --property=ExecMainStatus --value 2>/dev/null || true)
last_ts=$(systemctl show "$SERVICE" --property=ExecMainExitTimestamp --value 2>/dev/null || true)
if [[ -n "$last_ts" && "$last_ts" != "n/a" ]]; then
    if [[ "$last_result" == "success" ]]; then
        echo -e "  ${GREEN:-}●${NC:-} Last run: success (${last_ts})"
    else
        echo -e "  ${RED:-}●${NC:-} Last run: ${last_result:-unknown} exit=${last_exit:-?} (${last_ts})"
    fi
fi

# Backup inventory (canonical dir per the systemd unit's --backup-dir).
if [[ -d "$BACKUP_DIR" ]]; then
    file_count=$(find "$BACKUP_DIR" -maxdepth 1 -name 'dump_*.rdb' 2>/dev/null | wc -l)
    total_size=$(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1)
    echo "  Backup dir: ${BACKUP_DIR} (${file_count} backups, ${total_size:-?})"

    newest=$(find "$BACKUP_DIR" -maxdepth 1 -type f -name 'dump_*.rdb' -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)
    if [[ -n "$newest" ]]; then
        age=$(stat -c '%y' "$newest" 2>/dev/null | cut -d. -f1)
        size=$(du -h "$newest" 2>/dev/null | cut -f1)
        echo "  Latest: $(basename "$newest") (${size:-?}, ${age})"
        meta="${newest%.rdb}.meta"
        if [[ -f "$meta" ]]; then
            echo "  Meta:   $(basename "$meta") present"
        fi
    fi
else
    echo -e "  ${RED:-}●${NC:-} Backup dir: not found at ${BACKUP_DIR}"
fi

# Script availability
if [[ -x "$BACKUP_SCRIPT" ]]; then
    echo -e "  ${GREEN:-}●${NC:-} backup-valkey.sh: available"
else
    echo -e "  ${RED:-}●${NC:-} backup-valkey.sh: not found at ${BACKUP_SCRIPT}"
fi
