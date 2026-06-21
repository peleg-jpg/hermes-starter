#!/usr/bin/env bash
# One-time bootstrap for a FRESH VPS (Ubuntu 22.04/24.04 LTS).
# Run as a normal sudo user (NOT root). Idempotent: safe to re-run.
#
#   swapfile (OOM insurance) + Docker engine + compose plugin + ufw firewall
#
# Hermes brains bind their state to a host folder and talk outbound only
# (Telegram polling etc.), so no inbound ports are opened.
set -euo pipefail

if [ "$(id -u)" -eq 0 ]; then
  echo "Run as a normal sudo user, not root. Create one:" >&2
  echo "  adduser hermes && usermod -aG sudo hermes && su - hermes" >&2
  exit 1
fi

SWAP_GB="${SWAP_GB:-8}"

echo "==> 1/3 swapfile (${SWAP_GB} GB OOM insurance; many VPS images ship none)"
if ! sudo swapon --show | grep -q '/swapfile'; then
  sudo fallocate -l "${SWAP_GB}G" /swapfile
  sudo chmod 600 /swapfile
  sudo mkswap /swapfile
  sudo swapon /swapfile
  grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab >/dev/null
  echo "    swap on: $(free -h | awk '/Swap/{print $2}')"
else
  echo "    swapfile already active, skipping"
fi

echo "==> 2/3 Docker engine + compose plugin"
if ! command -v docker >/dev/null 2>&1; then
  # Docker's official convenience installer (https://docs.docker.com/engine/install).
  curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
  sudo sh /tmp/get-docker.sh
  sudo usermod -aG docker "$USER"
  echo "    NOTE: log out and back in (or run 'newgrp docker') so docker works without sudo,"
  echo "          then re-run install.sh."
else
  echo "    docker present: $(docker --version)"
fi
compose_ver="$(docker compose version 2>/dev/null | head -1 || true)"
[ -n "$compose_ver" ] && echo "    compose: $compose_ver" \
  || echo "    WARNING: 'docker compose' plugin missing"

echo "==> 3/3 firewall (allow SSH only; brains are outbound-only)"
if command -v ufw >/dev/null 2>&1; then
  sudo ufw allow OpenSSH || sudo ufw allow 22/tcp
  yes | sudo ufw enable
  sudo ufw status verbose | head -8
else
  echo "    ufw not installed; skipping"
fi

echo "==> bootstrap done."
