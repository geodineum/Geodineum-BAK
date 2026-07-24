#!/bin/bash
# Offsite push: newest ValKey RDB snapshot (+ .meta sidecar) → Proton Drive.
# Runs after the nightly backup-valkey.sh (see valkey-offsite-protondrive.timer).
# Requires a one-time `proton-drive auth login` as the invoking user (root for
# the timer) — see /tmp/proton-drive-setup.sh guidance or CONTRACT.md §offsite.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
BACKUP_DIR="${BACKUP_DIR:-$PROJECT_ROOT/backups/valkey}"
REMOTE_ROOT="${PROTON_REMOTE_ROOT:-/geodineum-backups/$(hostname -s)}"
PROTON_BIN="${PROTON_BIN:-/usr/local/bin/proton-drive}"
export PROTON_DRIVE_CREDENTIALS_STORE="${PROTON_DRIVE_CREDENTIALS_STORE:-unsafe_file}"
KEEP_REMOTE="${PROTON_KEEP_REMOTE:-14}"

log() { echo "[offsite-protondrive] $*"; }

[[ -x "$PROTON_BIN" ]] || { log "proton-drive CLI not installed ($PROTON_BIN) — run proton-drive-setup"; exit 1; }

LATEST=$(ls -t "$BACKUP_DIR"/dump_*.rdb 2>/dev/null | head -1 || true)
[[ -n "$LATEST" ]] || { log "no local snapshots in $BACKUP_DIR"; exit 1; }
META="${LATEST%.rdb}.meta"

# Auth check first — a clear message beats a cryptic upload failure.
if ! "$PROTON_BIN" filesystem list / >/dev/null 2>&1; then
    log "not authenticated — run 'proton-drive auth login' as $(whoami) (see setup guidance)"
    exit 1
fi

"$PROTON_BIN" filesystem list "$REMOTE_ROOT" >/dev/null 2>&1 \
    || "$PROTON_BIN" filesystem mkdir "$REMOTE_ROOT" >/dev/null 2>&1 || true

log "uploading $(basename "$LATEST") → $REMOTE_ROOT"
"$PROTON_BIN" filesystem upload "$LATEST" "$REMOTE_ROOT" >/dev/null
[[ -f "$META" ]] && "$PROTON_BIN" filesystem upload "$META" "$REMOTE_ROOT" >/dev/null

# Remote rotation: keep the newest $KEEP_REMOTE snapshots (name-sorted =
# time-sorted for dump_YYYYmmdd_HHMMSS). Best-effort; --json when available.
if REMOTE_LIST=$("$PROTON_BIN" filesystem list "$REMOTE_ROOT" --json 2>/dev/null); then
    echo "$REMOTE_LIST" | python3 - "$KEEP_REMOTE" <<'PYEOF' | while IFS= read -r victim; do
import json, sys
keep = int(sys.argv[1])
try:
    items = json.load(sys.stdin)
except Exception:
    sys.exit(0)
names = sorted(
    (i.get("name", "") for i in (items if isinstance(items, list) else items.get("items", []))
     if str(i.get("name", "")).startswith("dump_") and str(i.get("name", "")).endswith(".rdb")),
    reverse=True)
for n in names[keep:]:
    print(n)
PYEOF
        log "pruning remote $victim"
        "$PROTON_BIN" filesystem remove "$REMOTE_ROOT/$victim" >/dev/null 2>&1 || true
        "$PROTON_BIN" filesystem remove "$REMOTE_ROOT/${victim%.rdb}.meta" >/dev/null 2>&1 || true
    done
fi

log "offsite push complete: $(basename "$LATEST") → $REMOTE_ROOT (remote keep=$KEEP_REMOTE)"
