#!/bin/bash
# Offsite push: newest ValKey RDB snapshot (+ .meta sidecar) → Proton Drive.
# Started by valkey-backup.service on success (valkey-backup.service.d/offsite.conf).
# Requires a one-time `proton-drive auth login` as root; scripts/deploy.sh checks the CLI and the login first.
# CLI surface used (proton-drive usage): filesystem list | info | create-folder parent name | upload local... parent | delete path...
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
BACKUP_DIR="${BACKUP_DIR:-$PROJECT_ROOT/backups/valkey}"
REMOTE_ROOT="${PROTON_REMOTE_ROOT:-/geodineum-backups/$(hostname -s)}"
PROTON_BIN="${PROTON_BIN:-/usr/local/bin/proton-drive}"
export PROTON_DRIVE_CREDENTIALS_STORE="${PROTON_DRIVE_CREDENTIALS_STORE:-unsafe_file}"
KEEP_REMOTE="${PROTON_KEEP_REMOTE:-14}"

log() { echo "[offsite-protondrive] $*"; }
pd() { "$PROTON_BIN" "$@"; }

[[ -x "$PROTON_BIN" ]] || { log "proton-drive CLI not installed ($PROTON_BIN)"; exit 1; }

LATEST=$(ls -t "$BACKUP_DIR"/dump_*.rdb 2>/dev/null | head -1 || true)
[[ -n "$LATEST" ]] || { log "no local snapshots in $BACKUP_DIR"; exit 1; }
META="${LATEST%.rdb}.meta"

if ! out=$(pd filesystem list / 2>&1); then
    log "cannot list the drive root — not logged in as $(whoami)? the CLI said: $(head -c 300 <<<"$out")"
    exit 1
fi

# Each missing folder on the way to REMOTE_ROOT is created under its parent.
parent=""
IFS='/' read -r -a parts <<<"${REMOTE_ROOT#/}"
for part in "${parts[@]}"; do
    [[ -n "$part" ]] || continue
    path="${parent}/${part}"
    if ! pd filesystem info "$path" >/dev/null 2>&1; then
        pd filesystem create-folder "${parent:-/}" "$part" >/dev/null || { log "cannot create $path"; exit 1; }
        log "created $path"
    fi
    parent="$path"
done

files=("$LATEST"); [[ -f "$META" ]] && files+=("$META")
log "uploading $(basename "$LATEST") → $REMOTE_ROOT"
pd filesystem upload "${files[@]}" "$REMOTE_ROOT" >/dev/null

# Rotation by name only: whatever the listing's format, the snapshot names are dump_YYYYmmdd_HHMMSS.rdb,
# and only those, in this folder, are ever deleted.
listing=$(pd filesystem list "$REMOTE_ROOT" 2>/dev/null || true)
grep -qF "$(basename "$LATEST")" <<<"$listing" || { log "$(basename "$LATEST") is not listed under $REMOTE_ROOT after the upload"; exit 1; }
mapfile -t victims < <(grep -oE 'dump_[0-9]{8}_[0-9]{6}\.rdb' <<<"$listing" | sort -u -r | tail -n +$((KEEP_REMOTE + 1)))
for v in "${victims[@]}"; do
    targets=("$REMOTE_ROOT/$v")
    grep -qF "${v%.rdb}.meta" <<<"$listing" && targets+=("$REMOTE_ROOT/${v%.rdb}.meta")
    pd filesystem delete "${targets[@]}" >/dev/null 2>&1 && log "pruned $v" || log "could not prune $v"
done

log "offsite push complete: $(basename "$LATEST") → $REMOTE_ROOT (remote keep=$KEEP_REMOTE)"
