# gphotos-takeout

Moves Google Takeout archives from Google Drive to S3 object storage, then deletes them from Google Drive after a successful upload.

## Quick start

### 1) Generate `rclone.conf`

```bash
docker run --rm -it \
  -v "$(pwd):/work" \
  -w /work \
  rclone/rclone:latest \
  config
```

Create these remotes in the menu:

- `gdrive` (type `drive`, scope `drive`, login with your personal Google account)
- `s3` (type `s3`, provider `Other`, add your S3 details)

### 2) Run

```bash
docker compose up -d
```

By default this reads from `gdrive:Takeout` (the `Takeout` folder in Drive) and writes to `s3:my-bucket` (can be modified in docker-compose.yml).