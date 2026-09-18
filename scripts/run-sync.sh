#!/bin/sh
# Disable globbing: filter patterns and RCLONE_ADDITIONAL_ARGS are expanded
# unquoted and must reach rclone literally, not as expanded pathnames.
set -euf

# Required environment variables:
# - RCLONE_DRIVE_REMOTE (example: gdrive:Takeout)
# - RCLONE_S3_REMOTE (example: s3:my-bucket)

# Optional:
# - RCLONE_TRANSFERS (default: 2)
# - RCLONE_CHECKERS (default: 4)
# - RCLONE_LOG_LEVEL (default: INFO)
# - RCLONE_S3_STORAGE_CLASS (default: STANDARD)
# - RCLONE_ADDITIONAL_ARGS (extra flags passed to rclone)
# - VERIFY_MODE (checksum | download | size, default: checksum)
# - DELETE_AFTER_VERIFY (true | false, default: true)
# - WRITE_MANIFEST (true | false, default: true)
# - MANIFEST_PREFIX (default: _manifests)

: "${RCLONE_DRIVE_REMOTE:?RCLONE_DRIVE_REMOTE is required, e.g. gdrive:Takeout}"
: "${RCLONE_S3_REMOTE:?RCLONE_S3_REMOTE is required, e.g. s3:my-bucket}"

SCAN_INTERVAL_SECONDS=3600
RCLONE_TRANSFERS="${RCLONE_TRANSFERS:-2}"
RCLONE_CHECKERS="${RCLONE_CHECKERS:-4}"
RCLONE_LOG_LEVEL="${RCLONE_LOG_LEVEL:-INFO}"
RCLONE_S3_STORAGE_CLASS="${RCLONE_S3_STORAGE_CLASS:-STANDARD}"
RCLONE_ADDITIONAL_ARGS="${RCLONE_ADDITIONAL_ARGS:-}"
VERIFY_MODE="${VERIFY_MODE:-checksum}"
DELETE_AFTER_VERIFY="${DELETE_AFTER_VERIFY:-true}"
WRITE_MANIFEST="${WRITE_MANIFEST:-true}"
MANIFEST_PREFIX="${MANIFEST_PREFIX:-_manifests}"

# Validate configuration once at startup: a typo here must stop the container
# immediately, not silently produce a no-op pass every hour.
case "$VERIFY_MODE" in
  checksum) VERIFY_ARGS="--checksum" ;;
  download) VERIFY_ARGS="--download" ;;
  size)     VERIFY_ARGS="--size-only" ;;
  *)
    echo "VERIFY_MODE must be checksum, download or size (got '$VERIFY_MODE')" >&2
    exit 1
    ;;
esac

require_bool() {
  case "$2" in
    true|false) ;;
    *)
      echo "$1 must be true or false (got '$2')" >&2
      exit 1
      ;;
  esac
}

require_bool DELETE_AFTER_VERIFY "$DELETE_AFTER_VERIFY"
require_bool WRITE_MANIFEST "$WRITE_MANIFEST"

# Takeout chunk files: takeout-<timestamp>-001.zip ... takeout-<timestamp>-NNN.zip
TAKEOUT_FILTER='takeout-*-[0-9][0-9][0-9].zip'

# Flags shared by every rclone command that walks the takeout chunks.
COMMON_ARGS="--include $TAKEOUT_FILTER --transfers $RCLONE_TRANSFERS --checkers $RCLONE_CHECKERS --log-level $RCLONE_LOG_LEVEL --log-format date,time --stats 30s"

WORK_DIR="${TMPDIR:-/tmp}/gphotos-takeout"
mkdir -p "$WORK_DIR"

log() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"
}

log_err() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" >&2
}

count_lines() {
  if [ -s "$1" ]; then
    wc -l <"$1" | tr -d ' '
  else
    echo 0
  fi
}

