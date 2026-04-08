# gphotos-takeout

Moves Google Photos Takeout ZIP files from your **personal Google Drive** to OVH Object Storage (S3), then deletes each ZIP from Drive after a successful upload.

- Runs every **1 hour** (fixed)
- Uses `rclone move` (copy + delete source only on success)
- Uploads with `STANDARD_IA`

## Quick start

### 1) Create `rclone.conf` with Docker (personal Google account)

```bash
mkdir -p ./rclone-config

docker run --rm -it \
  -v "$(pwd)/rclone-config:/config/rclone" \
  rclone/rclone:latest \
  config
```

In the interactive `rclone config` menu:

1. Create remote `gdrive` (type `drive`)
2. For `client_id` and `client_secret`, press **Enter** to leave empty (this is fine for personal use)
3. Set scope to `drive`
4. Complete browser login with your personal Google account
5. Create remote `ovh-s3-de` (type `s3`, provider `Other`)
6. Set:
   - region: `de`
   - endpoint: `s3.de.io.cloud.ovh.net`
   - access key / secret key: your OVH credentials

After saving, copy config into this repo:

```bash
cp ./rclone-config/rclone.conf ./rclone.conf
```

### 2) Start the worker

```bash
docker compose up -d --build
```

Default destination is:

- `ovh-s3-de:my-bucket`

Default source is:

- `gdrive:Takeout`

## What gets deleted from Google Drive?

The worker uses:

```bash
rclone move gdrive:Takeout ovh-s3-de:my-bucket --include '*.zip'
```

So ZIP files are deleted from Drive **only after** each file upload succeeds.

## Main env vars

- `RCLONE_DRIVE_REMOTE` (default in compose: `gdrive:Takeout`)
- `RCLONE_S3_REMOTE` (default in compose: `ovh-s3-de:my-bucket`)
- `RCLONE_TRANSFERS` (default `2`)
- `RCLONE_CHECKERS` (default `4`)
- `RCLONE_LOG_LEVEL` (default `INFO`)
