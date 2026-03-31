#!/usr/bin/env bash
set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'
RED='\033[0;31m'; BOLD='\033[1m'; RESET='\033[0m'

ok()     { echo -e "  ${GREEN}✔${RESET}  $1"; }
warn()   { echo -e "  ${YELLOW}⚠${RESET}  $1"; }
fail()   { echo -e "  ${RED}✘${RESET}  $1"; }
banner() { echo -e "\n${CYAN}${BOLD}══════════  $1  ══════════${RESET}\n"; }

# Must run as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root: sudo ./vm-setup.sh"
  exit 1
fi

banner "Step 1 — System Update"
apt-get update -qq && apt-get upgrade -y -qq
ok "System updated"

banner "Step 2 — Install Dependencies"
apt-get install -y -qq \
  curl wget git unzip \
  ca-certificates gnupg \
  lsb-release apt-transport-https \
  net-tools
ok "Dependencies installed"

banner "Step 3 — Install Docker"
if command -v docker &>/dev/null; then
  ok "Docker already installed: $(docker --version)"
else
  curl -fsSL https://get.docker.com | sh
  systemctl enable docker
  systemctl start docker
  ok "Docker installed: $(docker --version)"
fi

banner "Step 4 — Install Docker Compose Plugin"
if docker compose version &>/dev/null; then
  ok "Docker Compose already installed: $(docker compose version)"
else
  COMPOSE_VERSION="v2.24.0"
  mkdir -p /usr/local/lib/docker/cli-plugins
  curl -SL "https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-linux-x86_64" \
    -o /usr/local/lib/docker/cli-plugins/docker-compose
  chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
  ok "Docker Compose installed: $(docker compose version)"
fi

banner "Step 5 — Add User to Docker Group"
SUDO_USER="${SUDO_USER:-ubuntu}"
usermod -aG docker "$SUDO_USER" 2>/dev/null || true
ok "User $SUDO_USER added to docker group"

banner "Step 6 — Kernel Settings for Elasticsearch"
sysctl -w vm.max_map_count=262144
grep -q "vm.max_map_count" /etc/sysctl.conf \
  && sed -i 's/vm.max_map_count.*/vm.max_map_count=262144/' /etc/sysctl.conf \
  || echo "vm.max_map_count=262144" >> /etc/sysctl.conf
ok "vm.max_map_count=262144 set (permanent)"

# File descriptor limits
cat >> /etc/security/limits.conf << 'LIMITS'
* soft nofile 65536
* hard nofile 65536
LIMITS
ok "File descriptor limits set"

banner "Step 7 — Open Required Firewall Ports"
if command -v ufw &>/dev/null; then
  ufw allow 2181/tcp comment "Zookeeper"     2>/dev/null || true
  ufw allow 9092/tcp comment "Kafka external" 2>/dev/null || true
  ufw allow 29092/tcp comment "Kafka internal" 2>/dev/null || true
  ufw allow 8080/tcp comment "Kafka UI"       2>/dev/null || true
  ufw allow 9200/tcp comment "Elasticsearch"  2>/dev/null || true
  ufw allow 9300/tcp comment "Elasticsearch cluster" 2>/dev/null || true
  ufw allow 9042/tcp comment "ScyllaDB CQL"   2>/dev/null || true
  ufw allow 6379/tcp comment "Redis"          2>/dev/null || true
  ufw allow 22/tcp comment "SSH"              2>/dev/null || true
  ok "Firewall ports opened"
else
  warn "ufw not found — skip firewall config"
fi

banner "Step 8 — Verify Port Availability"
PORTS="2181 9092 29092 8080 9200 9300 9042 9160 10000 6379"
ALL_FREE=true
for port in $PORTS; do
  if ss -tlnp 2>/dev/null | grep -q ":$port "; then
    warn "Port $port is already in use!"
    ALL_FREE=false
  else
    ok "Port $port is free"
  fi
done

banner "Step 9 — System Resource Check"
CPU=$(nproc)
RAM=$(free -g | awk '/Mem/{print $2}')
DISK=$(df -BG / | awk 'NR==2{print $4}' | tr -d G)

echo "  CPU cores : $CPU  (recommended: 4+)"
echo "  RAM (GB)  : $RAM  (recommended: 8+)"
echo "  Free disk : ${DISK}GB (recommended: 20GB+)"

[ "$CPU" -lt 2 ] && warn "Low CPU — stack may be slow"
[ "$RAM" -lt 4 ] && warn "Low RAM — consider adding swap"
[ "$DISK" -lt 10 ] && warn "Low disk space"

# Add swap if RAM < 4GB
if [ "$RAM" -lt 4 ]; then
  banner "Adding 4GB Swap (low RAM detected)"
  if [ ! -f /swapfile ]; then
    fallocate -l 4G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo "/swapfile none swap sw 0 0" >> /etc/fstab
    ok "4GB swap added"
  else
    ok "Swap already exists"
  fi
fi

banner "Setup Complete!"
echo -e "  ${GREEN}${BOLD}VM is ready to run the Docker stack.${RESET}"
echo ""
echo -e "  Next steps:"
echo -e "  1. Log out and back in (for docker group)"
echo -e "  2. Clone your repo:"
echo -e "     ${CYAN}git clone https://github.com/YOUR_USERNAME/YOUR_REPO.git${RESET}"
echo -e "  3. Start the stack:"
echo -e "     ${CYAN}cd YOUR_REPO && docker compose up -d${RESET}"
echo -e "  4. Validate:"
echo -e "     ${CYAN}./stack-check.sh${RESET}"
echo ""
