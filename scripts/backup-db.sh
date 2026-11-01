#!/usr/bin/env bash
set -euo pipefail

DB_PATH="${DB_PATH:-db.sqlite3}"
BUCKET="${S3_BACKUP_BUCKET:-}"
BACKUP_DIR="${BACKUP_DIR:-/tmp/groovebox-backups}"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_NAME="groovebox-db-${TIMESTAMP}.sqlite3"

mkdir -p "${BACKUP_DIR}"

echo "[backup-db] Copying ${DB_PATH} -> ${BACKUP_DIR}/${BACKUP_NAME}"
cp "${DB_PATH}" "${BACKUP_DIR}/${BACKUP_NAME}"

if [[ -n "${BUCKET}" ]]; then
    echo "[backup-db] Uploading to s3://${BUCKET}/${BACKUP_NAME}"
    aws s3 cp "${BACKUP_DIR}/${BACKUP_NAME}" "s3://${BUCKET}/${BACKUP_NAME}"
    echo "[backup-db] Upload complete."
else
    echo "[backup-db] S3_BACKUP_BUCKET not set — skipping upload. Local backup kept at ${BACKUP_DIR}/${BACKUP_NAME}"
fi
