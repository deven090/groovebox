# Groovebox — Production Cloud Deployment & Engineering Architecture

An enterprise-grade, containerized Django music streaming application engineered for production on AWS. This deployment features hardened network-edge TLS termination, automated zero-downtime database snapshots, immutable container deployments via Amazon ECR, proactive infrastructure observability, and strict principle-of-least-privilege IAM enforcement.

---

## 1. System Architecture & Traffic Flow

Traffic routes from public DNS through transport security termination and into an isolated, unprivileged container network. 

```text
                               Public Internet
                                      │
                         HTTPS Request (Port 443)
                                      ▼
                        [ DuckDNS Dynamic DNS Engine ]
                         quack-vortex-99.duckdns.org
                                      │
                                      ▼
                           [ AWS Elastic IP (EIP) ]
                                 43.205.8.25
                                      │
                                      ▼
                 [ AWS EC2: t3.micro (Ubuntu 24.04 LTS) ]
                           Region: ap-south-1
 ┌────────────────────────────────────────────────────────────────────────┐
 │ Host System (Docker Engine & System Daemons)                           │
 │                                                                        │
 │  ┌──────────────────────────────────────────────────────────────────┐  │
 │  │ groovebox-network (Docker Bridge Network)                        │  │
 │  │                                                                  │  │
 │  │  ┌───────────────────────┐            ┌───────────────────────┐  │  │
 │  │  │    groovebox-nginx    │            │     groovebox-app     │  │  │
 │  │  │   (Nginx 1.27 Proxy)  │───────────>│   (Django + Gunicorn) │  │  │
 │  │  │   - TLS 1.2 / TLS 1.3 │  HTTP/WSGI │   - Non-Root: appuser │  │  │
 │  │  │   - 301 Force HTTPS   │  Port 8000 │   - Gunicorn Workers  │  │  │
 │  │  └───────────┬───────────┘            └───────────┬───────────┘  │  │
 │  └──────────────┼────────────────────────────────────┼──────────────┘  │
 │                 │                                    │                 │
 │                 ▼                                    ▼                 │
 │       [ certbot-certs ]                      [ Named Docker Volumes ]  │
 │       Let's Encrypt Fullchain                - db-data: /app/data      │
 │       & Private Keys                         - static-data: /app/static│
 │                 │                            - media-data: /app/media  │
 └─────────────────┼────────────────────────────────────┼─────────────────┘
                   │                                    │
           Weekly Renew Check                 Daily 02:00 UTC Snapshot
           (ACME Webroot Challenge)           (sqlite3.backup API)
                   │                                    │
                   ▼                                    ▼
          Let's Encrypt CA                     [ Amazon S3 Bucket ]
                                          groovebox-backups-786971361856
                                          - Server-Side Encryption (AES256)
                                          - 30-Day Automated Expiration

               Instance Health & System Metrics
                               │
                               ▼
            [ AWS CloudWatch: StatusCheckFailed ]
                               │ (Trigger >= 1 in 2 consecutive 300s periods)
                               ▼
               [ Amazon SNS: groovebox-alerts ]
                               │
                               ▼
                    devendra2579a@gmail.com
```

---

## 2. Infrastructure & Cloud Specifications

