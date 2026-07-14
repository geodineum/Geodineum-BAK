#!/bin/bash
#
# gNode ValKey Backup Script (Systemd Version with ACL Support)
# Performs RDB backup with rotation and integrity verification
#
# Usage:
#   ./scripts/backup-valkey.sh [--keep N] [--backup-dir DIR] [--data-dir DIR]
#
# Options:
#   --keep N          Keep N most recent backups (default: 7)
#   --backup-dir DIR  Backup directory (default: backups/valkey)
#   --data-dir DIR    ValKey data directory (default: auto-discovered via CONFIG GET)
#

set -euo pipefail  # Exit on error, unset vars, and pipe failures

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Canonical ecosystem config loader (installed by Geodineum installer).
GEODINEUM_LIB="${GEODINEUM_LIB:-/usr/local/lib/geodineum}"
if [ ! -r "$GEODINEUM_LIB/bootstrap-loader.sh" ]; then
    echo "FATAL: $GEODINEUM_LIB/bootstrap-loader.sh not found. Run installer first." >&2
    exit 1
fi
# shellcheck source=/usr/local/lib/geodineum/bootstrap-loader.sh
source "$GEODINEUM_LIB/bootstrap-loader.sh"
load_ecosystem_config

# Credential directories (same resolution order as valkey-cli-secure.sh and PHP CredentialResolver)
CENTRALIZED_CREDS="${GEODINEUM_CREDENTIALS_DIR:-/etc/geodineum/credentials}"
STANDARD_CREDS="$PROJECT_ROOT/.gnode"
LEGACY_CREDS="/opt/gNode/.gnode"

# ValKey data directory — resolved dynamically after auth is loaded (see below)
VALKEY_DATA_DIR=""
VALKEY_RDB_FILE=""

# ACL credentials: search centralized → standard → legacy
VALKEY_AUTH_USER=""
VALKEY_PASSWORD_FILE=""
for creds_dir in "$CENTRALIZED_CREDS" "$STANDARD_CREDS" "$LEGACY_CREDS"; do
    if [ -f "$creds_dir/valkey_daemon.password" ]; then
        VALKEY_AUTH_USER="gnode_daemon"
        VALKEY_PASSWORD_FILE="$creds_dir/valkey_daemon.password"
        echo "Using ACL daemon credentials for backup ($creds_dir)"
        break
    elif [ -f "$creds_dir/valkey.password" ]; then
        VALKEY_AUTH_USER=""
        VALKEY_PASSWORD_FILE="$creds_dir/valkey.password"
        echo "Using admin credentials for backup ($creds_dir)"
        break
    fi
done

if [ -z "$VALKEY_PASSWORD_FILE" ]; then
    echo "Error: No ValKey password file found in:"
    echo "  - $CENTRALIZED_CREDS"
    echo "  - $STANDARD_CREDS"
    echo "  - $LEGACY_CREDS"
    exit 1
fi

# Default settings
BACKUP_DIR="$PROJECT_ROOT/backups/valkey"
KEEP_BACKUPS=7
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --keep)
            KEEP_BACKUPS="$2"
            shift 2
            ;;
        --backup-dir)
            BACKUP_DIR="$2"
            shift 2
            ;;
        --data-dir)
            VALKEY_DATA_DIR="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--keep N] [--backup-dir DIR] [--data-dir DIR]"
            exit 1
            ;;
    esac
done

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if ValKey service is running. The canonical Geodineum unit name
# is valkey-gnode.service. install.sh's Phase 4 enforces this name and
# purges any legacy units (valkey.service, valkey-server.service) so the
# fleet stays homogenous. Refusing to back up against an unknown unit is
# the right pre-launch posture per "no backward compatibility" discipline.
if ! systemctl is-active --quiet valkey-gnode.service; then
    log_error "ValKey service (valkey-gnode.service) is not running"
    log_error "If your install left legacy units (valkey.service / valkey-server.service)"
    log_error "running, re-run the installer Phase 4 to migrate, or manually:"
    log_error "  sudo systemctl stop  valkey valkey-server 2>/dev/null"
    log_error "  sudo systemctl disable valkey valkey-server 2>/dev/null"
    log_error "  sudo systemctl start valkey-gnode"
    exit 1
fi

# Load password
if [ ! -f "$VALKEY_PASSWORD_FILE" ]; then
    log_error "ValKey password not found: $VALKEY_PASSWORD_FILE"
    exit 1
