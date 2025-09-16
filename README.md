# Log Archive Tool

A simple Bash tool to archive logs into timestamped `.tar.gz` files, prune old logs, and manage archive retention.  
Useful for keeping systems clean while still keeping historical logs.

## Features
- Archives logs older than **N days** into `.tar.gz`
- Skips already-compressed files (`.gz`, `.xz`, `.bz2`, `.zip`, `.tar`, `.tgz`, `.zst`)
- Prevents archiving its own output
- Atomic writes (`.partial` → final `.tar.gz`)
- Deletes old logs (optional)
- Deletes old archives after retention period
- Works in:
  - **Interactive menu mode**
  - **Non-interactive CLI mode** (good for cron/systemd)

---

## Usage

### Interactive Mode
Run without flags:
```bash
./log-archive.sh
```

Menu options let you:
1. Set log directory
2. Days to keep logs
3. Days to keep archives
4. Toggle delete originals
5. Run archive
6. Setup daily cron (2:00 AM)
7. Exit

Non-Interactive Mode:
```bash
./log-archive.sh --log-dir /var/log \
                 --days-logs 7 \
                 --days-backups 30 \
                 --delete-originals
```

Options:

--log-dir <dir>: Source log directory (required)
--dest <dir>: Destination (default: <logdir>-archives)
--days-logs <N>: Archive files older than N days (default 7)
--days-backups <N>: Delete archives older than N days (default 30)
--delete-originals: Delete logs after successful archive
--help: Show help
