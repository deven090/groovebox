#!/usr/bin/env bash
# =============================================================================
# Groovebox — One-Shot Automated Production Deployment Script
#
# Target OS: Ubuntu 24.04 LTS / 22.04 LTS (AWS EC2 t3.micro)
# Region:    ap-south-1
#
# Prerequisites before execution:
#   1. EC2 instance attached to an IAM Instance Profile (groovebox-ec2-role)
#      with AmazonEC2ContainerRegistryReadOnly, AmazonS3FullAccess (scoped to bucket),
#      and CloudWatch/SNS permissions if running monitoring in-script.
#   2. Security Group: Inbound TCP 22 (SSH), 80 (HTTP), 443 (HTTPS) open.
#   3. Elastic IP associated with this EC2 instance.
# =============================================================================
set -euo pipefail

# ----------------------------- CONFIGURATION ---------------------------------
REPO_URL="${REPO_URL:-https://github.com/deven090/groovebox.git}"
APP_DIR="${APP_DIR:-/opt/groovebox}"

DOMAIN="${DOMAIN:-quack-vortex-99.duckdns.org}"
DUCKDNS_SUBDOMAIN="${DUCKDNS_SUBDOMAIN:-quack-vortex-99}"
DUCKDNS_TOKEN="${DUCKDNS_TOKEN:-}"          # Leave empty if DuckDNS already points to EIP

LETSENCRYPT_EMAIL="${LETSENCRYPT_EMAIL:-devendra2579a@gmail.com}"
ALERT_EMAIL="${ALERT_EMAIL:-devendra2579a@gmail.com}"

AWS_REGION="${AWS_REGION:-ap-south-1}"
AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:-786971361856}"
ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
ECR_IMAGE="${ECR_REGISTRY}/groovebox:latest"

S3_BUCKET="${S3_BUCKET:-groovebox-backups-786971361856}"
APP_CONTAINER="groovebox-app"
NGINX_CONTAINER="groovebox-nginx"
COMPOSE_FILE="docker-compose.prod.yml"

# Dead-man's-switch URL (e.g. healthchecks.io) - optional
HEALTHCHECK_URL="${HEALTHCHECK_URL:-}"
# -----------------------------------------------------------------------------

log()  { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }
warn() { printf '\n\033[1;33m[warn] %s\033[0m\n' "$*"; }
err()  { printf '\n\033[1;31m[error] %s\033[0m\n' "$*"; exit 1; }

# Enforce root execution
if [[ $EUID -ne 0 ]]; then
  exec sudo -E bash "$0" "$@"
fi

# ----------------------------- 1. System Packages ----------------------------
log "Updating package lists and installing core dependencies..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y ca-certificates curl git cron sqlite3 logrotate snapd python3 jq

# ----------------------------- 2. Docker & Compose ---------------------------
if ! command -v docker >/dev/null 2>&1; then
  log "Installing Docker engine..."
  curl -fsSL https://get.docker.com | sh
fi
systemctl enable --now docker
usermod -aG docker ubuntu || true

# ----------------------------- 3. AWS CLI ------------------------------------
if ! command -v aws >/dev/null 2>&1; then
  log "Installing AWS CLI v2 via snap..."
  snap install aws-cli --classic
fi
export AWS_DEFAULT_REGION="$AWS_REGION"

# ----------------------------- 4. Public IP & DuckDNS ------------------------
log "Retrieving host IP..."
PUBLIC_IP="$(curl -fsS --retry 3 https://checkip.amazonaws.com | tr -d '[:space:]')"
echo "Host Elastic/Public IP: ${PUBLIC_IP}"

if [[ -n "$DUCKDNS_TOKEN" ]]; then
  log "Updating DuckDNS record for ${DOMAIN} to ${PUBLIC_IP}..."
  RESULT="$(curl -fsS --retry 3 "https://www.duckdns.org/update?domains=${DUCKDNS_SUBDOMAIN}&token=${DUCKDNS_TOKEN}&ip=${PUBLIC_IP}")"
  [[ "$RESULT" == "OK" ]] || err "DuckDNS update failed: $RESULT"
  log "DuckDNS updated successfully. Waiting 10 seconds for DNS prop..."
  sleep 10
else
  warn "DUCKDNS_TOKEN not provided. Ensure ${DOMAIN} resolves to ${PUBLIC_IP} before SSL provisioning."
fi

# ----------------------------- 5. Clone Codebase -----------------------------
log "Setting up application directory at ${APP_DIR}..."
mkdir -p "$APP_DIR"
if [[ -d "$APP_DIR/.git" ]]; then
  log "Repository exists. Pulling latest main..."
  git -C "$APP_DIR" pull --ff-only || true
else
  log "Cloning repository ${REPO_URL}..."
  git clone "$REPO_URL" "$APP_DIR"
fi
cd "$APP_DIR"
chown -R ubuntu:ubuntu "$APP_DIR"

# ----------------------------- 6. Configure Environment (.env) ---------------
log "Generating production .env file..."
SECRET_KEY_VAL="$(python3 -c 'import secrets; print(secrets.token_urlsafe(50))')"

