# gphotos-takeout

A containerized `rclone` worker that checks Google Drive every hour for new Google Photos Takeout ZIP files, uploads them directly to S3 as **Infrequent Access**, and then deletes the source files from Google Drive after successful transfer.

## Why this fits your requirements

- **Hourly scan**: the container runs an infinite loop with a 3600-second sleep by default.
- **Low local disk usage (<=10 GB)**: transfers stream directly from Google Drive to S3 via `rclone`; no large local unzip/staging workflow is used.
- **Delete after upload**: uses `rclone move` (copy + delete source on success).
- **S3 infrequent access**: uses `--s3-storage-class STANDARD_IA`.

## Prerequisites

1. An `rclone.conf` with both remotes configured:
   - Google Drive remote, for example `gdrive:`
   - S3 remote, for example `s3:`
2. A destination S3 bucket path.

## Build locally

```bash
docker build -t gphotos-takeout:local .
```

## Run

```bash
docker run -d --name gphotos-takeout \
  -v $(pwd)/rclone.conf:/config/rclone/rclone.conf:ro \
  -e RCLONE_DRIVE_REMOTE="gdrive:Takeout" \
  -e RCLONE_S3_REMOTE="s3:google-photos-archive" \
  -e SCAN_INTERVAL_SECONDS=3600 \
  ghcr.io/<owner>/<repo>:latest
```

## Environment variables

- `RCLONE_DRIVE_REMOTE` (required): source path in Google Drive remote (e.g. `gdrive:Takeout`)
- `RCLONE_S3_REMOTE` (required): destination path in S3 remote (e.g. `s3:google-photos-archive`)
- `SCAN_INTERVAL_SECONDS` (optional, default `3600`)
- `RCLONE_TRANSFERS` (optional, default `2`)
- `RCLONE_CHECKERS` (optional, default `4`)
- `RCLONE_LOG_LEVEL` (optional, default `INFO`)
- `RCLONE_ADDITIONAL_ARGS` (optional): extra flags appended to `rclone move`

## GitHub Actions: build to GHCR

This repo includes `.github/workflows/build-image.yml` which:

- Builds on pushes to `main`, on version tags (`v*`), and manual dispatch.
- Logs into `ghcr.io` using `GITHUB_TOKEN`.
- Publishes tags including branch, tag, sha, and `latest` on default branch.

The image is published as:

- `ghcr.io/<owner>/<repo>:<tag>`
