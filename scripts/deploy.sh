#!/bin/bash
# The deliberate deploy path for Geodineum-BAK, which the orchestrator never pulls (a bad upstream commit
# must not take the backup path down with the cycle that broke everything else). Run from a checkout that
# is not the one it updates:
#   sudo bash ~august/gh/Geodineum-BAK/scripts/deploy.sh             dry run: what is pending, what would change
#   sudo bash ~august/gh/Geodineum-BAK/scripts/deploy.sh --apply     fast-forward, permissions, units; offsite on
#                                                                   once Proton Drive is authenticated, then one
#                                                                   push, checked on the remote
#   sudo bash ~august/gh/Geodineum-BAK/scripts/deploy.sh --apply --no-offsite   update only
set -uo pipefail
APPLY=0; OFFSITE=1
for a in "$@"; do case "$a" in --apply) APPLY=1 ;; --no-offsite) OFFSITE=0 ;; *) echo "unknown option $a" >&2; exit 2 ;; esac; done
H="$(hostname -s)"
B="${BAK_DIR:-/opt/geodineum/Geodineum-BAK}"
UNITS=/etc/systemd/system
PROTON_BIN="${PROTON_BIN:-/usr/local/bin/proton-drive}"
REMOTE_ROOT="${PROTON_REMOTE_ROOT:-/geodineum-backups/$H}"
export PROTON_DRIVE_CREDENTIALS_STORE=unsafe_file
step() { echo; echo "on $H: [$1] $2"; }
die()  { echo "on $H: STOP: $*" >&2; exit 1; }
run()  { if (( APPLY )); then "$@"; else echo "  would run: $*"; fi; }
[[ $EUID -eq 0 ]] || die "run with sudo"
[[ -d "$B/.git" ]] || die "no Geodineum-BAK checkout at $B"
[[ "$(cd "$(dirname "$0")/.." && pwd -P)" != "$(cd "$B" && pwd -P)" ]] || die "run this from another checkout (e.g. ~august/gh/Geodineum-BAK), not from $B"
G="$(stat -c %U "$B/.git")"
as_git() { sudo -u "$G" git -c safe.directory="$B" -C "$B" "$@"; }
git_root() { git -c safe.directory="$B" -C "$B" "$@"; }

step 1/5 "what is pending"
as_git fetch -q origin main || die "fetch failed (as $G)"
HEAD_WAS="$(as_git rev-parse HEAD)"; TARGET="$(as_git rev-parse origin/main)"
[[ -z "$(as_git status --porcelain --untracked-files=no)" ]] || die "$B has local changes; look at them first: git -C $B status"
as_git merge-base --is-ancestor "$HEAD_WAS" "$TARGET" || die "$B has commits origin/main does not; it cannot fast-forward"
if [[ "$HEAD_WAS" == "$TARGET" ]]; then echo "  up to date at ${HEAD_WAS:0:7}"
else echo "  ${HEAD_WAS:0:7} → ${TARGET:0:7}:"; as_git log --oneline "$HEAD_WAS..$TARGET" | sed 's/^/    /'; fi

step 2/5 "the incoming scripts parse"
bad=0
while IFS= read -r f; do
    as_git show "$TARGET:$f" | bash -n 2>/dev/null || { echo "  syntax error: $f"; bad=1; }
done < <(as_git ls-tree -r --name-only "$TARGET" -- scripts | grep '\.sh$')
(( bad == 0 )) || die "an incoming script does not parse; nothing changed"
echo "  every scripts/*.sh at ${TARGET:0:7} parses"

step 3/5 "fast-forward, permissions"
if [[ "$HEAD_WAS" != "$TARGET" ]]; then
    run git_root merge -q --ff-only "$TARGET"
    run chown -R "$G:$(stat -c %G "$B/.git")" "$B/.git"
fi
run chown -R root:gnode "$B/scripts"
run find "$B/scripts" \( -type d -o -name '*.sh' \) -exec chmod 0750 {} +
if (( APPLY )) && [[ "$HEAD_WAS" != "$TARGET" ]]; then
    echo "  at $(git_root rev-parse --short HEAD); to go back:"
    echo "    on $H: sudo git -c safe.directory=$B -C $B reset -q --hard ${HEAD_WAS:0:7} && sudo chown -R $G $B/.git"
fi

step 4/5 "the offsite unit"
if [[ -e "$UNITS/valkey-offsite-protondrive.timer" ]]; then
    run systemctl disable --now valkey-offsite-protondrive.timer
    run rm -f "$UNITS/valkey-offsite-protondrive.timer"
fi
run install -m 0644 -o root -g root "$B/config/systemd/valkey-offsite-protondrive.service" "$UNITS/valkey-offsite-protondrive.service"
run systemctl daemon-reload

step 5/5 "offsite: Proton Drive"
if (( ! OFFSITE )); then echo "  skipped (--no-offsite)"; exit 0; fi
[[ -x "$PROTON_BIN" ]] || die "no proton-drive CLI at $PROTON_BIN; install it, then run this again"
help="$("$PROTON_BIN" filesystem --help 2>&1 || true)"
missing=""; for c in list upload mkdir remove; do grep -qw "$c" <<<"$help" || missing+=" $c"; done
[[ -z "$missing" ]] || { echo "$help" | head -30; die "the CLI has no filesystem$missing, which offsite-protondrive.sh uses; fix the script before turning offsite on"; }
echo "  CLI has filesystem list, upload, mkdir, remove"
if ! "$PROTON_BIN" filesystem list / >/dev/null 2>&1; then
    echo "  not logged in as root. Log in once (a browser login; on a headless node forward the CLI's callback port):"
    echo "    on $H: sudo env PROTON_DRIVE_CREDENTIALS_STORE=unsafe_file $PROTON_BIN auth login"
    echo "  then run this again with --apply. Offsite stays off until then."
    exit 0
fi
echo "  logged in"
run install -d -m 0755 "$UNITS/valkey-backup.service.d"
run install -m 0644 -o root -g root "$B/config/systemd/valkey-backup.service.d/offsite.conf" "$UNITS/valkey-backup.service.d/offsite.conf"
run systemctl daemon-reload
(( APPLY )) || { echo "  (dry run: nothing changed; --apply to act)"; exit 0; }
[[ "$(systemctl show valkey-backup.service -p OnSuccess --value)" == *valkey-offsite-protondrive.service* ]] \
    || die "valkey-backup.service does not name the offsite push in OnSuccess after daemon-reload"
newest="$(ls -t "$B"/backups/valkey/dump_*.rdb 2>/dev/null | head -1)"
[[ -n "$newest" ]] || die "no local snapshot to push in $B/backups/valkey"
echo "  pushing $(basename "$newest") now (the nightly backup will do this from tonight)"
systemctl start valkey-offsite-protondrive.service || { journalctl -u valkey-offsite-protondrive.service -n 20 --no-pager; die "the offsite push failed"; }
journalctl -u valkey-offsite-protondrive.service -n 6 --no-pager -o cat | sed 's/^/    /'
"$PROTON_BIN" filesystem list "$REMOTE_ROOT" 2>/dev/null | grep -qF "$(basename "$newest")" \
    || die "$(basename "$newest") is not listed under $REMOTE_ROOT after the push"
echo "on $H: offsite live: $(basename "$newest") is on Proton Drive under $REMOTE_ROOT; every successful nightly backup now pushes its snapshot"