| Layer | AWS / Technology Component | Resource Identifier / Configuration | Engineering Purpose |
| :--- | :--- | :--- | :--- |
| **Compute** | Amazon EC2 | `t3.micro` (`i-0b5f9b5c71688e95c`) | Ubuntu 24.04 LTS host runtime in `ap-south-1`. |
| **Networking** | AWS Elastic IP (EIP) | `43.205.8.25` | Static public IPv4 anchor preventing DNS drift on reboots. |
| **DNS Resolution** | DuckDNS DDNS | `quack-vortex-99.duckdns.org` | Dynamic DNS mapping to the dedicated Elastic IP. |
| **Container Registry** | Amazon ECR | `786971361856.dkr.ecr.ap-south-1.amazonaws.com/groovebox` | Immutable `linux/amd64` production container image registry. |
| **Edge Proxy** | Nginx 1.27-alpine | `groovebox-nginx` | Reverse proxy, static asset delivery, and TLS 1.2/1.3 termination. |
| **App Server** | Gunicorn / Python 3.12 | `groovebox-app` | Non-root WSGI process management with isolated environment flags. |
| **Persistence** | Docker Named Volumes | `db-data`, `static-data`, `media-data` | Stateful data segregation independent of container lifecycles. |
| **Disaster Recovery** | Amazon S3 | `s3://groovebox-backups-786971361856` | Versioned, zero-downtime database snapshots with 30-day lifecycle expiration. |
| **Monitoring** | Amazon CloudWatch | Alarm: `groovebox-status-check` | Automated infrastructure failure detection (`StatusCheckFailed >= 1`). |
| **Alerting** | Amazon SNS | Topic: `groovebox-alerts` | Instant incident routing to `devendra2579a@gmail.com`. |
| **IAM Security** | Instance Profile Role | Role: `groovebox-ec2-role` | Scoped tokenless access to ECR image pulls and S3 bucket writes. |

---

## 3. Engineering Implementation Details

### Phase 1: Local Staging Validation
* Validated deployment orchestration locally via **Vagrant** running an Ubuntu base image with VirtualBox provider.
* Validated container isolation, cross-volume file permissions between Gunicorn and Nginx, and static asset collection before provisioning cloud resources.

### Phase 2: Multi-Container Docker Architecture
* **Non-Root Execution:** Application runtime executes under an unprivileged system user (`appuser`, UID/GID `10001`), preventing privilege escalation and host escape vulnerabilities.
* **Service Segregation:** Decoupled into `groovebox-app` (Gunicorn/Django WSGI runtime) and `groovebox-nginx` (reverse proxy). 
* **Multi-Stage Build:** Multi-stage Docker build producing an optimized `linux/amd64` artifact published to AWS ECR.

### Phase 3: Edge Security & TLS Hardening
* **Let's Encrypt Automated Provisioning:** Configured Certbot via HTTP-01 webroot challenge mapped through `/var/www/certbot` on Nginx.
* **Modern Cryptography:** Enforced TLS 1.2 and TLS 1.3 protocol suites with secure ECDHE/RSA cipher configurations.
* **Forced HTTPS Enforcement:** Plain HTTP requests across port 80 (whether accessed through the domain or directly through the raw Elastic IP `43.205.8.25`) are permanently redirected via `301 Moved Permanently` to `https://quack-vortex-99.duckdns.org`.
* **Django Security Flags:**
  * `DEBUG=0`
  * `COOKIE_SECURE=1` (Strict enforcement of `Secure` and `HttpOnly` attributes on session and CSRF tokens)
  * `ALLOWED_HOSTS=quack-vortex-99.duckdns.org,43.205.8.25,localhost,127.0.0.1`
  * `CSRF_TRUSTED_ORIGINS=https://quack-vortex-99.duckdns.org`

### Phase 4: Zero-Downtime Hot Backups & Disaster Recovery Verification
* **Hot SQLite Snapshots:** Backups utilize Python's underlying `sqlite3.backup()` API to clone the active database page-by-page. This eliminates read/write locks, ensures ACID transaction integrity, and avoids table corruption while the music streaming application is under load.
* **Automated Archiving Pipeline:** Scheduled daily cron execution at `02:00 UTC` generating timestamped artifacts (`db-YYYYMMDDTHHMMSSZ.sqlite3`) and uploading directly to Amazon S3:
  ```bash
  0 2 * * * BACKUP_BUCKET=groovebox-backups-786971361856 /opt/groovebox/scripts/backup-db.sh >> /var/log/groovebox-backup.log 2>&1
  ```
* **Proven Recovery Path:** Tested end-to-end recovery by pulling remote snapshots into an isolated environment and executing automated diagnostic scripts:
  * Executed `PRAGMA integrity_check;` confirming an exact `ok` status.
  * Verified table catalog integrity (confirmed all 22 database tables including migrations and auth tables).
  * Validated row count accuracy across user data.