fi
VALKEY_PASSWORD=$(cat "$VALKEY_PASSWORD_FILE" | tr -d '\n')

log_info "Starting ValKey backup..."

# Create backup directory
mkdir -p "$BACKUP_DIR"

# Advisory flock so manual + timer-fired runs don't race over
# the same backup_dir. flock is held for the lifetime of the script via
# fd 9; on exit (success, error, or signal) the kernel auto-releases it.
# `-n` (nonblock) means a contending run exits cleanly with status 0
# rather than queueing up — daily timer + accidental manual run is the
# expected case, not a worker pool.
exec 9>"$BACKUP_DIR/.backup-valkey.lock"
if ! flock -n 9; then
    log_warn "Another backup is in progress (flock contention) — exiting cleanly"
    exit 0
fi

# ValKey connection flags (sourced from bootstrap.env)
VALKEY_CLI_FLAGS=(-h "${VALKEY_HOST:-127.0.0.1}" -p "${VALKEY_PORT:-47445}")

# Execute a ValKey command with the password fed via stdin (never argv,
# never env). Prevents REDISCLI_AUTH leak via /proc/<pid>/environ
# and xtrace leak under `bash -x`:
#   - Subshell `( set +x; printf ... )` shields the password line from
#     xtrace; subshell isolation means xtrace state is preserved for the
#     parent script.
#   - `2>/dev/null` redirects the trace of `set +x` itself.
#   - First stdin line is `AUTH ...`; remaining lines are the command
#     tokens; valkey-cli reads from stdin in interactive mode.
#   - `--no-auth-warning` suppresses the "using --pass" deprecation
#     hint; `tail -n +2` strips the `OK` returned by AUTH so callers
#     see only the actual command's output.
valkey_cmd() {
    local cmd_str
    cmd_str=$(printf '%s ' "$@")
    cmd_str="${cmd_str% }"

    if [ -n "$VALKEY_AUTH_USER" ]; then
        ( set +x; printf 'AUTH %s %s\n%s\n' "$VALKEY_AUTH_USER" "$VALKEY_PASSWORD" "$cmd_str" ) 2>/dev/null \
            | valkey-cli --no-auth-warning "${VALKEY_CLI_FLAGS[@]}" 2>/dev/null \
            | tail -n +2 \
            | { grep -v "Warning" || true; }
    else
        ( set +x; printf 'AUTH %s\n%s\n' "$VALKEY_PASSWORD" "$cmd_str" ) 2>/dev/null \
            | valkey-cli --no-auth-warning "${VALKEY_CLI_FLAGS[@]}" 2>/dev/null \
            | tail -n +2 \
            | { grep -v "Warning" || true; }
    fi
}

# Discover ValKey data directory dynamically
# Priority: --data-dir flag → CONFIG GET dir → known filesystem locations
if [ -z "$VALKEY_DATA_DIR" ]; then
    VALKEY_DATA_DIR=$(valkey_cmd CONFIG GET dir | tail -1)
fi
if [ -z "$VALKEY_DATA_DIR" ] || [ "$VALKEY_DATA_DIR" = "dir" ]; then
    log_warn "CONFIG GET dir failed (ACL may restrict it) — probing filesystem"
    for candidate in /var/lib/valkey-gnode /var/lib/valkey-gsd /var/lib/valkey; do
        if [ -f "$candidate/dump.rdb" ]; then
            VALKEY_DATA_DIR="$candidate"
            break
        fi
    done
fi
if [ -z "$VALKEY_DATA_DIR" ]; then
    log_error "Could not discover ValKey data directory"
    log_error "Grant CONFIG permission to $VALKEY_AUTH_USER or pass --data-dir"
    exit 1
fi

# realpath + whitelist gate. ValKey actor with CONFIG SET could
# return a malicious dir; the --data-dir flag also accepts arbitrary
# operator input. Whitelist: directory must canonicalize to a path under
# /var/lib/valkey* before we cp from it. Symlink in the whitelisted
# parent is fine — realpath resolves it. Symlink/path-traversal that
# escapes /var/lib/valkey* is rejected hard.
VALKEY_DATA_DIR_REAL="$(realpath -m "$VALKEY_DATA_DIR" 2>/dev/null || true)"
case "$VALKEY_DATA_DIR_REAL" in
    /var/lib/valkey|/var/lib/valkey-*|/var/lib/valkey/*|/var/lib/valkey-*/*) ;;
    *)
        log_error "VALKEY_DATA_DIR '$VALKEY_DATA_DIR' resolved to '$VALKEY_DATA_DIR_REAL' which is not under /var/lib/valkey* — refusing backup"
        log_error "If your ValKey data lives elsewhere, edit this whitelist after operator review"
        exit 1
        ;;
