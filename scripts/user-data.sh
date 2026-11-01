#!/usr/bin/env bash
set -euxo pipefail
exec > >(tee /var/log/user-data.log) 2>&1

apt-get update -y
apt-get install -y ca-certificates curl sqlite3 rsync
curl -fsSL https://get.docker.com | sh
usermod -aG docker ubuntu
snap install aws-cli --classic

mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<'JSON'
{"log-driver":"json-file","log-opts":{"max-size":"10m","max-file":"3"}}
JSON
systemctl restart docker

mkdir -p /opt/groovebox && chown ubuntu:ubuntu /opt/groovebox
