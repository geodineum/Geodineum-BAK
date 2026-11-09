#!/bin/bash
# on the node, as root: fetch one real archive from the Storage Box for the restore drill, checked against the box's
# own hash, into ~/restore-drill of the user who ran sudo (folder root-owned 0750, file 0640, both readable by that
# user's group, so nothing in the folder can be swapped for a link). It stays encrypted: the node holds no key that
# opens it. The drill itself runs where the private key is (scripts/restore-drill.sh).
#   sudo bash scripts/restore-drill-fetch.sh            the newest archive
#   sudo bash scripts/restore-drill-fetch.sh --list     what the box holds, nothing fetched
#   sudo bash scripts/restore-drill-fetch.sh sites_20261109_014457.tar.zst.gpg
#   sudo bash scripts/restore-drill-fetch.sh --clean    remove ~/restore-drill afterwards
set -uo pipefail
CONF_DIR="${SITES_BACKUP_CONF:-/etc/geodineum-sites-backup}"
NAME_RE='sites_[0-9]{8}_[0-9]{6}\.tar\.zst\.gpg'
H="$(hostname -s)"
die() { echo "on $H: STOP: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "run with sudo"
OWNER="${SUDO_USER:-}"
[[ -n "$OWNER" && "$OWNER" != root ]] || die "run it with sudo from your own login, so the archive lands in your home"
HOME_DIR="$(getent passwd "$OWNER" | cut -d: -f6)"
[[ -d "$HOME_DIR" ]] || die "no home directory for $OWNER"
GROUP="$(id -gn "$OWNER")"
DEST="$HOME_DIR/restore-drill"
if [[ -e "$DEST" || -L "$DEST" ]]; then
    [[ -d "$DEST" && ! -L "$DEST" && "$(stat -c %u "$DEST")" == 0 ]] || die "$DEST exists and is not this script's folder; move it away first"
fi
if [[ "${1:-}" == --clean ]]; then
    rm -rf --one-file-system "$DEST"; echo "on $H: $DEST removed"; exit 0
fi
[[ -r "$CONF_DIR/storagebox.env" ]] || die "no $CONF_DIR/storagebox.env: this node has no Storage Box backup set up"
# shellcheck source=/dev/null
source "$CONF_DIR/storagebox.env"
[[ -n "${BOX_USER:-}" && -n "${BOX_HOST:-}" && -n "${BOX_DIR:-}" ]] || die "$CONF_DIR/storagebox.env is incomplete"
SSH_OPTS=(-p 23 -i "$CONF_DIR/id_ed25519" -o BatchMode=yes -o StrictHostKeyChecking=yes
          -o UserKnownHostsFile="$CONF_DIR/known_hosts" -o ConnectTimeout=20)
box_sftp() { sftp -q -b - -P 23 -i "$CONF_DIR/id_ed25519" -o BatchMode=yes -o StrictHostKeyChecking=yes \
                  -o UserKnownHostsFile="$CONF_DIR/known_hosts" -o ConnectTimeout=20 "$BOX_USER@$BOX_HOST"; }

listing="$(box_sftp <<<"ls -l $BOX_DIR" 2>&1)" || die "the box did not answer: $(head -1 <<<"$listing")"
mapfile -t archives < <(grep -oE "$NAME_RE" <<<"$listing" | sort -u)
(( ${#archives[@]} )) || die "no archives in $BOX_HOST:$BOX_DIR"

if [[ "${1:-}" == --list ]]; then
    echo "on $H: $BOX_HOST:$BOX_DIR holds ${#archives[@]} archives:"
    awk '$NF ~ /^sites_[0-9]+_[0-9]+[.]tar[.]zst[.]gpg$/ {printf "  %s  %.0f MiB\n", $NF, $5 / 1048576}' <<<"$listing" | sort
    exit 0
fi
NAME="${1:-${archives[-1]}}"
[[ "$NAME" =~ ^$NAME_RE$ ]] || die "not an archive name: $NAME"
grep -xF -- "$NAME" <<<"$(printf '%s\n' "${archives[@]}")" >/dev/null || die "$NAME is not on the box (--list shows what is)"

install -d -m 0750 -o root -g "$GROUP" "$DEST"
PART="$DEST/.$NAME.part"
rm -f "$PART"
trap 'rm -f "$PART"' EXIT
echo "on $H: fetching $NAME from $BOX_HOST:$BOX_DIR"
(umask 077; printf 'get %s/%s %s\n' "$BOX_DIR" "$NAME" "$PART" | box_sftp >/dev/null) || die "the download failed"
remote_sum="$(ssh "${SSH_OPTS[@]}" "$BOX_USER@$BOX_HOST" sha256sum "$BOX_DIR/$NAME" 2>/dev/null | cut -d' ' -f1)"
local_sum="$(sha256sum "$PART" | cut -d' ' -f1)"
[[ -n "$remote_sum" && "$remote_sum" == "$local_sum" ]] || die "the copy hashes to $local_sum, the box says ${remote_sum:-nothing}"
chgrp "$GROUP" "$PART"; chmod 0640 "$PART"
mv -f "$PART" "$DEST/$NAME"
trap - EXIT

echo "on $H: $DEST/$NAME ($(du -h "$DEST/$NAME" | cut -f1)), sha256 matches the box"
echo "next, on the machine that holds the backup private key (not this node):"
echo "  scp $H:restore-drill/$NAME ."
echo "  bash restore-drill.sh $NAME        (from Geodineum-BAK/scripts; docker there also proves a real database import)"
echo "afterwards, here: sudo bash $0 --clean"