# Phase 1: copy, never move. The source stays in place until the upload has
# been verified independently in phase 2.
#
# --checksum compares by hash instead of size+modtime, so a file that is
#   already in S3 but differs gets re-uploaded rather than skipped.
# rclone stores the source MD5 as X-Amz-Meta-Md5chksum on multipart uploads,
#   which is what makes the hash comparison in phase 2 possible at all: the
#   ETag of a multipart object is not an MD5. Never set --s3-disable-checksum.
# --drive-stop-on-upload-limit avoids partial behavior if quota is hit.
copy_phase() {
  log "Phase 1/3: copying $RCLONE_DRIVE_REMOTE -> $RCLONE_S3_REMOTE"

  # shellcheck disable=SC2086
  rclone copy "$RCLONE_DRIVE_REMOTE" "$RCLONE_S3_REMOTE" \
    $COMMON_ARGS \
    --checksum \
    --s3-storage-class "$RCLONE_S3_STORAGE_CLASS" \
    --drive-stop-on-upload-limit \
    $RCLONE_ADDITIONAL_ARGS
}

# Phase 2: verify what landed in S3 against what is still in Drive.
#
# checksum (default): compares MD5 on both sides. Drive serves it from file
#   metadata, S3 from the X-Amz-Meta-Md5chksum written during the upload.
#   No data transfer, no egress cost.
# download: streams both objects back and hashes the bytes as received. Also
#   catches corruption that happened after the upload and trusts no stored
#   metadata. Costs full egress plus retrieval fees on STANDARD_IA.
# size: size comparison only. No integrity guarantee; escape hatch for S3
#   providers that drop user metadata on multipart uploads.
#
# --one-way only reports files missing from S3. Without it every file already
# deleted from Drive in an earlier pass would be reported as missing-on-src.
verify_phase() {
  matched="$1"
  differ="$2"
  missing="$3"
  errors="$4"

  log "Phase 2/3: verifying uploads (mode: $VERIFY_MODE)"

  # rclone check exits non-zero as soon as a single file differs. That is not a
  # reason to abort the pass: the files that did match are still safe to
  # delete, so evaluate the result lists instead of the exit code.
  # shellcheck disable=SC2086
  rclone check "$RCLONE_DRIVE_REMOTE" "$RCLONE_S3_REMOTE" \
    $COMMON_ARGS \
    $VERIFY_ARGS \
    --one-way \
    --match "$matched" \
    --differ "$differ" \
    --missing-on-dst "$missing" \
    --error "$errors" \
    $RCLONE_ADDITIONAL_ARGS || true

  log "Verification result: $(count_lines "$matched") verified, $(count_lines "$differ") mismatched, $(count_lines "$missing") missing in S3, $(count_lines "$errors") errored"

  report_failures "$differ" "Checksum mismatch, source kept for retry:"
  report_failures "$missing" "Not present in S3, source kept for retry:"
  report_failures "$errors" "Could not be compared, source kept for retry:"

  enforce_hash_gate "$matched"
}

# rclone check reports a file as MATCHED when it cannot obtain a hash from one
# of the sides: checkHashes() returns equal=true with hash.None, and the file is
# counted as a match with only a debug-level "could not check hash" note. On an
# S3 provider that drops user metadata on multipart uploads, every chunk would
# therefore be reported as verified without a single byte ever being compared,
# and the Drive original would be deleted.
#
# Guard against that explicitly: ask S3 for the MD5 of every matched file and
# drop the ones that have none. rclone lsf --format ph prints "path;hash" and
# leaves the hash field empty when no hash is available, so this needs no JSON
# parsing. Only meaningful for the metadata-based comparison; --download hashes
# the transferred bytes itself, and --size-only is an explicit opt-out.
enforce_hash_gate() {
  matched="$1"

  if [ "$VERIFY_MODE" != "checksum" ] || [ ! -s "$matched" ]; then
    return 0
  fi

  hashes="$WORK_DIR/s3-hashes.csv"
  gated="$WORK_DIR/gated.txt"

  if ! rclone lsf "$RCLONE_S3_REMOTE" \
    --files-from "$matched" \
    --format ph \
    --hash MD5 \
    --checkers "$RCLONE_CHECKERS" \
    --log-level "$RCLONE_LOG_LEVEL" \
    --log-format date,time >"$hashes"; then
    log_err "Could not read back MD5 hashes from S3; keeping all sources for retry"
    : >"$matched"
    rm -f "$hashes"
    return 0
  fi

  # Keep only paths whose hash field is non-empty.
  awk -F';' 'NF >= 2 && $NF != "" { sub(/;[^;]*$/, ""); print }' "$hashes" >"$gated"

  n_before=$(count_lines "$matched")
  n_after=$(count_lines "$gated")

  if [ "$n_after" -lt "$n_before" ]; then
    log_err "$(( n_before - n_after )) of $n_before file(s) reported as verified carry no MD5 in S3."
    log_err "rclone counts those as matches without comparing anything, so they are NOT deleted."
    log_err "This provider likely drops x-amz-meta-md5chksum on multipart uploads; use VERIFY_MODE=download."
  fi

  mv "$gated" "$matched"
  rm -f "$hashes"
}

