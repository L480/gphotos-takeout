# gphotos-takeout

Personal-use worker: move Google Takeout ZIP parts from Google Drive to OVH Object Storage S3, then delete from Drive after successful upload.

## Quick start

### 1) Generate `rclone.conf` in this folder (no local rclone install)

```bash
docker run --rm -it \
  -v "$(pwd):/work" \
  -w /work \
  rclone/rclone:latest \
  config
```

Create these remotes in the menu:

- `gdrive` (type `drive`, scope `drive`, login with your personal Google account)
- `ovh-s3-de` (type `s3`, provider `Other`, region `de`, endpoint `s3.de.io.cloud.ovh.net`)

When done, confirm you now have `./rclone.conf` in this repo folder.

### 2) Run from GHCR image (no local build)

```bash
docker compose up -d
```

By default this reads from `gdrive:Takeout` (the `Takeout` folder in Drive) and writes to `ovh-s3-de:my-bucket`.
