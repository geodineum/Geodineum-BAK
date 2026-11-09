#!/bin/bash
# Nightly backup of a whole node to the Hetzner Storage Box: /var/www, every MySQL database, the newest ValKey
# snapshot, the node's configuration and credentials, and the local SQLite stores, as one archive encrypted to
# the operator's public key (aesir holds no key that can read it). Restoring gives a node back, not only its
# files: scripts/restore-drill.sh proves that on the workstation. Set up once with scripts/storagebox-setup.sh;
# run by sites-backup.timer.
set -euo pipefail

CONF_DIR="${SITES_BACKUP_CONF:-/etc/geodineum-sites-backup}"
WORK="${CACHE_DIRECTORY:-/var/cache/geodineum-sites-backup}"
KEEP_DAILY="${KEEP_DAILY:-7}"
KEEP_WEEKLY="${KEEP_WEEKLY:-4}"
KEEP_MONTHLY="${KEEP_MONTHLY:-12}"
VALKEY_BACKUPS="${VALKEY_BACKUPS:-/opt/geodineum/Geodineum-BAK/backups/valkey}"
SOURCES=(var/www etc/apache2 etc/geodineum etc/geodineum-sites-backup/recipient.asc etc/letsencrypt etc/php etc/opendkim
         etc/valkey etc/fail2ban etc/gshield etc/geoblock etc/postfix etc/systemd/system var/lib/geodineum var/lib/gshield
         var/lib/gshield-decide var/lib/geodineum-sites var/lib/geodineum-watch)
SQLITE_DIRS=(var/lib/geodineum-comms var/lib/gnode-comms var/lib/gflow)
NAME_RE='sites_[0-9]{8}_[0-9]{6}\.tar\.zst\.gpg'
# Read hourly by the COMMS watch (group adm), which alerts on a failed run or no success in max_age_h.
STATUS="${SITES_BACKUP_STATUS:-/var/lib/geodineum-watch/sites-backup.status}"
RECORDED=0

log() { echo "[sites-backup] $*"; }
record() {
    [[ -w "$(dirname "$STATUS")" ]] || return 0
    local now ok; now="$(date +%s%3N)"; ok="$(sed -n 's/^ok_ms=//p' "$STATUS" 2>/dev/null || true)"
    [[ -z "$1" ]] && ok="$now"
    printf 'what=sites backup to the Storage Box\nmax_age_h=26\nok_ms=%s\nrun_ms=%s\nerror=%s\n' "${ok:-0}" "$now" "${1//$'\n'/ }" >"$STATUS.tmp" || return 0
    chgrp adm "$STATUS.tmp" 2>/dev/null; chmod 0640 "$STATUS.tmp"; mv -f "$STATUS.tmp" "$STATUS"
    RECORDED=1
}
die() { log "FAILED: $*"; record "$*"; exit 1; }

# Archives to delete: all but the newest KEEP_DAILY, the oldest of each of the newest KEEP_WEEKLY ISO weeks and the
# oldest of each of the newest KEEP_MONTHLY months (7 + 4 + 12 = at most 23 on the box; fewer where they coincide).
pick_victims() {
    sort -u -r | while read -r n; do printf '%s %s\n' "$n" "$(date -d "${n:6:8}" +%G%V)"; done | awk -v d="$KEEP_DAILY" -v w="$KEEP_WEEKLY" -v m="$KEEP_MONTHLY" '
        { n[NR] = $1; wk = $2; mon = substr($1, 7, 6)
          oldw[wk] = NR; if (!(wk in sw)) { sw[wk] = 1; weeks[++kw] = wk }
          oldm[mon] = NR; if (!(mon in sm)) { sm[mon] = 1; months[++km] = mon } }
        END { for (i = 1; i <= kw && i <= w; i++) keep[oldw[weeks[i]]] = 1
              for (i = 1; i <= km && i <= m; i++) keep[oldm[months[i]]] = 1
              for (i = 1; i <= NR; i++) if (i > d && !(i in keep)) print n[i] }'
}
[[ "${1:-}" == --pick-victims ]] && { pick_victims; exit 0; }
RUN=""
on_exit() { local rc=$?; [[ -n "$RUN" ]] && rm -rf "$RUN"; (( rc == 0 || RECORDED )) || record "stopped with exit code $rc"; }
trap on_exit EXIT

[[ $EUID -eq 0 ]] || die "run as root (systemctl start sites-backup.service)"
[[ -r "$CONF_DIR/storagebox.env" ]] || die "no $CONF_DIR/storagebox.env; run scripts/storagebox-setup.sh first"
# shellcheck source=/dev/null
source "$CONF_DIR/storagebox.env"
: "${BOX_USER:?}" "${BOX_HOST:?}" "${BOX_DIR:?}"
SSH_OPTS=(-p 23 -i "$CONF_DIR/id_ed25519" -o BatchMode=yes -o StrictHostKeyChecking=yes
          -o UserKnownHostsFile="$CONF_DIR/known_hosts" -o ConnectTimeout=20)
box_sftp() { sftp -q -b - -P 23 -i "$CONF_DIR/id_ed25519" -o BatchMode=yes -o StrictHostKeyChecking=yes \
                  -o UserKnownHostsFile="$CONF_DIR/known_hosts" -o ConnectTimeout=20 "$BOX_USER@$BOX_HOST"; }

