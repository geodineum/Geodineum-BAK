# Geodineum-BAK :: CONTRACT primer (SCN)
> one-line: SCN primer — TRUTH = code on disk, this file is a point-in-time compression. Companion: CONTRACT.md (authoritative).

## ::ROLE
Geodineum-BAK = Chapter-1 backup infrastructure. Stateless, **daemon-less** single-purpose orchestrator: daily systemd timer → oneshot service → one bash script that BGSAVEs ValKey, size-verifies an RDB copy (≥100 B) and fingerprints it with MD5 into `.meta`, writes `.meta`, rotates N. Also ships ecosystem `logrotate` config + Nginx `deny` config. **Local-only**: ∀ off-node durability ∈ ValKey replication; BAK owns single-node point-in-time snapshots only. No remote push, no encryption, no PiTR, no daemon, no plugin layer.

## ::ANCHOR
- Core exec: `scripts/backup-valkey.sh` (backup-valkey.sh:1-389). BGSAVE 227 · LASTSAVE poll 224,230-249 · copy 265 + `chmod 640` 266 + size-verify 280-287 + md5 300 · `.meta` gen 290-308 · rotate 356-374 · flock `-n` `.backup-valkey.lock` 144-145 (contention→exit 0, 147) · whitelist gate 209-217 · cred chain 31-63 · stdin-AUTH wrapper 165-181 · timestamp `+%Y%m%d_%H%M%S` 68.
- Output: `dump_YYYYMMDD_HHMMSS.rdb` + `.meta` → `/opt/geodineum/Geodineum-BAK/backups/valkey/`, both mode **640** (chmod 266 RDB, 308 meta) — full-keyspace snapshot never world-readable. BACKUP_FILE 258, METADATA_FILE 290. `.meta` = timestamp/date/size/md5/auth_method/valkey_info(SERVER INFO)/database_info(KEYSPACE) 296-306.
- Source: `{CONFIG GET dir | --data-dir}/dump.rdb`, MUST canonicalize ⊂ `/var/lib/valkey*` (gate 209-217, path 219).
- Timer: `valkey-backup.timer` `OnCalendar=*-*-* 02:00:00` + `RandomizedDelaySec=300` + `Persistent=true` + `WantedBy=timers.target` (timer:1-10, README.md:19,45).
- Service: `valkey-backup.service` `Type=oneshot` User/Group=`gnode` (10-11) · `After/Wants=valkey-gnode.service` (3,6) · sandbox NoNewPrivileges/PrivateTmp/ProtectSystem=strict/ProtectHome/ProtectKernel*/RestrictRealtime/LockPersonality/RestrictSUIDSGID (18-27) · single `ReadWritePaths=/opt/geodineum/Geodineum-BAK/backups` (28) · journal (30-31) · ExecStart `…/backup-valkey.sh --keep 30 --backup-dir …/backups/valkey` (12).
- CLI: `geodineum bak status` (geodeploy.yaml:20-23) → handler `scripts/cli/bak-status.sh:1-67` (timer active/enabled+next elapse 17-28, last oneshot run result/exit/ts 31-40, inventory count+size+latest+`.meta` 43-60, script avail 63-67) — **systemd-only, no crontab**. `geodineum bak contract` (geodeploy.yaml:16-19) → handler `scripts/cli/bak-contract.sh:1-17` (cats repo-root CONTRACT.md, exit 1 if missing).
- Logrotate: `config/logrotate/logrotate-geodineum.conf:1-171` → `/etc/logrotate.d/geodineum`; gNode copytruncate 16-32 retain 14d (19) postrotate USR1 (30) · WordPress dateext 95-105 retain 7d (98) · Apache error 30d (133) graceful reload 119-124 · gShield daily×14 (150-158) · deploy weekly×8 (163-171).
- Web-deny: Apache `.htaccess:1-8` (repo root) + `scripts/.htaccess:1-8` `Require all denied` (mod_authz_core, `Order deny,allow` fallback) — **primary on Apache hosts** · Nginx `nginx-deny.conf:1-5` (repo root) `location ~ /Geodineum-BAK { deny all; return 404; }` · `scripts/nginx-deny.conf:1-5` scoped `location ~ /Geodineum-BAK/scripts`.
- Per-svc hints: `log_per_service_hints()` 317-353 scans `/opt/geodineum/*/geodeploy.yaml` + `…/services/*/geodeploy.yaml` `.backup.{keys,files,exclude,schedule}` (327) — counts only, RDB wholesale (350 comment).
- Creds: `$GEODINEUM_CREDENTIALS_DIR=/etc/geodineum/credentials` (32) → `valkey_daemon.password` user=`gnode_daemon` (44-45) | fallback `valkey.password` (49) | fatal-none (57-62). Host 127.0.0.1 / Port 47445 (151).
- Bootstrap: `GEODINEUM_LIB=/usr/local/lib/geodineum/bootstrap-loader.sh` → `load_ecosystem_config` (22-29) → VALKEY_HOST/PORT, GNODE_USER/GROUP.

