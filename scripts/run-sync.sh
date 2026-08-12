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

SCAN_INTERVAL_SECONDS="${SCAN_INTERVAL_SECONDS:-3600}"
BACKOFF_MAX_SECONDS="${BACKOFF_MAX_SECONDS:-21600}"
BACKOFF_MULTIPLIER="${BACKOFF_MULTIPLIER:-2}"
BACKOFF_JITTER_PERCENT="${BACKOFF_JITTER_PERCENT:-10}"
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

# Non-negative random integer. Avoids $RANDOM, which busybox ash only
# provides when built with CONFIG_ASH_RANDOM_SUPPORT.
random_int() {
  _n=$(od -An -N2 -tu2 /dev/urandom 2>/dev/null | tr -dc '0-9') || _n=''
  [ -n "$_n" ] || _n=$(date +%s)
  printf '%s' "$_n"
}

# Spreads a sleep duration by +/- percent, so many independent deployments of
# this public image do not all wake in the same wall-clock minute after a
# shared outage or quota reset.
apply_jitter() {
  _base=$1
  _pct=$2
  _span=$(( _base * _pct / 100 ))
  if [ "$_span" -le 0 ]; then
    printf '%s' "$_base"
    return 0
  fi
  _off=$(( $(random_int) % ( 2 * _span + 1 ) ))
  printf '%s' "$(( _base - _span + _off ))"
}

# `sleep N &` + `wait` is interruptible by a trapped signal, unlike a bare
# `sleep N`, so the container reacts to `docker compose down` immediately
# instead of waiting out the full sleep and then the stop grace period.
interruptible_sleep() {
  sleep "$1" &
  _sleep_pid=$!
  wait "$_sleep_pid" || true
}

term_handler() {
  log NOTICE "Received termination signal; exiting"
  exit 143
}
trap term_handler TERM INT

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

next_sleep=$SCAN_INTERVAL_SECONDS
consecutive_failures=0

while true; do
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Starting sync pass"

  rc=0
  run_rclone || rc=$?

  # rclone exit codes: 0 success, 1/3 usage or config error, 7 fatal error,
  # 8 max-transfer limit reached, 9 no files transferred (only possible with
  # --error-on-no-transfer, which we do not set, so an idle pass is 0).
  case "$rc" in
    0|9)
      echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Sync pass completed"
      consecutive_failures=0
      next_sleep=$SCAN_INTERVAL_SECONDS
      ;;
    1|3)
      consecutive_failures=$(( consecutive_failures + 1 ))
      echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] rclone exit $rc (usage or config error) - this will NOT self-heal; check rclone.conf and the remote names" >&2
      next_sleep=$BACKOFF_MAX_SECONDS
      ;;
    7|8)
      consecutive_failures=$(( consecutive_failures + 1 ))
      echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] rclone exit $rc (fatal error or transfer limit reached); backing off to maximum" >&2
      next_sleep=$BACKOFF_MAX_SECONDS
      ;;
    *)
      consecutive_failures=$(( consecutive_failures + 1 ))
      echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Sync pass failed with rclone exit code $rc (consecutive failures: $consecutive_failures)" >&2
      if [ "$consecutive_failures" -gt 1 ]; then
        next_sleep=$(( next_sleep * BACKOFF_MULTIPLIER ))
      fi
      if [ "$next_sleep" -gt "$BACKOFF_MAX_SECONDS" ]; then
        next_sleep=$BACKOFF_MAX_SECONDS
      fi
      ;;
  esac

  sleep_for=$(apply_jitter "$next_sleep" "$BACKOFF_JITTER_PERCENT")
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Sleeping for ${sleep_for}s"
  interruptible_sleep "$sleep_for"
done