mkdir -m 0700 -p "$WORK"
exec 9>"$WORK/.lock"
flock -n 9 || { log "another run holds the lock; skipping"; exit 0; }
RUN="$WORK/run"; rm -rf "$RUN"; mkdir -m 0700 -p "$RUN/stage/mysql" "$RUN/stage/valkey" "$RUN/gnupg"
STAMP="$(date -u +%Y%m%d_%H%M%S)"; OUT="$RUN/sites_${STAMP}.tar.zst.gpg"

MYSQL_OPTS=(); [[ -r /etc/mysql/debian.cnf ]] && MYSQL_OPTS=(--defaults-file=/etc/mysql/debian.cnf)
mapfile -t dbs < <(mysql "${MYSQL_OPTS[@]}" -N -B -e 'SHOW DATABASES' | grep -vxE 'information_schema|performance_schema|mysql|sys')
(( ${#dbs[@]} )) || die "MySQL listed no databases"
for db in "${dbs[@]}"; do
    mysqldump "${MYSQL_OPTS[@]}" --single-transaction --quick --routines --triggers --events --set-gtid-purged=OFF "$db" \
        | zstd -q -3 -o "$RUN/stage/mysql/${db}.sql.zst" || die "dump of $db"
done
log "dumped ${#dbs[@]} databases ($(du -sh "$RUN/stage/mysql" | cut -f1))"

rdb="$(ls -t "$VALKEY_BACKUPS"/dump_*.rdb 2>/dev/null | head -1 || true)"
if [[ -n "$rdb" ]]; then cp "$rdb" "${rdb%.rdb}.meta" "$RUN/stage/valkey/" 2>/dev/null || cp "$rdb" "$RUN/stage/valkey/"
else log "warning: no ValKey snapshot in $VALKEY_BACKUPS"; fi

# A live SQLite file copied raw can be torn: take each through its own backup, and everything else as it is.
mkdir -m 0700 -p "$RUN/stage/sqlite"
EXCLUDE=()
for dir in "${SQLITE_DIRS[@]}"; do
    [[ -d "/$dir" ]] || continue
    while IFS= read -r -d '' db; do
        rel="${db#/}"; mkdir -p "$RUN/stage/sqlite/$(dirname "$rel")"
        python3 -I - "$db" "$RUN/stage/sqlite/$rel" <<'PY' || { log "warning: $db through a plain copy, its own backup failed"; cp "$db" "$RUN/stage/sqlite/$rel"; }
import sqlite3, sys
src = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True, timeout=30)
dst = sqlite3.connect(sys.argv[2])
with dst:
    src.backup(dst)
dst.close(); src.close()
PY
    done < <(find "/$dir" -type f \( -name '*.db' -o -name '*.sqlite' -o -name '*.sqlite3' \) -print0)
    SOURCES+=("$dir")
    EXCLUDE+=(--exclude='*.db' --exclude='*.db-wal' --exclude='*.db-shm' --exclude='*.sqlite' --exclude='*.sqlite-wal' --exclude='*.sqlite-shm' --exclude='*.sqlite3' --exclude='*.sqlite3-wal' --exclude='*.sqlite3-shm')
done
PRESENT=(); for s in "${SOURCES[@]}"; do [[ -e "/$s" ]] && PRESENT+=("$s"); done
log "sources: ${PRESENT[*]}"

# Exit 1 is tar saying a live file changed while it read it: on a running node that is normal.
tar_node() { tar -C / --warning=no-file-changed --warning=no-file-removed --ignore-failed-read "${EXCLUDE[@]}" -cf - "${PRESENT[@]}" -C "$RUN/stage" mysql valkey sqlite; local rc=$?; (( rc <= 1 )); }
tar_node \
    | zstd -q -3 -T0 \
    | gpg --batch --quiet --homedir "$RUN/gnupg" --trust-model always --compress-algo none \
          --recipient-file "$CONF_DIR/recipient.asc" --encrypt -o "$OUT" \
    || die "archive"
size=$(stat -c %s "$OUT")
log "archive $(basename "$OUT"): $((size / 1048576)) MiB"

rsync -t -e "ssh ${SSH_OPTS[*]}" "$OUT" "$BOX_USER@$BOX_HOST:$BOX_DIR/" || die "upload"
sum="$(sha256sum "$OUT" | cut -d' ' -f1)"
remote_sum="$(ssh "${SSH_OPTS[@]}" "$BOX_USER@$BOX_HOST" sha256sum "$BOX_DIR/$(basename "$OUT")" | cut -d' ' -f1)"
[[ "$remote_sum" == "$sum" ]] || die "$(basename "$OUT") on the box hashes to ${remote_sum:-nothing}, expected $sum"
listing="$(box_sftp <<<"ls -l $BOX_DIR")" || die "listing $BOX_DIR"

mapfile -t victims < <(grep -oE "$NAME_RE" <<<"$listing" | pick_victims)
if (( ${#victims[@]} )); then
    printf -- "-rm $BOX_DIR/%s\n" "${victims[@]}" | box_sftp >/dev/null \
        && log "pruned ${#victims[@]}: ${victims[*]}" || log "warning: pruning failed"
fi
kept=$(( $(grep -cE "$NAME_RE" <<<"$listing") - ${#victims[@]} ))
total=$(awk '$NF ~ /sites_[0-9_]+\.tar\.zst\.gpg$/ {s += $5} END {printf "%.1f", s / 1073741824}' <<<"$listing")
log "done: $(basename "$OUT") on $BOX_HOST:$BOX_DIR; $kept archives kept (keep $KEEP_DAILY daily + $KEEP_WEEKLY weekly + $KEEP_MONTHLY monthly; ${total} GiB before pruning)"
record ""
