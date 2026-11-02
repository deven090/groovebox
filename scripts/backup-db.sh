#!/usr/bin/env bash
# =============================================================================
# Zero-Downtime SQLite Backup -> Amazon S3 using sqlite3.backup() API
# =============================================================================
set -euo pipefail

BUCKET="${BACKUP_BUCKET:-groovebox-backups-786971361856}"
APP_CONTAINER="${APP_CONTAINER:-groovebox-app}"
DB_PATH="${DB_PATH:-/app/data/db.sqlite3}"
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
TEMP_BACKUP="/tmp/db-${TIMESTAMP}.sqlite3"

echo "[$(date -u)] Starting hot SQLite database snapshot..."

# 1. Take ACID-compliant snapshot directly from SQLite engine inside container
docker exec "${APP_CONTAINER}" python3 -c "
import sqlite3
src = sqlite3.connect('${DB_PATH}')
dst = sqlite3.connect('/tmp/hot-backup.sqlite3')
src.backup(dst)
dst.close()
src.close()
"

# 2. Extract snapshot from container to host
docker cp "${APP_CONTAINER}:/tmp/hot-backup.sqlite3" "${TEMP_BACKUP}"
docker exec "${APP_CONTAINER}" rm -f /tmp/hot-backup.sqlite3

# 3. Verify SQLite integrity before uploading
python3 -c "
import sqlite3
con = sqlite3.connect('${TEMP_BACKUP}')
cur = con.cursor()
cur.execute('PRAGMA integrity_check;')
res = cur.fetchone()[0]
assert res == 'ok', f'Integrity check failed: {res}'
con.close()
"

# 4. Upload to S3 with server-side encryption
echo "[$(date -u)] Uploading snapshot to s3://${BUCKET}/db-${TIMESTAMP}.sqlite3..."
aws s3 cp "${TEMP_BACKUP}" "s3://${BUCKET}/db-${TIMESTAMP}.sqlite3" --sse AES256

# 5. Clean up host temp file
rm -f "${TEMP_BACKUP}"
echo "[$(date -u)] Database backup completed successfully: db-${TIMESTAMP}.sqlite3"
