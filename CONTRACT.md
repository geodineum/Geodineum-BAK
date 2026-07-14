# Geodineum-BAK — Integration Contract

**Role:** Stateless, daemon-less backup orchestrator (Chapter-1 backup infrastructure). Runs a daily systemd timer that triggers a single bash script to take a ValKey RDB snapshot, verify it, write a `.meta` companion, and rotate old snapshots — plus ships ecosystem-wide logrotate and Nginx-deny config. Local-only: no remote replication, no off-node push. Off-node durability is delegated to ValKey replication.

> This file is the human-readable **integration contract** — what BAK provides, what it requires, the file/path/schedule tables, the credential/ACL expectation, and a copy-paste manual-run example. Code on disk is authoritative; this is a point-in-time compression. Companion: **[CONTRACT.scn.md](CONTRACT.scn.md)** (SCN primer).

---

## 1. PROVIDES (interfaces operators / other components may rely on)

| Interface | Kind | Signature / Key | Evidence |
|---|---|---|---|
| RDB snapshot backup mechanism | executable | `scripts/backup-valkey.sh --keep N --backup-dir DIR --data-dir DIR` — BGSAVE → wait → size-verified copy (≥100 B, `chmod 640`) → `.meta` (records an MD5 fingerprint) → rotate | backup-valkey.sh:1-389 (BGSAVE 227; wait 230-249; copy 265 + chmod 266 + size-verify 280-287 + md5 300; meta 290-308; rotate 356-374). Default `--keep`=7 (line 67); production timer overrides to 30 (valkey-backup.service:12) |
| Backup file format & location | output | `dump_YYYYMMDD_HHMMSS.rdb` + `dump_YYYYMMDD_HHMMSS.meta` under `/opt/geodineum/Geodineum-BAK/backups/valkey/`, both mode 640 | backup-valkey.sh:258 (BACKUP_FILE), 290 (METADATA_FILE); chmod 640 at 266 (RDB) + 308 (meta); dir from `--backup-dir`, service override valkey-backup.service:12. `.meta` carries timestamp/date/size/md5/auth_method/valkey_info(SERVER INFO)/database_info(KEYSPACE) per backup-valkey.sh:296-306 |
| ValKey backup systemd timer | service | `valkey-backup.timer` — `OnCalendar=*-*-* 02:00:00`, `RandomizedDelaySec=300`, `Persistent=true` | valkey-backup.timer:1-10. Daily 02:00 ±300s jitter; `Persistent=true` re-runs if missed. README.md:19,45 |
| ValKey backup systemd service | service | `valkey-backup.service` — `Type=oneshot`, `User=gnode`, `After/Wants=valkey-gnode.service`, `ProtectSystem=strict`, single `ReadWritePaths=/opt/geodineum/Geodineum-BAK/backups` | valkey-backup.service:1-31 (user/group 10-11; deps 3,6; sandbox 18-27; RW path 28; journal 30-31; ExecStart 12) |
| `bak status` CLI command | cli | `geodineum bak status` → text report: timer active/enabled + next elapse, last oneshot run result/exit/timestamp, backup dir inventory (count + size), latest backup + `.meta` presence, script availability | geodeploy.yaml:20-23; handler scripts/cli/bak-status.sh:1-67 (timer 17-28, last run 31-40, inventory 43-60, script 63-67). Systemd-only — no crontab involved |
| `bak contract` CLI command | cli | `geodineum bak contract` → prints this component's integration contract (`CONTRACT.md`) | geodeploy.yaml:16-19; handler scripts/cli/bak-contract.sh:1-17 (cats repo-root CONTRACT.md, exit 1 if missing) |
| Ecosystem logrotate config | config | `logrotate-geodineum.conf` → installed to `/etc/logrotate.d/geodineum`; manages all `/var/log/geodineum/*` | logrotate-geodineum.conf:1-171 (gNode copytruncate 16-32, retention 19=14d; WordPress dateext 95-105, 98=7d; Apache error 30d 133; postrotate gNode USR1 30, Apache reload 119-124; gShield daily×14 150-158; deploy weekly×8 163-171) |
| Web access denial rules | config | Apache `.htaccess` `Require all denied` (repo root + `scripts/`) — **primary deny on deployed Apache hosts**; plus `nginx-deny.conf` (repo root) → `location ~ /Geodineum-BAK { deny all; return 404; }` and `scripts/nginx-deny.conf` → scoped `location ~ /Geodineum-BAK/scripts` | .htaccess:1-8; scripts/.htaccess:1-8; nginx-deny.conf:1-5; scripts/nginx-deny.conf:1-5. Blocks HTTP retrieval of backup paths |
| Per-service backup introspection hints | logging | scans `geodeploy.yaml` `.backup.{keys,files,exclude,schedule}` and logs counts (informational only) | backup-valkey.sh:317-353 (`log_per_service_hints()`); scans `/opt/geodineum/*/geodeploy.yaml` + `/opt/geodineum/*/services/*/geodeploy.yaml` (327); RDB is wholesale regardless (line 350) |

