#!/usr/bin/env bash
# Hybrid Log Archive Tool
# - Interactive menu OR non-interactive flags
# - Archives files older than N days into timestamped .tar.gz
# - Safe: atomic writes, skip compressed files, avoid self-archiving, delete only after success
# - Defaults destination to <logdir>-archives (outside source)
#
# Non-interactive usage:
#   ./log-archive.sh --log-dir /var/log --days-logs 7 --days-backups 30 [--dest /backups/logs] [--delete-originals]
#   ./log-archive.sh --help
#
# Interactive usage:
#   ./log-archive.sh     # presents a menu

set -euo pipefail
IFS=$'\n\t'

# ---------- Utilities ----------
say() { printf '%s\n' "$*"; }
err() { printf 'ERROR: %s\n' "$*" >&2; }
iso_now() { date -Is; }

have_cmd() { command -v "$1" >/dev/null 2>&1; }

abs_path() {
  if have_cmd realpath; then realpath -m "$1"
  elif have_cmd python3; then python3 - <<'PY' "$1"
import os,sys; print(os.path.abspath(sys.argv[1]))
PY
  else
    # naive fallback
    case "$1" in
      /*) printf '%s\n' "$1" ;;
      *)  printf '%s\n' "$(pwd)/$1" ;;
    esac
  fi
}

file_size_bytes() {
  local f=$1
  if have_cmd stat; then
    # GNU stat: -c%s ; BSD/Darwin: -f%z
    stat -c%s "$f" 2>/dev/null || stat -f%z "$f" 2>/dev/null || echo "unknown"
  else
    echo "unknown"
  fi
}

# ---------- Core archiving (safe) ----------
archive_logs() {
  # Args:
  #   $1: log_dir
  #   $2: days_to_keep_logs (int)
  #   $3: dest_dir (archives dir; default <logdir>-archives)
  #   $4: days_to_keep_backups (int)
  #   $5: delete_originals ("true"/"false")
  local log_dir="$1"
  local keep_days="$2"
  local dest_dir="${3:-}"
  local keep_arch_days="$4"
  local delete_originals="${5:-false}"

  if [[ ! -d "$log_dir" ]]; then
    err "Log directory does not exist: $log_dir"
    return 1
  fi

  # Default destination outside the source
  if [[ -z "$dest_dir" ]]; then
    dest_dir="${log_dir%/}-archives"
  fi

  # Absolute, normalized paths
  local LOG_DIR_ABS DEST_DIR_ABS
  LOG_DIR_ABS="$(abs_path "$log_dir")"
  DEST_DIR_ABS="$(abs_path "$dest_dir")"

  # Refuse if destination is inside the log dir (recursion risk)
  case "$DEST_DIR_ABS" in
    "$LOG_DIR_ABS"|"$LOG_DIR_ABS"/*)
      err "Destination must not be inside the log directory."
      err "LOG_DIR = $LOG_DIR_ABS"
      err "DEST_DIR = $DEST_DIR_ABS"
      return 1
      ;;
  esac

  mkdir -p "$DEST_DIR_ABS"
  local run_log="$DEST_DIR_ABS/archive.log"
  local timestamp
  timestamp="$(date +%Y%m%d_%H%M%S)"
  local archive_name="logs_archive_${timestamp}.tar.gz"
  local archive_path="${DEST_DIR_ABS}/${archive_name}"
  local tmp_archive="${archive_path}.partial"

  # Build list of candidate files:
  # - Prune any directory that matches the destination basename if it exists under the source (defense-in-depth)
  # - Only files older than N days
  # - Skip already-compressed/archived formats
  local dest_base
  dest_base="$(basename "$DEST_DIR_ABS")"

  local file_list
  file_list="$(mktemp)"
  # shellcheck disable=SC2016
  find "$LOG_DIR_ABS" \
    -type d -name "$dest_base" -prune -o \
    -type f -mtime +"$keep_days" \
    ! -name '*.gz' ! -name '*.xz' ! -name '*.bz2' ! -name '*.zip' ! -name '*.zst' \
    ! -name '*.tar' ! -name '*.tgz' \
    -print0 > "$file_list"

  if [[ ! -s "$file_list" ]]; then
    say "No files older than ${keep_days} days found in $LOG_DIR_ABS. Nothing to archive."
    rm -f "$file_list"
    # Still prune old archives
    if [[ -n "${keep_arch_days}" ]]; then
      find "$DEST_DIR_ABS" -type f -name '*.tar.gz' -mtime +"$keep_arch_days" -delete || true
    fi
    return 0
  fi

  say "Creating archive: $archive_path"
  # Create archive atomically from list
  tar -czf "$tmp_archive" --null -T "$file_list"
  mv "$tmp_archive" "$archive_path"

  # Log the run
  local size_bytes
  size_bytes="$(file_size_bytes "$archive_path")"
  printf '[%s] source="%s" archive="%s" size_bytes=%s delete_originals=%s keep_days=%s keep_arch_days=%s\n' \
    "$(iso_now)" "$LOG_DIR_ABS" "$archive_path" "$size_bytes" "$delete_originals" "$keep_days" "$keep_arch_days" \
    >> "$run_log"

  # Delete only files we archived, if requested
  if [[ "$delete_originals" == "true" ]]; then
    xargs -0 rm -f < "$file_list"
    say "Deleted original uncompressed files that were archived."
  fi

  rm -f "$file_list"

  # Retention for archives
  if [[ -n "${keep_arch_days}" ]]; then
    find "$DEST_DIR_ABS" -type f -name '*.tar.gz' -mtime +"$keep_arch_days" -delete || true
  fi

  say "Done."
  say "Archive: $archive_path"
  say "Run log: $run_log"
}

# ---------- CLI parsing (non-interactive mode) ----------
print_help() {
  cat <<'EOF'
Hybrid Log Archive Tool

Usage (non-interactive):
  log-archive.sh --log-dir <dir> [--dest <archive-dir>]
                 [--days-logs <N>] [--days-backups <N>]
                 [--delete-originals]

Options:
  --log-dir <dir>        Source log directory (e.g., /var/log)  [required]
  --dest <dir>           Destination for .tar.gz (default: <logdir>-archives)
  --days-logs <N>        Archive files older than N days (default: 7)
  --days-backups <N>     Delete archive .tar.gz older than N days (default: 30)
  --delete-originals     Delete the archived originals after success
  --help                 Show this help

Interactive mode:
  Run without flags to use the menu-driven flow.

Notes:
  - Skips already-compressed files (*.gz, *.xz, *.bz2, *.zip, *.zst, *.tar, *.tgz).
  - Writes run records to <dest>/archive.log with ISO timestamps.
  - Uses atomic write (.partial -> final) to avoid corrupt archives.
EOF
}

if [[ "${1:-}" == "--help" ]]; then
  print_help
  exit 0
fi

# Detect if any known flags are present; if yes, run non-interactively.
if [[ $# -gt 0 ]]; then
  LOG_DIR=""
  DEST_DIR=""
  DAYS_LOGS=7
  DAYS_BACKUPS=30
  DELETE_ORIG="false"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --log-dir)       LOG_DIR="$2"; shift 2 ;;
      --dest)          DEST_DIR="$2"; shift 2 ;;
      --days-logs)     DAYS_LOGS="$2"; shift 2 ;;
      --days-backups)  DAYS_BACKUPS="$2"; shift 2 ;;
      --delete-originals) DELETE_ORIG="true"; shift ;;
      --help)          print_help; exit 0 ;;
      *) err "Unknown option: $1"; print_help; exit 1 ;;
    esac
  done

  if [[ -z "$LOG_DIR" ]]; then
    err "--log-dir is required in non-interactive mode."
    exit 1
  fi

  archive_logs "$LOG_DIR" "$DAYS_LOGS" "${DEST_DIR:-}" "$DAYS_BACKUPS" "$DELETE_ORIG"
  exit $?
fi

# ---------- Interactive mode ----------
prompt_for_input() {
  local prompt="$1" default="$2" input
  read -r -p "$prompt [$default]: " input
  echo "${input:-$default}"
}

setup_cron() {
  read -r -p "Add this script to cron for daily execution at 02:00? (y/n) " ans
  if [[ "$ans" =~ ^[Yy]$ ]]; then
    # Use the absolute path to this script
    local self_path
    self_path="$(abs_path "$0")"
    local cron_line="0 2 * * * $self_path --log-dir ${LOG_DIR:-/var/log} --days-logs ${DAYS_LOGS:-7} --days-backups ${DAYS_BACKUPS:-30} --delete-originals"
    (crontab -l 2>/dev/null; echo "$cron_line") | crontab -
    say "Cron job added:"
    say "  $cron_line"
  else
    say "Cron job not added."
  fi
}

LOG_DIR=""
DAYS_LOGS=7
DAYS_BACKUPS=30
DELETE_ORIG_INT="true"  # align with your original default behavior

while true; do
  say ""
  say "==== Log Archive Tool ===="
  say "1. Specify Log Directory          (current: ${LOG_DIR:-/var/log})"
  say "2. Days to Keep Logs              (current: $DAYS_LOGS)"
  say "3. Days to Keep Backup Archives   (current: $DAYS_BACKUPS)"
  say "4. Toggle Delete Originals        (current: $DELETE_ORIG_INT)"
  say "5. Run Archiving Process"
  say "6. Setup Daily Cron (02:00)"
  say "7. Exit"
  say ""
  read -r -p "Choose an option [1-7]: " choice

  case "$choice" in
    1)
      LOG_DIR="$(prompt_for_input "Enter the log directory" "${LOG_DIR:-/var/log}")"
      if [[ ! -d "$LOG_DIR" ]]; then
        err "Log directory does not exist."
        LOG_DIR=""
      else
        say "Log directory set to $LOG_DIR"
      fi
      ;;
    2)
      DAYS_LOGS="$(prompt_for_input "How many days of logs to keep before archiving?" "$DAYS_LOGS")"
      say "Will archive files older than $DAYS_LOGS days."
      ;;
    3)
      DAYS_BACKUPS="$(prompt_for_input "How many days of archives to keep?" "$DAYS_BACKUPS")"
      say "Will delete .tar.gz archives older than $DAYS_BACKUPS days."
      ;;
    4)
      if [[ "$DELETE_ORIG_INT" == "true" ]]; then DELETE_ORIG_INT="false"; else DELETE_ORIG_INT="true"; fi
      say "Delete originals set to: $DELETE_ORIG_INT"
      ;;
    5)
      if [[ -z "$LOG_DIR" ]]; then
        err "Log directory is not set. Please set it first."
      else
        # Use default dest outside source; user can change by editing cron later or switching to flags
        archive_logs "$LOG_DIR" "$DAYS_LOGS" "" "$DAYS_BACKUPS" "$DELETE_ORIG_INT"
      fi
      ;;
    6)
      if [[ -z "$LOG_DIR" ]]; then
        say "Tip: set log directory first (option 1). Using default: /var/log"
        LOG_DIR="/var/log"
      fi
      setup_cron
      ;;
    7)
      say "Exiting..."
      break
      ;;
    *)
      err "Invalid option. Choose 1-7."
      ;;
  esac
done