## ::ARCHITECTURE
No long-running process. Flow: systemd timer (02:00 ±300s, Persistent catch-up) → pulls oneshot service (User=gnode, ProtectSystem=strict, single RW path) → `backup-valkey.sh`:
resolve cred (centralized→standard→legacy fallback, fatal else) → discover data dir (`CONFIG GET dir` | `--data-dir`) → whitelist gate `/var/lib/valkey*` → BGSAVE + poll LASTSAVE until done|60s-timeout(proceed+warn 248) → `cp` RDB + `chmod 640` (≥100B check) + MD5 → write `.meta` (info+keyspace, chmod 640) → rotate keep-N via `ls -t`+`tail` → optional best-effort per-service hint logging.
Concurrency: `flock -n` → manual+timer never race; contention = graceful skip exit 0, no queue. Observability: `bak status` CLI + journal + `.meta` audit trail.
Philosophy: simple/verifiable/single-purpose · contract-first (23-line manifest, declared-not-inferred CLI) · fail-safe defaults (cred fatal-if-none, whitelist gate, size≥100B verify, lock graceful, sandbox strict) · credential stdin-only (no argv/env leak) · code-wins (contract drifts→behavior authoritative) · no-remote-complexity (bounded surface) · centralized logging (journal, not component-local log files) · composability (logrotate ecosystem-wide, nginx into site hardening, manifest → shared registry).

## ::IO
IN ← ValKey via valkey-cli ACL user `gnode_daemon` (stdin-AUTH): BGSAVE(227)·LASTSAVE(224,236)·CONFIG GET(186)·INFO(293-294). ← RDB `{dir}/dump.rdb` read (gnode:gnode, ⊂/var/lib/valkey*). ← `geodeploy.yaml` manifest schema. ← `bootstrap-loader.sh` ecosystem config. ← scans `/opt/geodineum/*/geodeploy.yaml` `.backup.*` (hints).
OUT → `dump_*.rdb` (raw binary, `cp` unchanged 265, `chmod 640` 266) + `dump_*.meta` (text, 640) @ `/opt/geodineum/Geodineum-BAK/backups/valkey/`. → journal (StandardOutput=journal). → `bak status` text report · `bak contract` prints CONTRACT.md. → installs `/etc/logrotate.d/geodineum` (manages `/var/log/geodineum/*`) + nginx deny blocks.

## ::CONTRACT
PROVIDES → RDB snapshot mechanism `backup-valkey.sh --keep N --backup-dir DIR --data-dir DIR` | `dump_*.rdb`+`.meta` format/location (mode 640) | timer `02:00 ±300s Persistent` | oneshot service `gnode`/strict-sandbox | `geodineum bak status` + `geodineum bak contract` | ecosystem logrotate `/etc/logrotate.d/geodineum` | nginx `/Geodineum-BAK`→404 deny (+ `/Geodineum-BAK/scripts` scoped) | per-service `.backup.*` introspection hints (informational).
CONSUMES ← ValKey (`valkey-gnode.service`) BGSAVE/LASTSAVE/CONFIG GET/INFO via `gnode_daemon` ACL | RDB read `/var/lib/valkey*/dump.rdb` | `geodeploy.yaml` schema (runtime.group, triggers[], dirty-tree.strategy, cli.commands[]) | systemd (timer.target, oneshot) | `gnode:gnode` perms + writable `…/backups` | `bootstrap-loader.sh` (`GEODINEUM_LIB`).

## ::USECASES
- Daily automated RDB snapshot, keep 30 (production) — local corruption recovery (ransomware, fat-finger DEL).
- Manual on-demand: `systemctl start valkey-backup.service` | direct `backup-valkey.sh` (NB: bare run keeps 7).
- `geodineum bak status` → timer active/next-elapse, last oneshot result/exit/ts, inventory count+size, latest+`.meta`, script avail — for ops dashboard.
- `geodineum bak contract` → print this integration contract (CONTRACT.md) at the terminal.
- `.meta` audit trail: timestamp/MD5/ValKey version/keyspace sizes for verification + correlation.
- Centralized logrotate: `logrotate-geodineum.conf` manages all `/var/log/geodineum/*` (BAK = one provider, not exclusive).
- Per-service `.backup.*` introspection: log counts (keys/files/excludes/schedule) — ops awareness, NOT selective targeting.
- Nginx hardening: `nginx-deny.conf` blocks HTTP retrieval of backup paths.
- Pre-deploy snapshot → rollback RDB if deploy breaks.
- Single-node constellation recovery: BAK = local snapshot; ValKey replication = cross-node durability.