report_failures() {
  list="$1"
  headline="$2"

  if [ -s "$list" ]; then
    log_err "$headline"
    sed 's/^/  /' "$list" >&2
  fi
}

# Record the MD5 of every verified file next to the data in S3, so the archive
# can still be validated years from now, once Drive is long gone.
write_manifest() {
  matched="$1"

  if [ "$WRITE_MANIFEST" != "true" ] || [ ! -s "$matched" ]; then
    return 0
  fi

  manifest_name="manifest-$(date -u +%Y%m%dT%H%M%SZ).md5"
  manifest_path="$WORK_DIR/$manifest_name"

  # Hashes are read from Drive: that side never went through the upload path
  # and is therefore the reference.
  if ! rclone hashsum md5 "$RCLONE_DRIVE_REMOTE" \
    --files-from "$matched" \
    --checkers "$RCLONE_CHECKERS" \
    --log-level "$RCLONE_LOG_LEVEL" \
    --log-format date,time \
    --output-file "$manifest_path"; then
    log_err "Failed to generate manifest; continuing without it"
    rm -f "$manifest_path"
    return 0
  fi

  if rclone copyto "$manifest_path" "$RCLONE_S3_REMOTE/$MANIFEST_PREFIX/$manifest_name" \
    --s3-storage-class "$RCLONE_S3_STORAGE_CLASS" \
    --log-level "$RCLONE_LOG_LEVEL" \
    --log-format date,time; then
    log "Manifest uploaded: $MANIFEST_PREFIX/$manifest_name ($(count_lines "$manifest_path") entries)"
  else
    log_err "Failed to upload manifest $manifest_name"
  fi

  rm -f "$manifest_path"
}

# Phase 3: delete from Drive, but only the files that verified cleanly.
# Anything mismatched, missing or unreadable stays put and is retried next pass.
delete_phase() {
  matched="$1"

  if [ "$DELETE_AFTER_VERIFY" != "true" ]; then
    log "Phase 3/3: skipped (DELETE_AFTER_VERIFY=$DELETE_AFTER_VERIFY)"
    return 0
  fi

  # Guard against deleting the whole remote: rclone delete without --files-from
  # entries would match every file the filter allows.
  if [ ! -s "$matched" ]; then
    log "Phase 3/3: nothing verified, no source files deleted"
    return 0
  fi

  log "Phase 3/3: deleting $(count_lines "$matched") verified file(s) from $RCLONE_DRIVE_REMOTE"

  rclone delete "$RCLONE_DRIVE_REMOTE" \
    --files-from "$matched" \
    --transfers "$RCLONE_TRANSFERS" \
    --checkers "$RCLONE_CHECKERS" \
    --log-level "$RCLONE_LOG_LEVEL" \
    --log-format date,time
}

sync_once() {
  log "Starting sync pass"

  matched="$WORK_DIR/matched.txt"
  differ="$WORK_DIR/differ.txt"
  missing="$WORK_DIR/missing.txt"
  errors="$WORK_DIR/errors.txt"

  # Truncate up front: a pass that aborts midway must never leave a stale
  # match list behind for the delete phase of the next pass.
  : >"$matched"
  : >"$differ"
  : >"$missing"
  : >"$errors"

  copy_phase
  verify_phase "$matched" "$differ" "$missing" "$errors"
  write_manifest "$matched"
  delete_phase "$matched"

  rm -f "$matched" "$differ" "$missing" "$errors" "$WORK_DIR/s3-hashes.csv" "$WORK_DIR/gated.txt"

  log "Sync pass completed"
}

while true; do
  if ! sync_once; then
    log_err "Sync pass failed; retrying after interval"
  fi

  log "Sleeping for ${SCAN_INTERVAL_SECONDS}s"
  sleep "$SCAN_INTERVAL_SECONDS"
done