* **Log Rotation:** Automated log rotation at `/etc/logrotate.d/groovebox-backup` configured with `su ubuntu ubuntu` to compress and cycle `/var/log/groovebox-backup.log` weekly (retaining 4 rotations).

### Phase 5: Automated Maintenance & Observability
* **SSL Renewal Pipeline:** Scheduled weekly cron execution Mondays at `03:00 UTC` to test and execute renewal of Let's Encrypt certificates without downtime:
  ```bash
  0 3 * * 1 cd /opt/groovebox && docker compose run --rm certbot renew -q && docker compose exec -T nginx nginx -s reload
  ```
* **Infrastructure Failure Alerting:** Configured CloudWatch metric alarm triggering on `StatusCheckFailed >= 1` over two consecutive 300-second evaluation windows, routing failure notices to Amazon SNS.

---

## 4. Directory Structure

```text
.
├── .gitignore                    # Strict exclusion for .env, *.pem keys, and *.sqlite3 data
├── docker-compose.prod.yml       # Production multi-container orchestration definition
├── Dockerfile                    # Multi-stage production container build specification
├── nginx/
│   └── conf.d/
│       └── app.conf              # Nginx virtual host configuration (TLS, headers, proxying)
├── scripts/
│   ├── backup-db.sh              # Hot SQLite database backup and S3 upload script
│   └── user-data.sh              # EC2 cloud-init deployment and bootstrapping script
└── README.md                     # Comprehensive project architecture and operations manual
```

---

## 5. Operations & Incident Management Runbook

### Health & Container Diagnostic Commands
Connect to the production host via SSH:
```bash
ssh -i groovebox-key.pem ubuntu@43.205.8.25
```

Inspect service health and runtime logs:
```bash
cd /opt/groovebox

# Verify container process status
docker compose ps

# Inspect live application stdout/stderr streams
docker compose logs --tail=100 -f app

# Inspect reverse proxy access and error logs
docker compose logs --tail=100 -f nginx
```

### Manual Disaster Recovery Snapshot Test
Force an on-demand database snapshot and verify S3 transmission:
```bash
BACKUP_BUCKET=groovebox-backups-786971361856 /opt/groovebox/scripts/backup-db.sh
aws s3 ls s3://groovebox-backups-786971361856/
```

### End-to-End Backup Restoration & Integrity Test
To verify the recovery procedure from scratch:
```bash
# 1. Fetch newest backup key
LATEST=$(aws s3 ls s3://groovebox-backups-786971361856/ | sort | tail -n 1 | awk '{print $4}')

# 2. Download to temporary staging directory
aws s3 cp "s3://groovebox-backups-786971361856/$LATEST" /tmp/restore-test.sqlite3

# 3. Execute integrity check via Python SQLite engine
python3 -c "
import sqlite3
con = sqlite3.connect('/tmp/restore-test.sqlite3')
cur = con.cursor()
cur.execute('PRAGMA integrity_check;')
status = cur.fetchone()[0]
print(f'PRAGMA status: {status}')
assert status == 'ok', 'Integrity check failed'
con.close()
"

# 4. Clean up test artifact
rm -f /tmp/restore-test.sqlite3
```

### Certbot Renewal Pipeline Verification
Perform an ACME dry-run test to validate routing through the webroot volume:
```bash
cd /opt/groovebox
docker compose run --rm certbot renew --dry-run
```

### Infrastructure Alarm & Metric Validation
Run from your local workstation terminal:
```bash
aws cloudwatch describe-alarms \
  --alarm-names groovebox-status-check \
  --region ap-south-1 \
  --query "MetricAlarms[0].[AlarmName,StateValue]" \
  --output text
```

---

## 6. Author & Maintainer

* **Devendra Yadav** — [@deven090](https://github.com/deven090)

## 7. License

Distributed under the terms of the **MIT License**.