## ::LIMITATIONS
- Local-only: no S3/rsync/borg/DC-2; cross-node durability ⇒ ValKey replication.
- No encryption (plaintext on disk; LUKS/fscrypt = operator).
- No PiTR (snapshot-at-N; continuous window ⇒ enable ValKey AOF separately).
- No selective restore (wholesale RDB; per-key ⇒ scratch instance + manual RESTORE).
- BGSAVE timeout 60s (230); over → proceed w/ current RDB + warn (248) → possible stale snapshot.
- ACL brittleness: needs gnode_daemon BGSAVE/LASTSAVE/CONFIG GET/INFO; **no pre-flight check** → runtime fail if missing.
- Whitelist strictness: data dir must ⊂ `/var/lib/valkey*`; relocated dir ⇒ pass `--data-dir` or edit gate.
- `--keep` divergence: script default 7 (67) vs service 30 (12); bare direct run keeps only 7; README.md:188 = operator runbook ownership.
- Per-service `.backup.*` hints logging-only, not selective.
- No integrity test-restore: size + MD5 only; silent corruption possible.
- Timer depends on systemd: disabled/uninstalled ⇒ no auto backups, manual fallback only.

## ::GRAPH
DEPENDS_ON: ValKey `valkey-gnode.service` (BGSAVE/LASTSAVE/CONFIG GET/INFO via gnode_daemon ACL) · Geodineum installer (deploy scripts, install units, `/etc/geodineum/credentials/`, gnode user:group) · systemd (timer+oneshot) · `/usr/local/lib/geodineum/bootstrap-loader.sh`.
PROVIDES_TO: operators (`geodineum bak status`/`bak contract`, snapshots, restore source) · ecosystem logs (`/etc/logrotate.d/geodineum` → all `/var/log/geodineum/*`) · Nginx site hardening (deny blocks) · Geodineum CLI dispatcher (manifest `bak status` + `bak contract`).
ADHERES_TO: `geodeploy.yaml` manifest schema ↔ geodeploy.sh + `geodineum` CLI (geodineum:77-123 `discover_manifest_commands`, yq @tsv 120, dispatch 124-145; ✓ runtime.group/triggers/dirty-tree/cli.commands well-formed) · CredentialResolver stdin-only protocol ↔ ecosystem (✓ no argv/env leak, backup-valkey.sh:165-181) · systemd.unit(5) · logrotate(8) · nginx.conf(5).
ISOLATED_FROM: remote durability layer (no S3/network — ValKey replication owns it) · selective/per-key backup (wholesale RDB) · its own `/var/log/` (delegates to journal) · backup encryption (operator FS-level).
RISK: `--keep` 7-vs-30 divergence ⚠ · ACL no pre-flight ⚠ · BGSAVE 60s→stale ⚠ · whitelist gate strict ⚠ · no test-restore→silent corruption ⚠ · per-svc hints non-selective ⚠ · timer⇒systemd hard-dep ⚠.

## ::LATENT
- "stateless daemon-less backup orchestrator — timer → oneshot → bash script, nothing long-running"
- "BGSAVE → poll LASTSAVE(60s) → cp RDB + chmod 640 + ≥100B size-verify (only gate) + MD5 fingerprint into .meta → .meta(640) → rotate keep-N via ls -t|tail"
- "bak status = systemd-truth: timer state + oneshot Result/ExecMainStatus via systemctl show — cron never involved"
- "local-only: off-node durability ∈ ValKey replication; no S3/rsync/encryption/PiTR/selective-restore"
- "credential stdin-only to valkey-cli, gnode_daemon ACL, never argv/env — no process-listing/xtrace leak"
- "data-dir whitelist gate ⊂ /var/lib/valkey* defeats path-traversal even if ACL overprivileged"
- "--keep divergence: script default 7 vs production timer 30 — operator owns runbook"
- "ProtectSystem=strict single ReadWritePaths=…/backups — sandbox blocks unexpected writes"
- "logrotate-geodineum.conf ecosystem-wide /var/log/geodineum/*; BAK logs to journal not its own file"
