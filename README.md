# GSD-BAK: Deployment & Operations Infrastructure

Deployment, backup, and log management infrastructure for the GSD (Geodineum Service Daemon) ecosystem.

## Directory Structure

```
GSD-BAK/
├── auto-deploy.sh              # Git-triggered auto-deployment
├── setup-log-rotation.sh       # Log rotation installer
├── config/
│   ├── gsd-bak.yaml           # Configuration settings
│   └── logrotate/
│       ├── gcore              # Logrotate config for gCore
│       └── gcore-wp           # Logrotate config for WordPress
├── logs/                       # Log archives (gitignored)
└── backups/
    └── valkey/                 # ValKey RDB snapshots (gitignored)
```

## Quick Start

```bash
# Install log rotation with backup and truncation
sudo ./setup-log-rotation.sh --truncate

# Install without backup
sudo ./setup-log-rotation.sh --truncate --no-backup

# Show help
./setup-log-rotation.sh --help
```

## Configuration

Edit `config/gsd-bak.yaml` to customize:

```yaml
log_truncation:
  threshold_bytes: 10485760    # 10MB for gCore logs
  backup_before_truncate: true
  archive_retention_days: 30

log_sources:
  wordpress:
    truncate_threshold_bytes: 5242880  # 5MB for WP logs
```

## Scripts

### `auto-deploy.sh`
Triggered by cron or git hooks to auto-deploy GSD changes:
- Pulls from git
- Builds the Rust daemon
- Reloads Lua functions
- Restarts the daemon service

### `setup-log-rotation.sh`
Installs and configures log rotation:
- Copies logrotate configs to `/etc/logrotate.d/`
- Optionally backs up large logs before truncation
- Cleans up old archives based on retention policy

## Integration with GSD

This repo is separate from the main GSD codebase to:
1. Keep deployment infrastructure isolated
2. Store logs and backups without polluting the main repo
3. Allow independent versioning of ops tooling

The main GSD service installer (`install-gsd-service.sh`) automatically integrates with GSD-BAK for log rotation.

## Environment

GSD-BAK expects these paths:
- **GSD Production**: `/opt/geodineum/GSD`
- **GSD-BAK**: `/opt/geodineum/GSD-BAK`
- **gCore Logs**: `/var/log/gcore/`
- **WP Logs**: `/var/www/*/wp-content/logs/`

## Log Rotation

Logs are rotated daily by the system logrotate service. Configuration:
- **Frequency**: Daily
- **Retention**: 7 days
- **Compression**: Enabled (delayed by 1 cycle)

## Backup Retention

- **Log Archives**: 30 days (configurable)
- **ValKey Backups**: 30 snapshots (configurable)

## License

Same as GSD - see the main repository for details.
