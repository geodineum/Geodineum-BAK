#!/bin/bash
# Nightly sites backup to the Hetzner Storage Box: /var/www, every MySQL database, the newest ValKey
# snapshot and the Apache vhosts, as one archive encrypted to the operator's public key (aesir holds no
# key that can read it). Set up once with scripts/storagebox-setup.sh; run by sites-backup.timer.
set -euo pipefail

CONF_DIR="${SITES_BACKUP_CONF:-/etc/geodineum-sites-backup}"
WORK="${CACHE_DIRECTORY:-/var/cache/geodineum-sites-backup}"
KEEP_DAILY="${KEEP_DAILY:-30}"
KEEP_MONTHLY="${KEEP_MONTHLY:-12}"
VALKEY_BACKUPS="${VALKEY_BACKUPS:-/opt/geodineum/Geodineum-BAK/backups/valkey}"
SOURCES=(var/www etc/apache2/sites-available)
NAME_RE='sites_[0-9]{8}_[0-9]{6}\.tar\.zst\.gpg'

log() { echo "[sites-backup] $*"; }
die() { log "FAILED: $*"; exit 1; }

# Archives to delete: all but the newest KEEP_DAILY, and the oldest of each of the newest KEEP_MONTHLY months.
pick_victims() {
    sort -u -r | awk -v d="$KEEP_DAILY" -v m="$KEEP_MONTHLY" '
        { n[NR] = $0; mon = substr($0, 7, 6); oldest[mon] = NR; if (!(mon in seen)) { seen[mon] = 1; months[++k] = mon } }
        END { for (i = 1; i <= k && i <= m; i++) keep[oldest[months[i]]] = 1
              for (i = 1; i <= NR; i++) if (i > d && !(i in keep)) print n[i] }'
}
[[ "${1:-}" == --pick-victims ]] && { pick_victims; exit 0; }

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
trap 'rm -rf "$RUN"' EXIT
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

tar -C / -cf - "${SOURCES[@]}" -C "$RUN/stage" mysql valkey \
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
log "done: $(basename "$OUT") on $BOX_HOST:$BOX_DIR; $kept archives kept (keep $KEEP_DAILY daily + $KEEP_MONTHLY monthly; ${total} GiB before pruning)"
