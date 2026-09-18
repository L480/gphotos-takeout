# 📦 Google Photos Takeout

This project runs a lightweight, repeatable pipeline for Google Photos Takeout ZIP archives: it scans a Drive folder, streams matching archives directly to S3, and only removes each source file after the upload has been verified by checksum. The sync loop in `scripts/run-sync.sh` runs a copy → verify → delete pass on a fixed interval (default hourly), filters for `takeout-*-<n>.zip` chunks, and applies configurable transfer/checker/concurrency settings through environment variables. In practice, that means no large local staging, predictable retries on failure, and automated cleanup of completed files from Google Drive.

## Quick start

### 1. Set up Google Takeout

Set up Google Takeout via https://takeout.google.com/.

![Google Takeout Setup](./images/image3.png)

### 2. Generate `rclone.conf`

```bash
mkdir /opt/gphotos-takeout && cd /opt/gphotos-takeout
docker run --rm -it \
  -v "$(pwd):/config/rclone" \
  rclone/rclone:latest \
  config
```

Create these remotes in the menu:

- `gdrive` (type `drive`, scope `drive`, login with your personal Google account)
- `s3` (type `s3`, provider `Other`, add your S3 details)

Change folder permissions:

```bash
chown -R 1000:1000 /opt/gphotos-takeout
```

### 3. Run

