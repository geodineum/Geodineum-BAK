#!/bin/bash
# One-time setup of the nightly sites backup to a Hetzner Storage Box. Run on the node, as root:
#   sudo bash scripts/storagebox-setup.sh --user u405941 --pubkey /path/to/backup-public-key.asc
# The box password is typed once into ssh's own prompt to install a key that only this backup uses;
# it is never stored or passed on a command line. The public key is the one archives are encrypted to;
# its private half stays with the operator, never on the node.
set -uo pipefail
BOX_USER=""; BOX_HOST=""; PUBKEY=""; BOX_DIR="$(hostname -s)/sites"
while (( $# )); do case "$1" in
    --user) BOX_USER="$2"; shift 2 ;; --host) BOX_HOST="$2"; shift 2 ;;
    --pubkey) PUBKEY="$2"; shift 2 ;; --dir) BOX_DIR="$2"; shift 2 ;;
    *) echo "unknown option $1" >&2; exit 2 ;; esac; done
H="$(hostname -s)"; C="${SITES_BACKUP_CONF:-/etc/geodineum-sites-backup}"
step() { echo; echo "on $H: [$1] $2"; }
die()  { echo "on $H: STOP: $*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die "run with sudo"
[[ "$BOX_USER" =~ ^u[0-9]+(-sub[0-9]+)?$ ]] || die "--user uNNNNNN (the Storage Box user name) is required"
BOX_HOST="${BOX_HOST:-${BOX_USER%%-sub*}.your-storagebox.de}"
[[ -r "$PUBKEY" ]] || die "--pubkey <file> is required: your exported GnuPG public key"
SSH=(ssh -p 23 -i "$C/id_ed25519" -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$C/known_hosts" -o ConnectTimeout=20)

step 1/6 "the public key archives are encrypted to"
G="$(mktemp -d)"; trap 'rm -rf "$G"' EXIT
shown="$(gpg --batch --homedir "$G" --with-colons --show-keys "$PUBKEY" 2>/dev/null)" || die "$PUBKEY is not a GnuPG key"
grep -q '^sec' <<<"$shown" && die "$PUBKEY contains a PRIVATE key; export only the public one (gpg --export --armor)"
awk -F: '($1 == "pub" || $1 == "sub") && $12 ~ /e/ { ok = 1 } END { exit !ok }' <<<"$shown" \
    || die "$PUBKEY has no encryption key"
gpg --batch --homedir "$G" --show-keys "$PUBKEY" 2>/dev/null | sed 's/^/  /'
install -d -m 0700 -o root -g root "$C"
install -m 0600 -o root -g root "$PUBKEY" "$C/recipient.asc"
echo test | gpg --batch --quiet --homedir "$G" --trust-model always --recipient-file "$C/recipient.asc" --encrypt >/dev/null \
    || die "encrypting to that key failed"

step 2/6 "the box's host key"
ssh-keyscan -p 23 -t ed25519,rsa "$BOX_HOST" 2>/dev/null >"$C/known_hosts.new"
[[ -s "$C/known_hosts.new" ]] || die "no SSH answer from $BOX_HOST:23 (is SSH support on for the box in the Hetzner console?)"
if [[ -s "$C/known_hosts" ]] && ! diff -q <(sort "$C/known_hosts") <(sort "$C/known_hosts.new") >/dev/null; then
    die "$BOX_HOST's host key differs from the pinned one in $C/known_hosts; find out why before going on"
fi
mv "$C/known_hosts.new" "$C/known_hosts"; chmod 0600 "$C/known_hosts"
ssh-keygen -lf "$C/known_hosts" | sed 's/^/  /'
echo "  (compare with the fingerprints Hetzner publishes for Storage Boxes)"

step 3/6 "this node's key for the box"
[[ -f "$C/id_ed25519" ]] || ssh-keygen -q -t ed25519 -N "" -C "sites-backup@$H" -f "$C/id_ed25519"
chmod 0600 "$C/id_ed25519"
if "${SSH[@]}" -o BatchMode=yes "$BOX_USER@$BOX_HOST" ls >/dev/null 2>&1; then
    echo "  the box already accepts it"
else
    echo "  type the Storage Box password when ssh asks (once; it is not saved):"
    "${SSH[@]}" -o PubkeyAuthentication=no "$BOX_USER@$BOX_HOST" install-ssh-key <"$C/id_ed25519.pub" \
        || die "installing the key failed"
    "${SSH[@]}" -o BatchMode=yes "$BOX_USER@$BOX_HOST" ls >/dev/null 2>&1 || die "the box still refuses the key"
    echo "  installed; from now on the key logs in, no password"
fi

step 4/6 "MySQL"
MYSQL_OPTS=(); [[ -r /etc/mysql/debian.cnf ]] && MYSQL_OPTS=(--defaults-file=/etc/mysql/debian.cnf)
dbs="$(mysql "${MYSQL_OPTS[@]}" -N -B -e 'SHOW DATABASES' 2>&1)" || die "root cannot reach MySQL: $dbs"
echo "  $(grep -cvxE 'information_schema|performance_schema|mysql|sys' <<<"$dbs") databases to dump"

step 5/6 "the folder on the box"
path=""; for part in ${BOX_DIR//\// }; do path="${path:+$path/}$part"; echo "-mkdir $path"; done \
    | sftp -q -b - -P 23 -i "$C/id_ed25519" -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$C/known_hosts" \
           "$BOX_USER@$BOX_HOST" >/dev/null || die "creating $BOX_DIR on the box failed"
echo "  $BOX_HOST:$BOX_DIR"

step 6/6 "settings"
umask 077
printf 'BOX_USER=%s\nBOX_HOST=%s\nBOX_DIR=%s\n' "$BOX_USER" "$BOX_HOST" "$BOX_DIR" >"$C/storagebox.env"
ls -l "$C" | sed 's/^/  /'
echo "on $H: set up. Next: sudo bash ~august/gh/Geodineum-BAK/scripts/deploy.sh --apply (installs and starts the nightly timer, then runs one backup)"