esac
VALKEY_DATA_DIR="$VALKEY_DATA_DIR_REAL"
VALKEY_RDB_FILE="$VALKEY_DATA_DIR/dump.rdb"
log_info "ValKey data directory: $VALKEY_DATA_DIR"

# Trigger BGSAVE to create fresh RDB snapshot
log_info "Triggering background save (BGSAVE)..."
LASTSAVE_BEFORE=$(valkey_cmd LASTSAVE | tail -1)

# Execute BGSAVE via the stdin-AUTH wrapper (no env-var leak).
valkey_cmd BGSAVE > /dev/null 2>&1

# Wait for BGSAVE to complete
BGSAVE_TIMEOUT=60
ELAPSED=0
BGSAVE_COMPLETE=0

while [ $ELAPSED -lt $BGSAVE_TIMEOUT ]; do
    sleep 2
    LASTSAVE_CURRENT=$(valkey_cmd LASTSAVE | tail -1)

    if [ "$LASTSAVE_CURRENT" != "$LASTSAVE_BEFORE" ] && [ -n "$LASTSAVE_CURRENT" ]; then
        log_info "Background save completed"
        BGSAVE_COMPLETE=1
        break
    fi

    ELAPSED=$((ELAPSED + 2))
done

if [ $BGSAVE_COMPLETE -eq 0 ]; then
    log_warn "BGSAVE timeout - proceeding with current RDB file"
fi

# Check if RDB file exists
if [ ! -f "$VALKEY_RDB_FILE" ]; then
    log_error "RDB file not found at $VALKEY_RDB_FILE"
    exit 1
fi

# Create backup with timestamp
BACKUP_FILE="$BACKUP_DIR/dump_${TIMESTAMP}.rdb"
log_info "Copying RDB file to: $BACKUP_FILE"

# Copy RDB file
# ValKey RDB is typically world-readable (644) — direct cp works for any user.
# The copy is a full-keyspace snapshot: strip the others bit immediately
# (ecosystem policy: nothing world-readable unless it must be).
cp "$VALKEY_RDB_FILE" "$BACKUP_FILE"
chmod 640 "$BACKUP_FILE"
# If running as root (manual), chown to service user for consistent ownership.
if [ "$EUID" -eq 0 ]; then
    # Absolute path for chown so the operator's PATH cannot supply a
    # shadowed binary. Mirrors the same sweep on the installer side.
    /usr/bin/chown "${GNODE_USER:-gnode}:${GNODE_GROUP:-gnode}" "$BACKUP_FILE"
fi

# Verify backup exists and get size
if [ ! -f "$BACKUP_FILE" ]; then
    log_error "Backup failed: file not created"
    exit 1
fi

BACKUP_SIZE=$(stat -c%s "$BACKUP_FILE" 2>/dev/null || stat -f%z "$BACKUP_FILE" 2>/dev/null)

# Verify backup has reasonable size (at least 100 bytes)
if [ "$BACKUP_SIZE" -lt 100 ]; then
    log_error "Backup verification failed: file too small ($BACKUP_SIZE bytes)"
    rm "$BACKUP_FILE"
    exit 1
fi

# Create metadata file
METADATA_FILE="$BACKUP_DIR/dump_${TIMESTAMP}.meta"

# Server info via the stdin-AUTH wrapper.
SERVER_INFO=$(valkey_cmd INFO Server | grep -E "redis_version|server_name|valkey_version|redis_mode|os|arch|process_id|uptime_in_days" || echo "unavailable")
KEYSPACE_INFO=$(valkey_cmd INFO Keyspace || echo "unavailable")

cat > "$METADATA_FILE" << EOF
timestamp: $TIMESTAMP
date: $(date)
size: $BACKUP_SIZE
md5: $(md5sum "$BACKUP_FILE" | awk '{print $1}')
auth_method: $([ -n "$VALKEY_AUTH_USER" ] && echo "ACL ($VALKEY_AUTH_USER)" || echo "legacy (default)")
valkey_info:
$SERVER_INFO
database_info:
$KEYSPACE_INFO
EOF