cat > "$APP_DIR/.env" <<EOF
DEBUG=False
SECRET_KEY=${SECRET_KEY_VAL}
ALLOWED_HOSTS=${DOMAIN},${PUBLIC_IP},localhost,127.0.0.1
CSRF_TRUSTED_ORIGINS=https://${DOMAIN}
COOKIE_SECURE=1
BACKUP_BUCKET=${S3_BUCKET}
AWS_REGION=${AWS_REGION}
EOF
chmod 600 "$APP_DIR/.env"
chown ubuntu:ubuntu "$APP_DIR/.env"

# ----------------------------- 7. ECR Authentication & Image Pull -----------
log "Authenticating Docker with Amazon ECR..."
aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "$ECR_REGISTRY"

log "Pulling latest production image: ${ECR_IMAGE}..."
docker pull "$ECR_IMAGE"

# ----------------------------- 8. Let's Encrypt SSL Provisioning -------------
log "Checking SSL certificates for ${DOMAIN}..."
if [[ ! -d "/etc/letsencrypt/live/${DOMAIN}" ]]; then
  log "Requesting initial Let's Encrypt certificate via Certbot standalone..."
  # Ensure port 80 is unbound
  docker compose -f "$COMPOSE_FILE" down 2>/dev/null || true
  
  certbot certonly --standalone \
    -d "$DOMAIN" \
    --non-interactive \
    --agree-tos \
    -m "$LETSENCRYPT_EMAIL"
else
  log "Existing certificate detected at /etc/letsencrypt/live/${DOMAIN}"
fi

# ----------------------------- 9. Start Container Services ------------------
log "Starting production container stack with ${COMPOSE_FILE}..."
docker compose -f "$COMPOSE_FILE" down 2>/dev/null || true
docker compose -f "$COMPOSE_FILE" up -d

log "Waiting for containers to initialize..."
sleep 8
docker compose -f "$COMPOSE_FILE" ps

# ----------------------------- 10. Automated Database Restoration ------------
log "Checking for existing database backups in s3://${S3_BUCKET}..."
if aws s3 ls "s3://${S3_BUCKET}/" >/dev/null 2>&1; then
  LATEST_SNAPSHOT="$(aws s3 ls "s3://${S3_BUCKET}/" | sort | tail -n 1 | awk '{print $4}')"
  if [[ -n "$LATEST_SNAPSHOT" && "$LATEST_SNAPSHOT" =~ \.sqlite3$ ]]; then
    log "Found recent snapshot: ${LATEST_SNAPSHOT}. Restoring into database volume..."
    aws s3 cp "s3://${S3_BUCKET}/${LATEST_SNAPSHOT}" /tmp/latest-backup.sqlite3
    
    # Run integrity verification
    INTEGRITY="$(sqlite3 /tmp/latest-backup.sqlite3 'PRAGMA integrity_check;')"
    if [[ "$INTEGRITY" == "ok" ]]; then
      log "Snapshot passed PRAGMA integrity_check. Restoring into ${APP_CONTAINER}..."
      docker compose -f "$COMPOSE_FILE" stop "$APP_CONTAINER"
      docker cp /tmp/latest-backup.sqlite3 "${APP_CONTAINER}:/app/data/db.sqlite3"
      # Fix permissions inside container data folder
      docker compose -f "$COMPOSE_FILE" start "$APP_CONTAINER"
      log "Database restored successfully."
    else
      warn "Integrity check failed on downloaded snapshot ($INTEGRITY). Skipping restore."
    fi
    rm -f /tmp/latest-backup.sqlite3
  else
    warn "No snapshot found in S3 bucket. Continuing with initial migrated DB."
  fi
else
  warn "Could not access S3 bucket. Ensure EC2 IAM role has AmazonS3FullAccess."
fi

# ----------------------------- 11. Backup Script & Cron Automation ----------
log "Configuring zero-downtime backup script..."
mkdir -p "$APP_DIR/scripts"

cat > "$APP_DIR/scripts/backup-db.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

BACKUP_BUCKET="${BACKUP_BUCKET:-groovebox-backups-786971361856}"
AWS_REGION="${AWS_REGION:-ap-south-1}"
CONTAINER_NAME="groovebox-app"
TIMESTAMP=$(date -u +"%Y%m%dT%H%M%SZ")
TARGET_FILE="db-${TIMESTAMP}.sqlite3"
LOCAL_TMP="/tmp/${TARGET_FILE}"

echo "[backup] snapshotting DB at ${TIMESTAMP}"

# Zero-downtime online SQLite backup using Python sqlite3.backup() API
docker exec "$CONTAINER_NAME" python -c "
import sqlite3
src = sqlite3.connect('/app/data/db.sqlite3')
dst = sqlite3.connect('/tmp/snapshot.sqlite3')
src.backup(dst)
dst.close()
src.close()
"

# Copy snapshot out of container
docker cp "${CONTAINER_NAME}:/tmp/snapshot.sqlite3" "$LOCAL_TMP"
docker exec "$CONTAINER_NAME" rm -f /tmp/snapshot.sqlite3

