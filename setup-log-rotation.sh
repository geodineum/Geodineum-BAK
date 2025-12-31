#!/usr/bin/env bash
# ==============================================================================
# GSD Log Rotation Setup
# ==============================================================================
# Installs logrotate configs for gCore and WordPress logs.
# Optionally backs up and truncates large logs.
#
# Usage: sudo ./setup-log-rotation.sh [OPTIONS]
#
# Options:
#   --truncate        Truncate logs exceeding threshold
#   --no-backup       Skip backup before truncation
#   --force           Don't prompt for confirmation
#   --help            Show this help
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config/gsd-bak.yaml"
LOGROTATE_DIR="$SCRIPT_DIR/config/logrotate"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_debug() { [[ "${DEBUG:-}" == "true" ]] && echo -e "${BLUE}[DEBUG]${NC} $*" || true; }

# ------------------------------------------------------------------------------
# Load Configuration
# ------------------------------------------------------------------------------
# Simple YAML parser using grep/sed (no external deps)
yaml_get() {
    local key="$1"
    local default="${2:-}"
    local value
    if [[ -f "$CONFIG_FILE" ]]; then
        # Handle nested keys like "log_truncation.threshold_bytes"
        value=$(grep -E "^\s*${key##*.}:" "$CONFIG_FILE" 2>/dev/null | head -1 | sed 's/.*:\s*//' | tr -d '"' || echo "")
    fi
    echo "${value:-$default}"
}

# Load config values with defaults
LOG_ARCHIVE_DIR=$(yaml_get "log_archive_dir" "$SCRIPT_DIR/logs")
TRUNCATE_THRESHOLD=$(yaml_get "threshold_bytes" "10485760")
WP_TRUNCATE_THRESHOLD=$(yaml_get "truncate_threshold_bytes" "5242880")
BACKUP_BEFORE_TRUNCATE=$(yaml_get "backup_before_truncate" "true")
ARCHIVE_RETENTION_DAYS=$(yaml_get "archive_retention_days" "30")

# ------------------------------------------------------------------------------
# Parse Arguments
# ------------------------------------------------------------------------------
TRUNCATE=false
NO_BACKUP=false
FORCE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --truncate)
            TRUNCATE=true
            shift
            ;;
        --no-backup)
            NO_BACKUP=true
            shift
            ;;
        --force)
            FORCE=true
            shift
            ;;
        --help|-h)
            echo "Usage: sudo $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --truncate        Truncate logs exceeding threshold"
            echo "  --no-backup       Skip backup before truncation"
            echo "  --force           Don't prompt for confirmation"
            echo "  --help            Show this help"
            echo ""
            echo "Config: $CONFIG_FILE"
            echo "Thresholds: gCore=$(numfmt --to=iec $TRUNCATE_THRESHOLD), WP=$(numfmt --to=iec $WP_TRUNCATE_THRESHOLD)"
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

# ------------------------------------------------------------------------------
# Root Check
# ------------------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    log_error "This script must be run as root (use sudo)"
    exit 1
fi

# ------------------------------------------------------------------------------
# Ensure directories exist
# ------------------------------------------------------------------------------
mkdir -p "$LOG_ARCHIVE_DIR"
log_debug "Log archive directory: $LOG_ARCHIVE_DIR"

# ------------------------------------------------------------------------------
# Install Logrotate Configs
# ------------------------------------------------------------------------------
log_info "Installing logrotate configurations..."

if [[ -f "$LOGROTATE_DIR/gcore" ]]; then
    cp "$LOGROTATE_DIR/gcore" /etc/logrotate.d/gcore
    chmod 644 /etc/logrotate.d/gcore
    log_info "Installed /etc/logrotate.d/gcore"
else
    log_error "Config not found: $LOGROTATE_DIR/gcore"
    exit 1
fi

if [[ -f "$LOGROTATE_DIR/gcore-wp" ]]; then
    cp "$LOGROTATE_DIR/gcore-wp" /etc/logrotate.d/gcore-wp
    chmod 644 /etc/logrotate.d/gcore-wp
    log_info "Installed /etc/logrotate.d/gcore-wp"
else
    log_error "Config not found: $LOGROTATE_DIR/gcore-wp"
    exit 1
fi

# ------------------------------------------------------------------------------
# Validate Configs
# ------------------------------------------------------------------------------
log_info "Validating logrotate configurations..."
if logrotate --debug /etc/logrotate.d/gcore 2>&1 | grep -q "error:"; then
    log_error "gcore config validation failed"
    exit 1
fi
log_info "gcore config: OK"

if logrotate --debug /etc/logrotate.d/gcore-wp 2>&1 | grep -q "error:"; then
    log_error "gcore-wp config validation failed"
    exit 1
fi
log_info "gcore-wp config: OK"

