#!/bin/bash
# Prove an archive restores, on the workstation that holds the private key, into a throwaway folder that is
# removed at the end. Nothing is restored over anything. Prints no secret.
#   sftp -P 23 <box user>@<box host>:<box dir>/sites_<stamp>.tar.zst.gpg .
#   bash restore-drill.sh sites_<stamp>.tar.zst.gpg
# Proves: it decrypts; the tar is whole; every expected part is there; each dump decompresses and ends complete;
# each SQLite store passes integrity_check; the RDB passes valkey-check-rdb if you have it; one database really
# imports if docker is available. Exit 0 only if everything it could check held, and it names what it could not.
set -uo pipefail
ARCHIVE="${1:?usage: restore-drill.sh <archive>}"; [[ -r "$ARCHIVE" ]] || { echo "cannot read $ARCHIVE" >&2; exit 2; }
for b in gpg zstd tar python3; do command -v "$b" >/dev/null || { echo "needs $b" >&2; exit 2; }; done
D="$(mktemp -d)"; chmod 0700 "$D"; trap 'rm -rf "${D:?}"' EXIT
pass=0; fail=0; skipped=()
ok() { pass=$((pass+1)); echo "  ok   $*"; }; bad() { fail=$((fail+1)); echo "  FAIL $*"; }; skip() { skipped+=("$*"); echo "  --   not proved: $*"; }

echo "== decrypt and unpack (in $D, removed afterwards)"
if gpg --batch --quiet --decrypt "$ARCHIVE" 2>"$D/gpg.err" | zstd -q -d | tar -C "$D" -xf - --same-permissions 2>"$D/tar.err"; then
    ok "decrypted and unpacked: $(du -sh --exclude=gpg.err --exclude=tar.err "$D" | cut -f1)"
else
    bad "decrypt or unpack failed"; sed -E 's/^/       /' "$D/gpg.err" "$D/tar.err" | cut -c1-160 | head -8
    echo "== $pass ok, $fail failed"; exit 1
fi

echo "== the parts of a node"
for p in var/www etc/apache2/sites-available etc/geodineum/credentials etc/letsencrypt etc/valkey/users.acl mysql valkey sqlite; do
    [[ -e "$D/$p" ]] && ok "$p" || bad "$p is missing"
done
n=$(find "$D/etc/geodineum/credentials" -maxdepth 1 -name '*.password' 2>/dev/null | wc -l)
(( n >= 1 )) && ok "$n credential files present (not printed)" || bad "no credential files"

echo "== databases"
smallest=""; size=""
for f in "$D"/mysql/*.sql.zst; do
    [[ -f "$f" ]] || { bad "no dumps at all"; break; }
    if zstd -q -t "$f" && [[ "$(zstd -q -dc "$f" | tail -1)" == *"Dump completed"* ]]; then
        ok "$(basename "$f"): complete"
        s=$(stat -c %s "$f"); [[ -z "$size" || "$s" -lt "$size" ]] && { size=$s; smallest=$f; }
    else bad "$(basename "$f"): truncated or corrupt"; fi
done
if command -v docker >/dev/null && [[ -n "$smallest" ]]; then
    c="restore-drill-$$"; pw="$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    if docker run -d --rm --name "$c" -e MARIADB_ROOT_PASSWORD="$pw" -e MARIADB_DATABASE=drill mariadb:11 >/dev/null 2>&1; then
        for _ in $(seq 120); do docker exec "$c" mariadb-admin -h127.0.0.1 -uroot -p"$pw" ping >/dev/null 2>&1 && break; sleep 1; done
        if zstd -q -dc "$smallest" | docker exec -i "$c" mariadb -h127.0.0.1 -uroot -p"$pw" drill 2>"$D/imp.err"; then
            t=$(docker exec "$c" mariadb -h127.0.0.1 -uroot -p"$pw" -N -e "select count(*) from information_schema.tables where table_schema='drill'")
            (( t >= 1 )) && ok "$(basename "$smallest") imported: $t tables" || bad "imported to 0 tables"
        else bad "import of $(basename "$smallest") failed: $(head -1 "$D/imp.err" | cut -c1-120)"; fi
        docker stop "$c" >/dev/null 2>&1
    else skip "a real import: docker could not start mariadb:11"; fi
else skip "a real import: no docker"; fi

echo "== SQLite"
found=0
while IFS= read -r -d '' db; do
    found=1; r=$(python3 -I -c 'import sqlite3,sys; print(sqlite3.connect(sys.argv[1]).execute("pragma integrity_check").fetchone()[0])' "$db" 2>&1)
    [[ "$r" == ok ]] && ok "${db#"$D"/}" || bad "${db#"$D"/}: $r"
done < <(find "$D/sqlite" -type f -print0 2>/dev/null)
(( found )) || skip "SQLite: this node has no stores in the archive"

echo "== ValKey"
rdb="$(ls "$D"/valkey/dump_*.rdb 2>/dev/null | head -1 || true)"
if [[ -z "$rdb" ]]; then bad "no RDB"
elif command -v valkey-check-rdb >/dev/null; then valkey-check-rdb "$rdb" >/dev/null 2>&1 && ok "$(basename "$rdb") passes valkey-check-rdb" || bad "$(basename "$rdb") fails valkey-check-rdb"
else head -c 5 "$rdb" | grep -aE '^(REDIS|VALKE)' >/dev/null && ok "$(basename "$rdb") has an RDB header" || bad "$(basename "$rdb") has no RDB header"; skip "the whole RDB: no valkey-check-rdb"; fi

echo "== $pass ok, $fail failed, ${#skipped[@]} not proved"
exit $(( fail > 0 ))
