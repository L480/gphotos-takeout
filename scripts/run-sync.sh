#!/bin/sh
set -eu

# Required environment variables:
# - RCLONE_DRIVE_REMOTE (example: gdrive:Takeout)
# - RCLONE_S3_REMOTE (example: s3:my-bucket)

# Optional:
# - RCLONE_TRANSFERS (default: 2)
# - RCLONE_CHECKERS (default: 4)
# - RCLONE_LOG_LEVEL (default: INFO)
# - RCLONE_S3_STORAGE_CLASS (default: STANDARD_IA)
# - RCLONE_ADDITIONAL_ARGS (extra flags passed to rclone)

: "${RCLONE_DRIVE_REMOTE:?RCLONE_DRIVE_REMOTE is required, e.g. gdrive:Takeout}"
: "${RCLONE_S3_REMOTE:?RCLONE_S3_REMOTE is required, e.g. s3:my-bucket}"

SCAN_INTERVAL_SECONDS=3600
RCLONE_TRANSFERS="${RCLONE_TRANSFERS:-2}"
RCLONE_CHECKERS="${RCLONE_CHECKERS:-4}"
RCLONE_LOG_LEVEL="${RCLONE_LOG_LEVEL:-INFO}"
RCLONE_S3_STORAGE_CLASS="${RCLONE_S3_STORAGE_CLASS:-STANDARD_IA}"
RCLONE_ADDITIONAL_ARGS="${RCLONE_ADDITIONAL_ARGS:-}"

# Logs to stderr with an rclone-like "date time LEVEL : message" shape, so a
# single log pipeline can parse both wrapper and rclone lines.
log() {
  _level=$1
  shift
  printf '%s %-6s: %s\n' "$(date -u '+%Y/%m/%d %H:%M:%S')" "$_level" "$*" >&2
}

# Advisory only: warns if the Drive remote is still using rclone's built-in
# shared client_id, whose "Queries per minute" quota is pooled across every
# rclone user who never created their own OAuth client (see README step 2).
# Never blocks startup.
check_client_id() {
  _remote=${RCLONE_DRIVE_REMOTE%%:*}
  if rclone config show "$_remote" 2>/dev/null | grep -q '^client_id *= *[^ ]'; then
    return 0
  fi
  log ERROR "The '$_remote' remote has no client_id: rclone's built-in SHARED"
  log ERROR "Google credentials (project_number:202264815644) are in use. Their"
  log ERROR "'Queries per minute' quota is shared with every other rclone user,"
  log ERROR "which causes 403 quota errors even at RCLONE_TRANSFERS=1."
  log ERROR "This shared client is ALSO being retired during 2026 and will stop"
  log ERROR "working. See step 2 in the README to create your own client_id."
}

run_rclone() {
  # move = copy + delete source only after successful upload
  # --include 'takeout-*-[0-9][0-9][0-9].zip' targets Takeout chunk files 001+ (e.g. 001-051)
  # --s3-storage-class is configurable via RCLONE_S3_STORAGE_CLASS (default STANDARD_IA)
  # transfer is streamed via rclone; no large local staging required
  # --drive-stop-on-upload-limit avoids partial behavior if quota is hit
  _rc=0
  rclone move "$RCLONE_DRIVE_REMOTE" "$RCLONE_S3_REMOTE" \
    --include 'takeout-*-[0-9][0-9][0-9].zip' \
    --s3-storage-class "$RCLONE_S3_STORAGE_CLASS" \
    --transfers "$RCLONE_TRANSFERS" \
    --checkers "$RCLONE_CHECKERS" \
    --drive-stop-on-upload-limit \
    --log-level "$RCLONE_LOG_LEVEL" \
    --log-format "date,time" \
    --stats 30s \
    $RCLONE_ADDITIONAL_ARGS || _rc=$?
  return "$_rc"
}

check_client_id || true

while true; do
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Starting sync pass"

  rc=0
  run_rclone || rc=$?

  if [ "$rc" -eq 0 ]; then
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Sync pass completed"
  else
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Sync pass failed with rclone exit code $rc; retrying after interval" >&2
  fi

  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Sleeping for ${SCAN_INTERVAL_SECONDS}s"
  sleep "$SCAN_INTERVAL_SECONDS"
done