Change bucket name in [docker-compose.yml](./docker-compose.yml#L10):

```bash
nano docker-compose.yml
```

Start container:

```bash
docker compose up -d
```

## Integrity

Each pass runs in three phases instead of a single `rclone move`, so nothing is
removed from Drive before the copy in S3 has been proven correct:

1. **Copy** — `rclone copy` with `--checksum`, so an existing S3 object that
   differs from the source is re-uploaded instead of skipped.
2. **Verify** — `rclone check --one-way` compares Drive against S3 and writes
   the result into separate match/differ/missing lists.
3. **Delete** — only the files on the match list are removed from Drive.
   Anything that mismatched, is missing, or could not be compared stays in
   Drive, is logged as an error, and is retried on the next pass.

### Why a plain `rclone move` is not enough

Takeout chunks are large enough that S3 always stores them as multipart
uploads, and the ETag of a multipart object is not an MD5. With no hash
available on both sides, rclone silently falls back to comparing file sizes
and deletes the source anyway — a corrupted transfer of the correct length
would pass.

The pipeline works around this: rclone writes the source MD5 to the
`X-Amz-Meta-Md5chksum` metadata key during the upload, and the verify phase
reads it back for a real hash comparison. This is also why
`--s3-disable-checksum` must never be added to `RCLONE_ADDITIONAL_ARGS`.

### Which files are picked up

The chunk filter is an rclone regexp rather than a glob:

```
{{takeout-[^/]*-[0-9]+\.zip}}
```

The previous `takeout-*-[0-9][0-9][0-9].zip` glob required exactly three
digits. Google does not always zero-pad that far: a small export produces
`takeout-<timestamp>-1.zip`, and an export past 999 parts needs four digits.
Those files matched nothing, so they were never uploaded and never deleted,
with nothing in the log to say they had been skipped.

Two details of the pattern are deliberate:

- **No `^` or `$`.** For a path pattern without a leading slash, rclone wraps
  the rule as `(^|/)(<regexp>)$` itself. Adding anchors yields
  `(^|/)(^...$)$`, which stops matching anything inside a subdirectory.
- **`[^/]*`, not `.*`.** A glob `*` does not cross directory boundaries, but a
  regexp `.*` does: `takeout-x/evil-001.zip` would match.

Override with `TAKEOUT_FILTER` to sync something else, e.g.
`{{takeout-[^/]*-[0-9]+\.tgz}}` for tar.gz exports.

### Verification modes

`VERIFY_MODE` selects how phase 2 compares the two sides:

| Mode | Compares | Cost | Notes |
| --- | --- | --- | --- |
| `checksum` (default) | MD5 from Drive metadata vs. `X-Amz-Meta-Md5chksum` | No data transfer | Detects corruption on the transfer path |
| `download` | Re-reads both objects and hashes the received bytes | Full egress on both sides, plus retrieval fees on `STANDARD_IA` | Trusts no stored metadata; also catches corruption that happened at rest |
| `size` | File size only | No data transfer | No integrity guarantee. Only for S3 providers that drop user metadata on multipart uploads |

### Checksum manifests

After each pass the MD5 of every verified file is written to
`s3://<bucket>/_manifests/manifest-<timestamp>.md5` (disable with
`WRITE_MANIFEST=false`). The hashes are read from Drive, which is the side that
never went through the upload path. This keeps the archive verifiable years
later, long after the Drive originals are gone:

```bash
rclone checksum md5 manifest-20260101T120000Z.md5 s3:my-bucket
```

### Non-AWS S3 providers

Run the preflight check once before enabling the sync loop against a new
bucket:

```bash
RCLONE_S3_REMOTE=s3:my-bucket ./scripts/preflight-check.sh
```

It uploads a small forced-multipart object, reads the MD5 back, and confirms
that `rclone check` really compares hashes instead of waving the file through.

This matters because of how rclone reports an unhashable file: when it cannot
obtain a hash from one side, `checkHashes()` returns *equal* with `hash.None`,
and the file is counted as a **match**. Only a debug-level counter
(`N hashes could not be checked`) records that nothing was compared. A provider
that discards `x-amz-meta-md5chksum` on multipart uploads would therefore make
every chunk look verified.

The sync loop guards against this independently: after `rclone check`, it reads
the MD5 of every matched file back from S3 and drops any file that has none, so
a source file is never deleted on the strength of a comparison that did not
happen. The log says so explicitly when it triggers.

> **Upgrading an existing deployment:** that guard changes behaviour on a loop
> that is already running. If the bucket does not return MD5s for multipart
> objects, nothing will be deleted from Drive any more, and Drive will fill up
> until new Takeout exports start failing. This is the safe direction to fail,
> but it is not a silent one: run the preflight check before deploying, and
> switch to `VERIFY_MODE=download` if it reports no MD5.

**OVHcloud specifics:**

- `STANDARD_IA` is not an OVHcloud storage class. OVHcloud offers `STANDARD`
  and `EXPRESS_ONEZONE` (which maps to the High Performance class). rclone
  sends `x-amz-storage-class` regardless of provider, and OVHcloud is lenient
  about the unknown value rather than rejecting the upload, so the old default
  did work; it just did not mean anything. The default is now `STANDARD` so
  that the request says what is actually being stored. Set
  `RCLONE_S3_STORAGE_CLASS` explicitly if you want something else.
- rclone has no dedicated `OVHcloud` provider before 1.70, and the image pins
  1.69, so `provider = Other` is correct. That setting also sets
  `useMultipartEtag = false`, meaning rclone relies on the metadata hash rather
  than the ETag, which is the behaviour this pipeline depends on.
- If the preflight check reports no MD5, use `VERIFY_MODE=download`.

Note that a checksum only proves the bytes in S3 match the bytes Google
delivered. It cannot detect an archive that Takeout generated incorrectly in
the first place — verify the ZIPs themselves before relying on the backup.

### Configuration

| Variable | Default | Purpose |
| --- | --- | --- |
| `VERIFY_MODE` | `checksum` | Verification mode, see table above |
| `DELETE_AFTER_VERIFY` | `true` | Set to `false` to keep every source file in Drive (dry run for the delete phase) |
| `WRITE_MANIFEST` | `true` | Write and upload the per-pass checksum manifest |
| `MANIFEST_PREFIX` | `_manifests` | Bucket prefix the manifests are stored under |
| `TAKEOUT_FILTER` | `{{takeout-[^/]*-[0-9]+\.zip}}` | rclone `--include` pattern selecting the chunks to sync |
| `RCLONE_S3_STORAGE_CLASS` | `STANDARD` | Storage class. `STANDARD_IA` is AWS-only and is meaningless on providers that do not define it |

## Tested VPS Offerings

### ✅ [Strato VC 1-1 (1 EUR/month)](https://www.strato.de/server/linux-vserver/)

![Strato VC 1-1 Offering](./images/image4.png)

#### Upload Speed with `RCLONE_TRANSFERS=2`: 86.3 Mbit/s Average

![Upload Speed RCLONE_TRANSFERS=2](./images/image2.png)