---

## 2. CONSUMES / REQUIRES (what BAK needs, and from whom)

| Need | From component | Expected format | Evidence |
|---|---|---|---|
| ValKey connection | ValKey cluster (`valkey-gnode.service`) | `valkey-cli` with ACL creds, **user=`gnode_daemon`**, password fed via **stdin** (never argv/env). `VALKEY_HOST` default `127.0.0.1`, `VALKEY_PORT` default `47445` | backup-valkey.sh:31-63 (cred chain: `$GEODINEUM_CREDENTIALS_DIR/valkey_daemon.password` 44, user 45; fallback `valkey.password` 49; fatal if none 57-62), 151 (host/port), 165-181 (stdin-AUTH wrapper). Requires ACL grants: BGSAVE (227), LASTSAVE (224,236), CONFIG GET (186), INFO (293-294) |
| RDB file read access | ValKey data directory | `dump.rdb` at `CONFIG GET dir` or `--data-dir`; path must canonicalize under `/var/lib/valkey*` | backup-valkey.sh:184-219 (discover 186, flag 88, whitelist gate 209-217, `{dir}/dump.rdb` 219, existence 252, copy 265). Runs as `gnode:gnode` (valkey-backup.service:10) which must read the RDB |
| `geodeploy.yaml` manifest schema | Geodineum installer (`geodeploy.sh`, `geodineum` CLI loader) | YAML: `runtime.group`, `triggers[]`, `dirty-tree.strategy`, `cli.commands[]{name,handler,description,category}` | geodeploy.yaml:1-23 (group=gnode 5, triggers 8-9, stash 12, cli 14-23). Verified vs CLI discovery `Geodineum/geodineum:77-123` (`discover_manifest_commands` scans `*/geodeploy.yaml` + `*/services/*/geodeploy.yaml` 91, `yq @tsv` 120; dispatch 124-145) |
| Paths & directory permissions | Geodineum installer + system | `gnode:gnode` for scripts; `/opt/geodineum/Geodineum-BAK/` readable, `…/backups/` writable | valkey-backup.service:10-11,28. Script `cp`s RDB (backup-valkey.sh:265), chmods 640 (266), chowns to gnode if run as root (271) |
| Systemd unit framework | systemd (installed by Geodineum installer to `/etc/systemd/system/`) | timer `OnCalendar`/`WantedBy=timers.target`; service `Type=oneshot` | valkey-backup.timer:5,10, valkey-backup.service:9. README.md:19-21 (`systemctl status/list-timers/start`) |
| `bootstrap-loader.sh` ecosystem config | Geodineum installer (bootstrap layer) | `GEODINEUM_LIB` (default `/usr/local/lib/geodineum`) with `bootstrap-loader.sh` exporting `load_ecosystem_config` | backup-valkey.sh:22-29. Populates `VALKEY_HOST`, `VALKEY_PORT`, `GNODE_USER`, `GNODE_GROUP`; fatal if missing (23-26) |

---

## 3. Formats · paths · schedules · ValKey keys

### 3.1 Wire / file formats

| Artifact | Format | Evidence |
|---|---|---|
| Snapshot | RDB binary (ValKey `dump.rdb`), copied raw/unchanged with `cp(1)`, then `chmod 640` | backup-valkey.sh:265-266 |
| Metadata | `dump_*.meta` plain text (mode 640) — timestamp, size, MD5, auth_method, valkey_info (SERVER lines), database_info (KEYSPACE lines) | backup-valkey.sh:296-306, chmod 308 |
| systemd units | `systemd.unit(5)` declarative — timer (`OnCalendar`/`RandomizedDelaySec`/`Persistent`); service (`Type`/`User`/`Group`/`ExecStart`/sandbox) | valkey-backup.timer, valkey-backup.service |
| Logrotate | `/etc/logrotate.d/` directive syntax per `logrotate(8)` (daily, rotate N, compress, postrotate) | logrotate-geodineum.conf |
| CLI manifest | YAML `.cli.commands[]`; parsed to TSV `name⇥handler⇥description⇥args⇥requires_sudo⇥category⇥fallback` by `yq @tsv` | geodineum:120 |
| Apache deny | `.htaccess` `Require all denied` (`mod_authz_core`, with `Order deny,allow` fallback) — repo root + `scripts/`; primary on Apache hosts | .htaccess:1-8, scripts/.htaccess:1-8 |
| Nginx | `location` block `deny all; return 404;` per `nginx.conf(5)` | nginx-deny.conf:1-5, scripts/nginx-deny.conf:1-5 |

