#!/bin/sh
set -eu

# Required environment variables:
# - RCLONE_DRIVE_REMOTE (example: gdrive:Takeout)
# - RCLONE_S3_REMOTE (example: s3:my-bucket)
#
# Optional, see README.md's Configuration reference for the full list and
# rationale. Every RCLONE_* name here is deliberately identical to the
# rclone flag it controls, since rclone itself also reads RCLONE_<FLAG> from
# the environment - keeping the names identical means both lookups always
# agree. Wrapper-only variables (SCAN_INTERVAL_SECONDS, BACKOFF_*) must never
# start with RCLONE_, or rclone would parse them as options for a backend
# literally named "backoff".

: "${RCLONE_DRIVE_REMOTE:?RCLONE_DRIVE_REMOTE is required, e.g. gdrive:Takeout}"
: "${RCLONE_S3_REMOTE:?RCLONE_S3_REMOTE is required, e.g. s3:my-bucket}"

SCAN_INTERVAL_SECONDS=3600
RCLONE_TRANSFERS="${RCLONE_TRANSFERS:-2}"
RCLONE_CHECKERS="${RCLONE_CHECKERS:-4}"
RCLONE_LOG_LEVEL="${RCLONE_LOG_LEVEL:-INFO}"
RCLONE_S3_STORAGE_CLASS="${RCLONE_S3_STORAGE_CLASS:-STANDARD_IA}"
RCLONE_ADDITIONAL_ARGS="${RCLONE_ADDITIONAL_ARGS:-}"

# Google Drive API quota protection. Conservative by default so the pipeline
# survives even on rclone's shared client_id; raise once you have your own
# (see README step 2).
RCLONE_TPSLIMIT="${RCLONE_TPSLIMIT:-10}"
RCLONE_TPSLIMIT_BURST="${RCLONE_TPSLIMIT_BURST:-20}"
RCLONE_DRIVE_PACER_MIN_SLEEP="${RCLONE_DRIVE_PACER_MIN_SLEEP:-1s}"
RCLONE_DRIVE_PACER_BURST="${RCLONE_DRIVE_PACER_BURST:-10}"
RCLONE_MULTI_THREAD_STREAMS="${RCLONE_MULTI_THREAD_STREAMS:-1}"
RCLONE_RETRIES="${RCLONE_RETRIES:-5}"
RCLONE_RETRIES_SLEEP="${RCLONE_RETRIES_SLEEP:-60s}"
RCLONE_LOW_LEVEL_RETRIES="${RCLONE_LOW_LEVEL_RETRIES:-20}"
RCLONE_DRIVE_STOP_ON_DOWNLOAD_LIMIT="${RCLONE_DRIVE_STOP_ON_DOWNLOAD_LIMIT:-true}"
RCLONE_STATS="${RCLONE_STATS:-30s}"
RCLONE_STATS_ONE_LINE="${RCLONE_STATS_ONE_LINE:-true}"

# Logs to stderr with an rclone-like "date time LEVEL : message" shape, so a
# single log pipeline can parse both wrapper and rclone lines.
log() {
  _level=$1
  shift
  printf '%s %-6s: %s\n' "$(date -u '+%Y/%m/%d %H:%M:%S')" "$_level" "$*" >&2
}

# Case-insensitive boolean parsing for RCLONE_*_LIMIT / *_ONE_LINE toggles.
is_true() {
  case "$1" in
    1|[Tt][Rr][Uu][Ee]|[Yy][Ee][Ss]|[Oo][Nn]) return 0 ;;
    *) return 1 ;;
  esac
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
  # Drive is only ever the source here, so --drive-stop-on-upload-limit
  # (which applies when Drive is the destination) would be a no-op;
  # --drive-stop-on-download-limit is the flag that actually matches this
  # workload's daily download quota.
  extra_flags=''
  if is_true "$RCLONE_DRIVE_STOP_ON_DOWNLOAD_LIMIT"; then
    extra_flags="$extra_flags --drive-stop-on-download-limit"
  fi
  if is_true "$RCLONE_STATS_ONE_LINE"; then
    extra_flags="$extra_flags --stats-one-line"
  fi

  _rc=0
  # Intentional word splitting: $extra_flags and $RCLONE_ADDITIONAL_ARGS hold
  # multiple whitespace-separated flags. POSIX sh has no arrays.
  # shellcheck disable=SC2086
  rclone move "$RCLONE_DRIVE_REMOTE" "$RCLONE_S3_REMOTE" \
    --include 'takeout-*-[0-9][0-9][0-9].zip' \
    --s3-storage-class "$RCLONE_S3_STORAGE_CLASS" \
    --transfers "$RCLONE_TRANSFERS" \
    --checkers "$RCLONE_CHECKERS" \
    --tpslimit "$RCLONE_TPSLIMIT" \
    --tpslimit-burst "$RCLONE_TPSLIMIT_BURST" \
    --drive-pacer-min-sleep "$RCLONE_DRIVE_PACER_MIN_SLEEP" \
    --drive-pacer-burst "$RCLONE_DRIVE_PACER_BURST" \
    --multi-thread-streams "$RCLONE_MULTI_THREAD_STREAMS" \
    --low-level-retries "$RCLONE_LOW_LEVEL_RETRIES" \
    --retries "$RCLONE_RETRIES" \
    --retries-sleep "$RCLONE_RETRIES_SLEEP" \
    --log-level "$RCLONE_LOG_LEVEL" \
    --log-format "date,time" \
    --stats "$RCLONE_STATS" \
    $extra_flags $RCLONE_ADDITIONAL_ARGS || _rc=$?
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
