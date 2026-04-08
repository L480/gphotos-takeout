# gphotos-takeout

A containerized `rclone` worker that checks Google Drive every hour for new Google Photos Takeout ZIP files, uploads them directly to S3 as **Infrequent Access**, and then deletes the source files from Google Drive after successful transfer.

## Why this fits your requirements

- **Personal Google account OAuth**: uses a regular Google Drive OAuth remote (`gdrive`) configured with your personal account token (no service account required).
- **Fixed hourly scan**: the container runs an infinite loop with a fixed 3600-second sleep interval (1 hour).
- **Low local disk usage (<=10 GB)**: transfers stream directly from Google Drive to S3 via `rclone`; no large local unzip/staging workflow is used.
- **Delete after upload**: uses `rclone move` (copy + delete source on success).
- **S3 infrequent access**: uses `--s3-storage-class STANDARD_IA`.

## Prerequisites

1. An `rclone.conf` with both remotes configured:
   - Google Drive remote, named `gdrive:` (personal account OAuth token)
   - OVHcloud S3 remote, named `ovh-s3-de:`
2. A destination S3 bucket path (`my-bucket`).

## Sample configuration files

- `rclone.conf.example`: sample remotes for personal Google Drive (`gdrive`) and OVHcloud Object Storage (`ovh-s3-de`) using endpoint `https://s3.de.io.cloud.ovh.net` and region `de`.
- `docker-compose.yml`: ready-to-run compose service mounting your real `./rclone.conf` and running as a non-root UID/GID (`1000:1000`).

To use:

1. Copy `rclone.conf.example` to `rclone.conf`.
2. Fill in your personal Google OAuth token and OVHcloud S3 credentials.
3. Keep the destination as `ovh-s3-de:my-bucket` (or add a subpath).
4. Start with `docker compose up -d --build`.

## Build locally

```bash
docker build -t ghcr.io/L480/gphotos-takeout:latest .
```

## Run

```bash
docker run -d --name gphotos-takeout \
  --user 1000:1000 \
  -v $(pwd)/rclone.conf:/config/rclone/rclone.conf:ro \
  -e RCLONE_DRIVE_REMOTE="gdrive:Takeout" \
  -e RCLONE_S3_REMOTE="ovh-s3-de:my-bucket" \
  ghcr.io/L480/gphotos-takeout:latest
```

## Environment variables

- `RCLONE_DRIVE_REMOTE` (required): source path in Google Drive remote (e.g. `gdrive:Takeout`)
- `RCLONE_S3_REMOTE` (required): destination path in S3 remote (e.g. `ovh-s3-de:my-bucket`)
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

- `ghcr.io/L480/gphotos-takeout:<tag>`
