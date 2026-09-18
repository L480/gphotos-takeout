#!/bin/sh
# Checks whether the configured S3 remote can actually support the checksum
# verification the sync loop relies on, before any source file is deleted.
#
# The sync loop deletes a file from Drive once rclone check reports it as
# matched. rclone reports a match even when it could not obtain a hash from
# either side, so on a provider that drops user metadata on multipart uploads
# "verified" would mean nothing. Takeout chunks are always multipart, so this
# has to be confirmed against the real bucket rather than assumed.
#
# Usage: RCLONE_S3_REMOTE=s3:my-bucket ./scripts/preflight-check.sh
set -euf

: "${RCLONE_S3_REMOTE:?RCLONE_S3_REMOTE is required, e.g. s3:my-bucket}"

RCLONE_S3_STORAGE_CLASS="${RCLONE_S3_STORAGE_CLASS:-STANDARD}"
TEST_PREFIX="${TEST_PREFIX:-_preflight}"

# Force a multipart upload with a small file: the chunk size stays at the 5 MiB
# minimum (some providers reject anything else) and the cutoff is lowered so
# 10 MiB is enough to produce a real multipart object.
UPLOAD_CUTOFF=5Mi
CHUNK_SIZE=5Mi
TEST_SIZE_MB=10

WORK_DIR="${TMPDIR:-/tmp}/gphotos-preflight.$$"
TEST_NAME="preflight-$(date -u +%Y%m%dT%H%M%SZ).bin"
REMOTE_OBJECT="$RCLONE_S3_REMOTE/$TEST_PREFIX/$TEST_NAME"

failures=0

# shellcheck disable=SC2317  # called via trap
cleanup() {
  rclone deletefile "$REMOTE_OBJECT" >/dev/null 2>&1 || true
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT INT TERM

mkdir -p "$WORK_DIR"

say()  { echo "$*"; }
ok()   { echo "  OK    $*"; }
warn() { echo "  WARN  $*"; }
bad()  { echo "  FAIL  $*"; failures=$((failures + 1)); }
# Explanatory follow-up lines: printed like a finding but not counted as one.
detail() { echo "        $*"; }

say "Remote:        $RCLONE_S3_REMOTE"
say "Storage class: $RCLONE_S3_STORAGE_CLASS"
say "Test object:   $TEST_PREFIX/$TEST_NAME (${TEST_SIZE_MB}MiB, forced multipart via ${UPLOAD_CUTOFF} cutoff)"
say ""

say "1. Uploading a multipart test object"
dd if=/dev/urandom of="$WORK_DIR/$TEST_NAME" bs=1048576 count="$TEST_SIZE_MB" 2>/dev/null
local_md5=$(md5sum "$WORK_DIR/$TEST_NAME" | cut -d' ' -f1)

if rclone copyto "$WORK_DIR/$TEST_NAME" "$REMOTE_OBJECT" \
  --s3-upload-cutoff "$UPLOAD_CUTOFF" \
  --s3-chunk-size "$CHUNK_SIZE" \
  --s3-storage-class "$RCLONE_S3_STORAGE_CLASS" \
  --log-level ERROR; then
  ok "upload accepted with storage class $RCLONE_S3_STORAGE_CLASS"
else
  bad "upload rejected with storage class $RCLONE_S3_STORAGE_CLASS"
  detail "STANDARD_IA is AWS-only. OVHcloud uses STANDARD and EXPRESS_ONEZONE"
  detail "(High Performance). Retry with RCLONE_S3_STORAGE_CLASS=STANDARD."
  exit 1
fi

say ""
say "2. Reading the MD5 back from the uploaded object"
# --format ph prints "path;hash" and leaves the hash empty when none is
# available, which is exactly the condition the sync loop must not treat
# as verified.
remote_line=$(rclone lsf "$RCLONE_S3_REMOTE/$TEST_PREFIX" \
  --include "$TEST_NAME" --format ph --hash MD5 --log-level ERROR || true)
remote_md5=$(printf '%s' "$remote_line" | sed 's/.*;//')

if [ -z "$remote_md5" ]; then
  bad "S3 returns no MD5 for a multipart object"
  detail "rclone stores the source MD5 as x-amz-meta-md5chksum during the upload."
  detail "This provider appears to drop it, so VERIFY_MODE=checksum verifies nothing."
  detail "Use VERIFY_MODE=download instead (hashes both sides, costs egress)."
elif [ "$remote_md5" = "$local_md5" ]; then
  ok "MD5 matches ($remote_md5), VERIFY_MODE=checksum works on this remote"
else
  bad "MD5 mismatch: local $local_md5, remote $remote_md5"
fi

say ""
say "3. End-to-end check: does rclone check actually compare hashes here?"
# rclone reports how many files it had to let through without a hash. Anything
# other than zero means a "verified" result from the sync loop is hollow.
check_output=$(rclone check "$WORK_DIR" "$RCLONE_S3_REMOTE/$TEST_PREFIX" \
  --include "$TEST_NAME" --checksum --one-way --log-level INFO 2>&1 || true)

if printf '%s' "$check_output" | grep -q 'hashes could not be checked'; then
  bad "rclone had to skip the hash comparison:"
  printf '%s\n' "$check_output" | grep 'hashes could not be checked' | sed 's/^/        /'
elif printf '%s' "$check_output" | grep -q '0 differences found'; then
  ok "hashes were compared and matched"
else
  warn "unexpected rclone check output:"
  printf '%s\n' "$check_output" | sed 's/^/        /'
fi

say ""
if [ "$failures" -eq 0 ]; then
  say "Preflight passed. VERIFY_MODE=checksum is safe on this remote."
  exit 0
fi

say "Preflight failed with $failures problem(s). Do not run the sync loop with"
say "DELETE_AFTER_VERIFY=true until these are resolved."
exit 1