### 3.2 Paths

| Path | Role |
|---|---|
| `/opt/geodineum/Geodineum-BAK/scripts/backup-valkey.sh` | core executable (deployed) |
| `/opt/geodineum/Geodineum-BAK/scripts/cli/bak-status.sh` | `bak status` handler |
| `/opt/geodineum/Geodineum-BAK/scripts/cli/bak-contract.sh` | `bak contract` handler |
| `/opt/geodineum/Geodineum-BAK/backups/valkey/` | snapshot + `.meta` destination (writable) |
| `/var/lib/valkey*/dump.rdb` | RDB source (whitelist-gated, read-only) |
| `/etc/geodineum/credentials/valkey_daemon.password` | primary credential (fallback `valkey.password`) |
| `/etc/logrotate.d/geodineum` | installed logrotate config |
| `/var/log/geodineum/*` | logs managed by logrotate config |
| `/usr/local/lib/geodineum/bootstrap-loader.sh` | ecosystem config loader (`GEODINEUM_LIB`) |

### 3.3 Schedule

| When | What | Evidence |
|---|---|---|
| Daily `02:00` ±300s jitter, `Persistent` (catch-up if missed) | timer pulls `valkey-backup.service` | valkey-backup.timer:1-10 |
| BGSAVE timeout = 60s | if BGSAVE exceeds, script proceeds with current RDB and warns | backup-valkey.sh:230, 248 (`log_warn`) |
| Retention | `--keep`=7 script default / 30 production (service override) | backup-valkey.sh:67, valkey-backup.service:12 |

### 3.4 ValKey commands required of `gnode_daemon` ACL user

`BGSAVE` (backup-valkey.sh:227) · `LASTSAVE` (224,236) · `CONFIG GET` (186) · `INFO` (293-294). No pre-flight check — missing grants fail at runtime.

---

## 4. Public types / surfaces

```text
Snapshot output    RDB binary file (ValKey serialization) + companion .meta (text metadata)
CLI                geodineum bak status  → text status report · geodineum bak contract → prints CONTRACT.md
Systemd units      valkey-backup.timer (scheduling) · valkey-backup.service (oneshot execution)
Config artifacts   logrotate-geodineum.conf (→ /etc/logrotate.d/) · nginx-deny.conf (→ vhost)
Manifest           geodeploy.yaml (YAML service declaration per Geodineum schema)
```

---

## 5. Copy-paste: manual backup + restore note

```bash
# Manual on-demand backup (matches the production cadence, keeps 30):
sudo systemctl start valkey-backup.service

# …or invoke the script directly. NOTE: bare invocation keeps only 7 (script default).
# Pass --keep 30 to match the production timer.
sudo -u gnode /opt/geodineum/Geodineum-BAK/scripts/backup-valkey.sh --keep 30 \
     --backup-dir /opt/geodineum/Geodineum-BAK/backups/valkey

# Inspect timer + last run:
geodineum bak status
systemctl status valkey-backup.timer
systemctl list-timers valkey-backup.timer

# Latest snapshot + its metadata:
ls -t /opt/geodineum/Geodineum-BAK/backups/valkey/dump_*.rdb | head -1
```

**Restore note:** snapshots are **wholesale RDB** — there is no selective restore. Recovery is: stop ValKey, place the chosen `dump_*.rdb` as the data-dir `dump.rdb`, restart ValKey. For individual keys, an operator must load the backup into a scratch instance and `RESTORE` keys manually. BAK does **not** test-restore; the only gating integrity check is the size floor (≥100 bytes) — an MD5 is recorded into the `.meta` sidecar as a fingerprint, not compared against the source.

---

## 6. Cross-deps (who else is in the loop)

