#!/bin/sh
set -eu

# Required environment variables:
# - RCLONE_DRIVE_REMOTE (example: gdrive:Takeout)
# - RCLONE_S3_REMOTE (example: s3:google-photos-takeout)
# Optional:
# - SCAN_INTERVAL_SECONDS (default: 3600)
# - RCLONE_TRANSFERS (default: 2)
# - RCLONE_CHECKERS (default: 4)
# - RCLONE_LOG_LEVEL (default: INFO)
# - RCLONE_ADDITIONAL_ARGS (extra flags passed to rclone)

: "${RCLONE_DRIVE_REMOTE:?RCLONE_DRIVE_REMOTE is required, e.g. gdrive:Takeout}"
: "${RCLONE_S3_REMOTE:?RCLONE_S3_REMOTE is required, e.g. s3:google-photos-takeout}"

SCAN_INTERVAL_SECONDS="${SCAN_INTERVAL_SECONDS:-3600}"
RCLONE_TRANSFERS="${RCLONE_TRANSFERS:-2}"
RCLONE_CHECKERS="${RCLONE_CHECKERS:-4}"
RCLONE_LOG_LEVEL="${RCLONE_LOG_LEVEL:-INFO}"
RCLONE_ADDITIONAL_ARGS="${RCLONE_ADDITIONAL_ARGS:-}"

sync_once() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Starting sync pass"

  # move = copy + delete source only after successful upload
  # --include '*.zip' ensures only takeout ZIP files are processed
  # --s3-storage-class STANDARD_IA uploads using infrequent access
  # transfer is streamed via rclone; no large local staging required
  # --drive-stop-on-upload-limit avoids partial behavior if quota is hit
  rclone move "$RCLONE_DRIVE_REMOTE" "$RCLONE_S3_REMOTE" \
    --include '*.zip' \
    --s3-storage-class STANDARD_IA \
    --transfers "$RCLONE_TRANSFERS" \
    --checkers "$RCLONE_CHECKERS" \
    --drive-stop-on-upload-limit \
    --log-level "$RCLONE_LOG_LEVEL" \
    --log-format "date,time" \
    --stats 30s \
    $RCLONE_ADDITIONAL_ARGS

  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Sync pass completed"
}

while true; do
  if ! sync_once; then
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Sync pass failed; retrying after interval" >&2
  fi

  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Sleeping for ${SCAN_INTERVAL_SECONDS}s"
  sleep "$SCAN_INTERVAL_SECONDS"
done