# Upload to S3
aws s3 cp "$LOCAL_TMP" "s3://${BACKUP_BUCKET}/${TARGET_FILE}" --region "$AWS_REGION"
rm -f "$LOCAL_TMP"

echo "[backup] successfully uploaded ${TARGET_FILE}"

if [[ -n "${HEALTHCHECK_URL:-}" ]]; then
  curl -fsS -m 10 --retry 3 "${HEALTHCHECK_URL}" >/dev/null || true
fi
EOF

chmod +x "$APP_DIR/scripts/backup-db.sh"
chown -R ubuntu:ubuntu "$APP_DIR/scripts"

# Setup Log file with correct permissions
touch /var/log/groovebox-backup.log
chown ubuntu:ubuntu /var/log/groovebox-backup.log
chmod 664 /var/log/groovebox-backup.log

# Schedule Cron Jobs under ubuntu user
log "Installing automated cron schedules for backup and SSL renewal..."
CRON_JOB_BACKUP="0 2 * * * BACKUP_BUCKET=${S3_BUCKET} ${APP_DIR}/scripts/backup-db.sh >> /var/log/groovebox-backup.log 2>&1"
CRON_JOB_SSL="0 3 * * 1 cd ${APP_DIR} && docker compose -f ${COMPOSE_FILE} run --rm certbot renew -q && docker compose -f ${COMPOSE_FILE} exec -T nginx nginx -s reload"

(crontab -u ubuntu -l 2>/dev/null | grep -v "backup-db.sh" | grep -v "certbot renew" || true; echo "$CRON_JOB_BACKUP"; echo "$CRON_JOB_SSL") | crontab -u ubuntu -

# Logrotate configuration with su directive to prevent permission errors
log "Configuring logrotate for /var/log/groovebox-backup.log..."
cat > /etc/logrotate.d/groovebox-backup <<'EOF'
/var/log/groovebox-backup.log {
    su ubuntu ubuntu
    weekly
    rotate 4
    compress
    missingok
    notifempty
    create 0664 ubuntu ubuntu
}
EOF

# ----------------------------- 12. Monitoring: CloudWatch Alarm & SNS --------
if [[ -n "$ALERT_EMAIL" ]]; then
  log "Configuring host-level CloudWatch StatusCheckFailed alarm and SNS..."
  
  # Fetch IMDSv2 metadata token
  IMDS_TOKEN="$(curl -fsS -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" 2>/dev/null || true)"
  if [[ -n "$IMDS_TOKEN" ]]; then
    INSTANCE_ID="$(curl -fsS -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" http://169.254.169.254/latest/meta-data/instance-id)"
    
    # Create or retrieve SNS topic
    TOPIC_ARN="$(aws sns create-topic --name groovebox-alerts --region "$AWS_REGION" --query TopicArn --output text 2>/dev/null || true)"
    
    if [[ -n "$TOPIC_ARN" && "$TOPIC_ARN" != "None" ]]; then
      # Subscribe Alert Email
      aws sns subscribe \
        --topic-arn "$TOPIC_ARN" \
        --protocol email \
        --notification-endpoint "$ALERT_EMAIL" \
        --region "$AWS_REGION" >/dev/null 2>&1 || true

      # Put CloudWatch Metric Alarm
      aws cloudwatch put-metric-alarm \
        --alarm-name groovebox-status-check \
        --namespace AWS/EC2 \
        --metric-name StatusCheckFailed \
        --dimensions Name=InstanceId,Value="$INSTANCE_ID" \
        --statistic Maximum \
        --period 300 \
        --evaluation-periods 2 \
        --threshold 1 \
        --comparison-operator GreaterThanOrEqualToThreshold \
        --alarm-actions "$TOPIC_ARN" \
        --region "$AWS_REGION" >/dev/null 2>&1 || true

      log "CloudWatch alarm 'groovebox-status-check' linked to instance ${INSTANCE_ID} and topic ${TOPIC_ARN}."
    else
      warn "IAM role lacks SNS permissions. Alarm configuration skipped (can be run from local laptop)."
    fi
  fi
fi

# ----------------------------- 13. End-to-End Verification -------------------
log "Running operational smoke tests..."
sleep 3

HTTP_CODE="$(curl -s -o /dev/null -w "%{http_code}" "http://${DOMAIN}" || true)"
HTTPS_CODE="$(curl -s -o /dev/null -w "%{http_code}" "https://${DOMAIN}" || true)"

echo "--------------------------------------------------------"
echo "  HTTP  Verification (expect 301): ${HTTP_CODE}"
echo "  HTTPS Verification (expect 200): ${HTTPS_CODE}"
echo "--------------------------------------------------------"

if [[ "$HTTPS_CODE" == "200" ]]; then
  log "Deployment completed successfully! Website live at https://${DOMAIN}"
else
  warn "HTTPS endpoint returned ${HTTPS_CODE}. Verify DNS propagation and container logs: 'docker compose -f ${APP_DIR}/${COMPOSE_FILE} logs'."
fi