- **ValKey (`valkey-gnode.service`)** — BGSAVE / LASTSAVE / CONFIG GET / INFO via ACL user `gnode_daemon`.
- **Geodineum installer (`install.sh`)** — copies scripts to `/opt/geodineum/Geodineum-BAK/`, installs systemd units to `/etc/systemd/system/`, creates `/etc/geodineum/credentials/`, establishes the `gnode` user:group.
- **`geodeploy.yaml` manifest schema** — shared with `geodeploy.sh` and the `geodineum` CLI dispatcher for command registration + manifest discovery.
- **logrotate ecosystem** — `logrotate-geodineum.conf` in `/etc/logrotate.d/` manages all `/var/log/geodineum/*` (not BAK-exclusive; BAK is one provider of the unified config).
- **Nginx hardening** — `nginx-deny.conf` blocks HTTP access to backup paths.
- **systemd** — `valkey-backup.timer` triggers the run; also manual via `systemctl start valkey-backup.service` or direct script (the `geodineum bak` verbs are read-only: status/contract).
- **`/usr/local/lib/geodineum/bootstrap-loader.sh`** (`GEODINEUM_LIB`) — ecosystem config loading.

---

## 7. Durability model (what BAK is NOT)

Intentionally **local-only** (README.md:152-154). No S3 / rsync / borg / second-datacenter target, no remote credentials, no network retry logic. Off-node durability is **ValKey replication's** responsibility (README.md:6-10); BAK covers single-node point-in-time recovery only (bad RDB, ransomware, fat-finger `DEL`, pre-deploy rollback). No encryption (filesystem-level LUKS/fscrypt is operator's job). No point-in-time recovery beyond the snapshot moment (operator must enable ValKey AOF separately).

---

## 8. Adherence (manifest conformance + observations)

Verified-aligned:
- **`geodeploy.yaml` manifest** conforms to schema: `runtime.group=gnode` (5); `triggers[]` chmod-scripts action (8-9); `dirty-tree.strategy=stash` (12); `cli.commands[]` well-formed (name/handler/description/category, 14-23).
- **CLI registration** — `bak contract` declared geodeploy.yaml:16-19, `bak status` geodeploy.yaml:20-23; both handlers in `scripts/cli/` are executable (0750); `geodineum` CLI parses via `yq @tsv` (line 120) into `CMD_HANDLER/CMD_ROOT/CMD_DESC/CMD_CAT`, two-word match (129-135), routes to `_exec_handler` (147) which exports `GEODINEUM_ROOT` (164). ✓
- **Credential security** — password fed via **stdin** to valkey-cli, never argv/env (backup-valkey.sh:153-164 comment, 165-181), preventing process-listing and xtrace leaks; matches CredentialResolver pattern (README.md:69-77). ✓
- **Data-dir whitelist** — strict allowlist gate (backup-valkey.sh:209-217) rejects any `CONFIG GET dir` outside `/var/lib/valkey*`, defeating symlink/path-traversal even if `gnode_daemon` ACL is overprivileged. ✓
- **Lock discipline** — `flock -n` on `.backup-valkey.lock` (144-145); contention → graceful exit 0 (147), no queue, no race between manual + timer runs.
- **Systemd sandbox** — `ProtectSystem=strict` (20) makes the FS read-only except the single `ReadWritePaths`; layered with NoNewPrivileges, PrivateTmp, ProtectHome, RestrictSUIDSGID, LockPersonality (18-27). Script cannot write anywhere unexpected.
- **Logging model** — backup output goes to the journal (`StandardOutput=journal`, valkey-backup.service:30); BAK provides the ecosystem logrotate config but does not manage its own backup logs under `/var/log/`. Aligns with centralized logging.
- **Timestamp stability** — filename `date +%Y%m%d_%H%M%S` (backup-valkey.sh:68); rotation glob `dump_*.rdb` (358) assumes this pattern; stable across runs/deployments.

Operator-relevant risks (design, not divergence):
- ⚠️ **`--keep` divergence** — script default 7 (backup-valkey.sh:67) vs production timer 30 (valkey-backup.service:12). Bare direct invocation keeps only 7. README.md:188 acknowledges this as intentional (manual defaults vs production override); **runbook accuracy is the operator's responsibility.**
- ⚠️ **ACL brittleness** — no pre-flight permission check; if `gnode_daemon` lacks BGSAVE/LASTSAVE/CONFIG GET/INFO, the script fails at runtime.
- ⚠️ **BGSAVE 60s timeout** (backup-valkey.sh:230) — on slow disks / high memory the script proceeds with the current (possibly stale) RDB and only warns (248).
- ⚠️ **Whitelist strictness** — if ValKey data was relocated outside `/var/lib/valkey*`, operator must pass `--data-dir` explicitly or edit the gate.
- ⚠️ **No integrity test-restore** — size + MD5 only; silent RDB corruption is possible (rare).
- ⚠️ **Per-service `.backup.*` hints are introspective only** — logged counts, NOT selective backup; the RDB always includes all data (backup-valkey.sh:350 comment).
- ⚠️ **Timer depends on systemd** — if the timer is disabled/uninstalled there are no automatic backups; manual invocation is the only fallback.
