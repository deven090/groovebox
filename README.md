# Groovebox — Production Cloud Deployment & Infrastructure

An automated, containerized music streaming web application built on Django, deployed to AWS with zero-downtime disaster recovery, automated SSL termination, and host monitoring.

---

## Architecture Overview

```text
                          Internet / Users
                                 │
                         (HTTPS: Port 443)
                                 ▼
                   [ DuckDNS Dynamic DNS ]
                  quack-vortex-99.duckdns.org
                                 │
                                 ▼
                     [ AWS Elastic IP ]
                        43.205.8.25
                                 │
                                 ▼
                 [ AWS EC2 Instance: t3.micro ]
                 (Ubuntu 24.04 LTS / ap-south-1)
     ┌─────────────────────────────────────────────────────────┐
     │                      Docker Host                        │
     │                                                         │
     │  ┌───────────────────────┐   ┌───────────────────────┐  │
     │  │   groovebox-nginx     │   │     groovebox-app     │  │
     │  │   (Reverse Proxy &    │──>│   (Django + Gunicorn) │  │
     │  │   TLS Termination)    │   │      (Port 8000)      │  │
     │  └──────────┬────────────┘   └───────────┬───────────┘  │
     │             │                            │              │
     │             ▼                            ▼              │
     │    Certbot TLS Certs            Mounted SQLite Volume   │
     │    (Let's Encrypt ACME)         (/app/data/db.sqlite3)  │
     └─────────────┬────────────────────────────┬──────────────┘
                   │                            │
      Weekly Renewal (Cron)            Daily Backup (02:00 UTC)
                   │                            │
                   ▼                            ▼
          Let's Encrypt CA              [ Amazon S3 Bucket ]
                                    groovebox-backups-786971361856
                                    (AES256, 30-Day Expiration)

               Host-Level Health Check:
          [ CloudWatch: StatusCheckFailed ] ──> [ SNS Alert Topic ]
                                                      │
                                                      ▼
                                           devendra2579a@gmail.com
```

---

## Infrastructure & AWS Resource Specifications

| Component | Technology / Identifier | Configuration Details |
| :--- | :--- | :--- |
| **Compute** | AWS EC2 `t3.micro` | Ubuntu 24.04 LTS (`i-0b5f9b5c71688e95c`) in `ap-south-1` |
| **Networking** | Elastic IP & DuckDNS | Static IP `43.205.8.25` bound to `quack-vortex-99.duckdns.org` |
| **Container Registry**| Amazon ECR | `786971361856.dkr.ecr.ap-south-1.amazonaws.com/groovebox:latest` |
| **Reverse Proxy** | Nginx 1.27 | TLS 1.2/1.3 termination, automatic HTTP→HTTPS redirect (301) |
| **Application Server**| Gunicorn / Django 5 | Running as non-root `appuser`, isolated internal network |
| **Persistence** | Docker Named Volumes | Independent volumes for `db-data`, `static-data`, and `media-data` |
| **Disaster Recovery** | Amazon S3 |
