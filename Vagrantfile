# -*- mode: ruby -*-
# vi: set ft=ruby :

Vagrant.configure("2") do |config|
  config.vm.box = "ubuntu/jammy64"
  config.vm.hostname = "groovebox-staging"

  # App is proxied on port 80 inside the VM (Nginx); reach it at localhost:8080 on the host.
  config.vm.network "forwarded_port", guest: 80, host: 8080

  config.vm.provider "virtualbox" do |vb|
    vb.memory = "1024"
    vb.cpus = 1
  end

  config.vm.provision "shell", inline: <<-SHELL
    set -euo pipefail

    echo "[provision] Updating package index..."
    apt-get update -y

    echo "[provision] Installing prerequisites..."
    apt-get install -y ca-certificates curl gnupg

    echo "[provision] Installing Docker + Compose plugin..."
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc

    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
      $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

    apt-get update -y
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    echo "[provision] Adding vagrant user to docker group..."
    usermod -aG docker vagrant

    echo "[provision] Verifying Docker install..."
    docker --version
    docker compose version

    echo "[provision] Done. SSH in with 'vagrant ssh' and run scripts/deploy.sh."
  SHELL
end
