# gphotos-takeout

This project runs a lightweight, repeatable pipeline for Google Photos Takeout ZIP archives: it scans a Drive folder, streams matching archives directly to S3, and only removes each source file after a successful upload. The sync loop in `scripts/run-sync.sh` executes `rclone move` on a fixed interval (default hourly), filters for `takeout-*-NNN.zip` chunks, and applies configurable transfer/checker/concurrency settings through environment variables. In practice, that means no large local staging, predictable retries on failure, and automated cleanup of completed files from Google Drive.

## Quick start

### 1) Generate `rclone.conf`

```bash
docker run --rm -it \
  -v "$(pwd):/config/rclone" \
  rclone/rclone:latest \
  config
```

Create these remotes in the menu:

- `gdrive` (type `drive`, scope `drive`, login with your personal Google account)
- `s3` (type `s3`, provider `Other`, add your S3 details)

Change file permissions:

```bash
chown 1000:1000 rclone.conf
```

### 2) Run

```bash
docker compose up -d
```

By default this reads from `gdrive:Takeout` (the `Takeout` folder in Drive) and writes to `s3:my-bucket` (can be modified in docker-compose.yml).