# ------------------------------------------------------------------------------
# Backup and Truncate Functions
# ------------------------------------------------------------------------------
backup_log() {
    local log_file="$1"
    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    local basename
    basename=$(basename "$log_file")
    local archive_file="$LOG_ARCHIVE_DIR/${basename%.log}_${timestamp}.log.gz"

    if gzip -c "$log_file" > "$archive_file"; then
        log_info "Backed up: $basename -> $(basename "$archive_file")"
        return 0
    else
        log_warn "Backup failed for $basename"
        return 1
    fi
}

truncate_log() {
    local log_file="$1"
    local owner="${2:-www-data}"
    local group="${3:-www-data}"

    > "$log_file"
    chown "$owner:$group" "$log_file"
    log_info "Truncated: $(basename "$log_file")"
}

cleanup_old_archives() {
    if [[ "$ARCHIVE_RETENTION_DAYS" -gt 0 ]]; then
        local deleted
        deleted=$(find "$LOG_ARCHIVE_DIR" -name "*.log.gz" -mtime +"$ARCHIVE_RETENTION_DAYS" -delete -print 2>/dev/null | wc -l)
        if [[ "$deleted" -gt 0 ]]; then
            log_info "Cleaned up $deleted old archive(s) (>${ARCHIVE_RETENTION_DAYS} days)"
        fi
    fi
}

# ------------------------------------------------------------------------------
# Truncate Large Logs (with backup)
# ------------------------------------------------------------------------------
if [[ "$TRUNCATE" == "true" ]]; then
    log_warn "Processing large log files..."

    DO_BACKUP=true
    if [[ "$NO_BACKUP" == "true" ]]; then
        DO_BACKUP=false
    elif [[ "$BACKUP_BEFORE_TRUNCATE" != "true" ]]; then
        DO_BACKUP=false
    fi

    # gCore bootstrap.log
    if [[ -f /var/log/gcore/bootstrap.log ]]; then
        SIZE=$(stat -c%s /var/log/gcore/bootstrap.log 2>/dev/null || echo 0)
        if [[ $SIZE -gt $TRUNCATE_THRESHOLD ]]; then
            log_info "bootstrap.log: $(numfmt --to=iec $SIZE) (threshold: $(numfmt --to=iec $TRUNCATE_THRESHOLD))"

            if [[ "$DO_BACKUP" == "true" ]]; then
                backup_log /var/log/gcore/bootstrap.log
            fi
            truncate_log /var/log/gcore/bootstrap.log www-data www-data
        fi
    fi

    # WordPress info logs
    for log_dir in /var/www/*/wp-content/logs; do
        if [[ -d "$log_dir" ]]; then
            site=$(echo "$log_dir" | sed 's|/var/www/\([^/]*\)/.*|\1|')
            log_debug "Checking $site logs..."

            find "$log_dir" -name '*-info.log' -type f 2>/dev/null | while read -r log_file; do
                SIZE=$(stat -c%s "$log_file" 2>/dev/null || echo 0)
                if [[ $SIZE -gt $WP_TRUNCATE_THRESHOLD ]]; then
                    log_info "$(basename "$log_file"): $(numfmt --to=iec $SIZE)"

                    if [[ "$DO_BACKUP" == "true" ]]; then
                        backup_log "$log_file"
                    fi
                    truncate_log "$log_file" www-data www-data
                fi
            done
        fi
    done

    # Cleanup old archives
    cleanup_old_archives

    log_info "Log processing complete"
fi

# ------------------------------------------------------------------------------
# Show Current Sizes
# ------------------------------------------------------------------------------
echo ""
log_info "Current log sizes:"
echo "  gCore:"
du -sh /var/log/gcore/* 2>/dev/null | sed 's/^/    /' || echo "    (no logs found)"
echo ""
echo "  WordPress:"
for log_dir in /var/www/*/wp-content/logs; do
    if [[ -d "$log_dir" ]]; then
        site=$(echo "$log_dir" | sed 's|/var/www/\([^/]*\)/.*|\1|')
        echo "    $site: $(du -sh "$log_dir" 2>/dev/null | cut -f1)"
    fi
done

if [[ -d "$LOG_ARCHIVE_DIR" ]] && [[ -n "$(ls -A "$LOG_ARCHIVE_DIR" 2>/dev/null)" ]]; then
    echo ""
    echo "  Archives:"
    du -sh "$LOG_ARCHIVE_DIR" 2>/dev/null | sed 's/^/    /'
fi

# ------------------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------------------
echo ""
log_info "Log rotation setup complete!"
echo ""
echo "Rotation: daily via /etc/cron.daily/logrotate"
echo "Archives: $LOG_ARCHIVE_DIR"
echo ""
echo "Commands:"
echo "  sudo logrotate -f /etc/logrotate.d/gcore      # Force rotation now"
echo "  sudo logrotate --debug /etc/logrotate.d/gcore # Test without rotating"
