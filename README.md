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


## Sample configuration files

- `rclone.conf.example`: sample remotes for Google Drive (`gdrive`) and OVHcloud Object Storage in Frankfurt (`ovh-s3-fra`).
- `docker-compose.yml`: ready-to-run compose service mounting your real `./rclone.conf` and running as a non-root UID/GID (`1000:1000`).

To use:

1. Copy `rclone.conf.example` to `rclone.conf`.
2. Fill in your real Google OAuth token and OVHcloud S3 credentials.
3. Update `RCLONE_S3_REMOTE` bucket/path if needed.
4. Start with `docker compose up -d --build`.

## Build locally

```bash
docker build -t gphotos-takeout:local .
```

## Run

```bash
docker run -d --name gphotos-takeout \
  --user 1000:1000 \
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
