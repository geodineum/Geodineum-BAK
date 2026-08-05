<p align="center">
  <a href="https://geodineum.com">
    <img src="https://geodineum.com/wp-content/uploads/2026/07/logo_geodineum_launch.png" alt="Geodineum" width="128">
  </a>
</p>

# Geodineum-BAK

Local ValKey snapshot rotation and centralized log rotation for a Geodineum
Constellation: a scheduled backup of the ValKey keyspace with integrity checks,
plus the logrotate policy for every component's logs.

Built by **Niels Erik Toren** · shell-based operational component (no build step)

---

## What it is

Geodineum-BAK is a single backup script driven by one systemd timer, plus the
ecosystem's logrotate configuration. On a schedule it takes a fresh RDB snapshot
of the ValKey instance gNode and COMMS share, verifies it, and rotates old
snapshots - nothing more.

It is deliberately narrow. Off-node durability is ValKey cluster replication's
job, not this component's: BAK exists to recover a single node from corruption (a
bad RDB, a ransomware event, a fat-fingered `DEL`), not from losing the node
itself. There is no remote push, and adding one would multiply the failure
surface without solving anything replication doesn't already solve at the right
layer.

## Public build surface

BAK is an operator component, not a library - there is nothing to build against.
The surface other components and operators rely on is:

- **The backup artifacts** - timestamped RDB snapshots and their `.meta`
  companions at the canonical backup path, written `0640` so a full-keyspace
  snapshot is never world-readable.
- **The systemd units** - the `valkey-backup` timer and oneshot service.
- **The `geodineum bak` CLI verbs** - `status` and `contract`.

The exact paths, file and metadata formats, schedule, and the ValKey ACL
commands the backup needs are specified in **[`CONTRACT.md`](CONTRACT.md)**.
Everything under `scripts/` is implementation and may change.

## Capabilities

- **Scheduled RDB snapshots** - a `BGSAVE`-fresh copy of the ValKey keyspace,
  taken daily with jitter and persisted across missed windows.
- **Integrity-checked rotation** - each snapshot is verified, and snapshots
  beyond the retention count are pruned.
- **Not world-readable** - snapshots and metadata are written `0640`.
- **Sandboxed execution** - the backup runs as a hardened systemd oneshot
  (read-only filesystem except the backup directory, no new privileges).
- **Centralized log rotation** - one logrotate policy covering every
  `/var/log/geodineum/` component.

## Contract

The precise operator surface - backup and metadata formats, canonical paths, the
schedule, retention, and the ValKey ACL commands required - is in
**[`CONTRACT.md`](CONTRACT.md)**. Agents should prime from
**[`CONTRACT.scn.md`](CONTRACT.scn.md)**. Print it on a host with `geodineum bak
contract`.

## Quick start

The Geodineum installer places this component and enables the timer. Verify it,
and take a manual snapshot:

```sh
systemctl status valkey-backup.timer     # the daily timer
systemctl list-timers valkey-backup.timer
geodineum bak status                      # timer state, last run, backup inventory

# On-demand backup (runs as the gnode ACL user, like the timer does)
sudo -u gnode /opt/geodineum/Geodineum-BAK/scripts/backup-valkey.sh --keep 30
```

## Limits worth knowing

- **Local-only - no off-node destination.** Cross-node durability is ValKey
  replication; rsync/borg/S3 push, if you need it, belongs at a layer above this
  component.
- **No point-in-time recovery.** Snapshots are periodic RDB copies; continuous
  durability is ValKey's `appendonly` (AOF), configured on ValKey, not here.
- **No backup encryption.** Encrypt the mount point (LUKS / fscrypt); BAK does
  not encrypt snapshots itself.
- **Retention differs by entry point.** The production timer keeps 30 snapshots;
  the script's own default when run bare is 7 - pass `--keep 30` to match the
  timer.

## Collaborate

Contributions are welcome. Open issues and pick up work on the ecosystem board
at [geodineum.com](https://geodineum.com); issues tagged `good-first-issue` are
a good place to start.

- Fork, branch, and open a pull request against `main`.
- Any change to a wire contract must update **both** `CONTRACT.md` and
  `CONTRACT.scn.md` in the same commit.
- A change to a signed extension must be re-signed in the same commit.

## Author & support

Built by **Niels Erik Toren**.

If you want to support the work:

| Currency | Address |
|---|---|
| Bitcoin (BTC) | `bc1qwf78fjgapt2gcts4mwf3gnfkclvqgtlg4gpu4d` |
| Ethereum (ETH) | `0xf38b517Dd2005d93E0BDc1e9807665074c5eC731` / `nierto.eth` |
| Monero (XMR) | `8BPaSoq1pEJH4LgbGNQ92kFJA3oi2frE4igHvdP9Lz2giwhFo2VnNvGT8XABYasjtoVY2Qb3LVHv6CP3qwcJ8UnyRtjWRZ5` |

## Disclaimer

This software is provided **"as is"**, without warranty of any kind, express or
implied. Use of this software is entirely at your own risk. In no event shall the
author or contributors be held liable for any damages arising from the use or
inability to use this software.

## License

Licensed under either of

* [Apache License, Version 2.0](LICENSE-APACHE)
* [MIT License](LICENSE-MIT)

at your option.