chmod 640 "$METADATA_FILE"

log_info "Backup completed: $BACKUP_FILE"
log_info "Backup size: $(numfmt --to=iec-i --suffix=B $BACKUP_SIZE 2>/dev/null || echo "$BACKUP_SIZE bytes")"

# Per-service backup hints (LAYER_6 of the manifest contract). Best-effort —
# the RDB snapshot above covers all ValKey state wholesale regardless of what
# any service declares here; this loop only LOGS what each registered service
# considers its important state. Failure here MUST NOT affect the backup.
log_per_service_hints() {
    # Need yq + a way to scan /opt/geodineum/*/geodeploy.yaml. Skip if yq
    # missing (older squad images).
    command -v yq >/dev/null 2>&1 || { return 0; }
    local geo_root="${GEODINEUM_ROOT:-/opt/geodineum}"
    [[ -d "$geo_root" ]] || return 0

    local svc_count=0 hinted_count=0
    local mf
    # Scan two depths: components themselves AND services they bundle.
    for mf in "${geo_root}"/*/geodeploy.yaml "${geo_root}"/*/services/*/geodeploy.yaml; do
        [[ -f "$mf" ]] || continue
        svc_count=$((svc_count + 1))
        local has_backup
        has_backup=$(yq eval '.backup // ""' "$mf" 2>/dev/null)
        [[ -z "$has_backup" || "$has_backup" == "null" || "$has_backup" == "" ]] && continue

        local name
        name=$(yq eval '.name // ""' "$mf" 2>/dev/null)
        [[ -z "$name" || "$name" == "null" ]] && name=$(basename "$(dirname "$mf")")

        local k_n f_n e_n sched
        k_n=$(yq    eval '(.backup.keys // [])    | length' "$mf" 2>/dev/null)
        f_n=$(yq    eval '(.backup.files // [])   | length' "$mf" 2>/dev/null)
        e_n=$(yq    eval '(.backup.exclude // []) | length' "$mf" 2>/dev/null)
        sched=$(yq  eval '.backup.schedule // "daily"'      "$mf" 2>/dev/null)

        log_info "  ${name}: ${k_n} key pattern(s), ${f_n} file path(s), ${e_n} exclude(s), schedule=${sched}"
        hinted_count=$((hinted_count + 1))
    done

    if [[ $svc_count -gt 0 ]]; then
        log_info "Per-service backup introspection: ${hinted_count} of ${svc_count} services declared backup: hints"
        log_info "  (RDB snapshot above is wholesale — hints are introspective, not selective)"
    fi
    return 0
}
log_per_service_hints || true

# Rotate old backups
log_info "Rotating backups (keeping $KEEP_BACKUPS most recent)..."
OLD_BACKUPS=$(ls -t "$BACKUP_DIR"/dump_*.rdb 2>/dev/null | tail -n +$((KEEP_BACKUPS + 1)) || true)

if [ -n "$OLD_BACKUPS" ]; then
    REMOVED_COUNT=0
    while IFS= read -r old_backup; do
        if [ -f "$old_backup" ]; then
            BACKUP_BASE=$(basename "$old_backup" .rdb)
            rm -f "$old_backup"
            rm -f "$BACKUP_DIR/${BACKUP_BASE}.meta"
            REMOVED_COUNT=$((REMOVED_COUNT + 1))
        fi
    done <<< "$OLD_BACKUPS"

    if [ $REMOVED_COUNT -gt 0 ]; then
        log_info "Removed $REMOVED_COUNT old backup(s)"
    fi
fi

# Summary
TOTAL_BACKUPS=$(ls -1 "$BACKUP_DIR"/dump_*.rdb 2>/dev/null | wc -l)
TOTAL_SIZE=$(du -sh "$BACKUP_DIR" 2>/dev/null | awk '{print $1}')

log_info "Backup summary:"
log_info "  Total backups: $TOTAL_BACKUPS"
log_info "  Total size: $TOTAL_SIZE"
log_info "  Latest: dump_${TIMESTAMP}.rdb"

# List recent backups
log_info "Recent backups:"
ls -lh "$BACKUP_DIR"/dump_*.rdb 2>/dev/null | tail -5 | awk '{print "  " $9 " (" $5 ")"}'

log_info "Backup completed successfully"
