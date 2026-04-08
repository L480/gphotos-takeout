# gphotos-takeout

Personal-use worker: move Google Takeout ZIP parts from Google Drive to OVH Object Storage S3, then delete from Drive after successful upload.

## Quick start

### 1) Create local config folder

```bash
mkdir -p ./rclone-config
```

### 2) Generate Google token + remotes with Docker (no local rclone install)

```bash
docker run --rm -it \
  -v "$(pwd)/rclone-config:/config/rclone" \
  rclone/rclone:latest \
  config
```

Create exactly these remotes in the menu:

- `gdrive` (type `drive`, scope `drive`, login with your personal Google account)
- `ovh-s3-de` (type `s3`, provider `Other`, region `de`, endpoint `s3.de.io.cloud.ovh.net`)

### 3) Copy generated config

```bash
cp ./rclone-config/rclone.conf ./rclone.conf
```

### 4) (Optional) print only the Google token for copy/paste

```bash
awk '/^\[gdrive\]/{in=1;next} /^\[/{in=0} in && /^token = /{print; exit}' ./rclone-config/rclone.conf
```

Paste that `token = ...` line into `rclone.conf.example` if you prefer filling it manually.

### 5) Run from GHCR image (no local build)

```bash
docker compose up -d
```

## Defaults used

- Image: `ghcr.io/L480/gphotos-takeout:latest`
- Source: `gdrive:Takeout`
- Destination: `ovh-s3-de:my-bucket`
- Interval: fixed 1 hour

## File matching

This worker targets Takeout part files like:

- `/Takeout/takeout-20260408T142729Z-3-001.zip`
- `/Takeout/takeout-20260408T142729Z-3-00X.zip`

And deletes them from Drive only after successful upload (`rclone move`).
